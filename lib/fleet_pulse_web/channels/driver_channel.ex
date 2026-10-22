defmodule FleetPulseWeb.DriverChannel do
  @moduledoc """
  Telemetry ingress for one driver
  """

  use FleetPulseWeb, :channel

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.RateLimit
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.Telemetry
  alias FleetPulse.Types

  @order_events ["pickup", "pod_upload", "delivered"]

  @type order_wire :: %{
          id: term(),
          status: term(),
          weight_kg: term(),
          pickup: %{latitude: term(), longitude: term()},
          dropoff: %{latitude: term(), longitude: term()},
          assigned_at: term()
        }

  @type error ::
          :batch_too_large
          | :forbidden
          | :invalid_batch
          | :invalid_order_id
          | :invalid_photo_hash
          | :invalid_status
          | :invalid_telemetry
          | :invalid_topic
          | :invalid_transition
          | :no_active_job
          | :not_found
          | :pending_approval
          | :rate_limited
          | :unavailable
          | {:start_failed, term()}
          | Driver.changeset()

  @impl Phoenix.Channel
  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, %{status: Driver.status()}, Phoenix.Socket.t()} | {:error, %{reason: String.t()}}
  def join("driver:" <> topic_id, _payload, socket) do
    with {:ok, driver_id} <- parse_id(topic_id),
         :ok <- authorise(driver_id, socket.assigns.driver_id),
         {:ok, _driver} <- Tracking.fetch_active_driver(driver_id),
         {:ok, state} <- Tracking.attach_channel(driver_id, self()) do
      :ok = Events.subscribe_driver(driver_id)
      send(self(), :after_join)
      {:ok, %{status: state.status}, assign(socket, :tracking, driver_id)}
    else
      {:error, reason} -> {:error, %{reason: to_reason(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl Phoenix.Channel
  @spec handle_in(String.t(), map(), Phoenix.Socket.t()) ::
          {:reply, :ok | {:ok, map()} | {:error, %{reason: String.t()}}, Phoenix.Socket.t()}
          | {:noreply, Phoenix.Socket.t()}

  def handle_in("ping", params, socket) do
    driver_id = socket.assigns.driver_id

    with :ok <- within_ping_budget(driver_id),
         {:ok, telemetry} <- Telemetry.from_params(params),
         :ok <- Tracking.track_location(driver_id, telemetry) do
      {:reply, :ok, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_reason(reason)}}, socket}
    end
  end

  def handle_in("ping_batch", %{"pings" => pings}, socket) do
    driver_id = socket.assigns.driver_id

    with :ok <- within_batch_budget(driver_id),
         {:ok, outcome} <- Tracking.record_offline_positions(driver_id, pings) do
      {:reply, {:ok, outcome}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_reason(reason)}}, socket}
    end
  end

  def handle_in("ping_batch", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_batch"}}, socket}
  end

  def handle_in("status", %{"status" => status}, socket) do
    driver_id = socket.assigns.driver_id

    with {:ok, parsed} <- parse_status(status),
         {:ok, state} <- Tracking.set_status(driver_id, parsed) do
      {:reply, {:ok, %{status: state.status}}, socket}
    else
      {:error, reason} -> {:reply, {:error, %{reason: to_reason(reason)}}, socket}
    end
  end

  def handle_in("status", _payload, socket) do
    {:reply, {:error, %{reason: "invalid_status"}}, socket}
  end

  def handle_in("pickup", %{"order_id" => order_id}, socket)
      when is_integer(order_id) and order_id > 0 do
    reply_transition(Dispatch.mark_picked_up(order_id, socket.assigns.driver_id), socket)
  end

  def handle_in("pod_upload", %{"order_id" => order_id} = payload, socket)
      when is_integer(order_id) and order_id > 0 do
    case Dispatch.pod_upload(order_id, socket.assigns.driver_id, payload["photo_sha256"]) do
      {:ok, upload} -> {:reply, {:ok, upload}, socket}
      {:error, reason} -> {:reply, {:error, %{reason: to_reason(reason)}}, socket}
    end
  end

  def handle_in("delivered", %{"order_id" => order_id} = payload, socket)
      when is_integer(order_id) and order_id > 0 do
    reply_transition(Dispatch.mark_delivered(order_id, socket.assigns.driver_id, payload), socket)
  end

  def handle_in(event, _payload, socket) when event in @order_events do
    {:reply, {:error, %{reason: "invalid_order_id"}}, socket}
  end

  def handle_in(_event, _params, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl Phoenix.Channel
  @spec handle_info(term(), Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def handle_info(:after_join, socket) do
    push(socket, "active_order", active_order_payload(socket.assigns.driver_id))
    {:noreply, socket}
  end

  def handle_info({:order_assigned, %Order{} = order}, socket) do
    push(socket, "order_assigned", order_payload(order))
    {:noreply, socket}
  end

  def handle_info({:order_updated, %Order{} = order}, socket) do
    push(socket, "order_updated", order_payload(order))
    {:noreply, socket}
  end

  def handle_info({:order_unassigned, %Order{} = order}, socket) do
    push(socket, "order_unassigned", %{id: order.id})
    push(socket, "active_order", active_order_payload(socket.assigns.driver_id))
    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @impl Phoenix.Channel
  @spec terminate(term(), Phoenix.Socket.t()) :: :ok
  def terminate(_reason, %Phoenix.Socket{assigns: %{tracking: driver_id}}) do
    Tracking.detach_channel(driver_id, self())
  end

  def terminate(_reason, _socket), do: :ok

  @spec within_ping_budget(Types.id()) :: :ok | {:error, :rate_limited}
  defp within_ping_budget(driver_id) do
    within_budget("ping:#{driver_id}", :ping_window_ms, :ping_limit)
  end

  @spec within_batch_budget(Types.id()) :: :ok | {:error, :rate_limited}
  defp within_batch_budget(driver_id) do
    within_budget("ping_batch:#{driver_id}", :ping_batch_window_ms, :ping_batch_limit)
  end

  @spec within_budget(String.t(), atom(), atom()) :: :ok | {:error, :rate_limited}
  defp within_budget(key, window, limit) do
    config = Application.fetch_env!(:fleet_pulse, __MODULE__)

    key
    |> RateLimit.hit(Keyword.fetch!(config, window), Keyword.fetch!(config, limit))
    |> verdict()
  end

  @spec verdict({:allow, non_neg_integer()} | {:deny, non_neg_integer()}) ::
          :ok | {:error, :rate_limited}
  defp verdict({:allow, _count}), do: :ok
  defp verdict({:deny, _retry_after_ms}), do: {:error, :rate_limited}

  @spec authorise(Types.id(), Types.id()) :: :ok | {:error, :forbidden}
  defp authorise(driver_id, driver_id), do: :ok
  defp authorise(_topic_id, _authenticated_id), do: {:error, :forbidden}

  @spec parse_id(String.t()) :: {:ok, Types.id()} | {:error, :invalid_topic}
  defp parse_id(topic_id) do
    case Integer.parse(topic_id) do
      {driver_id, ""} when driver_id > 0 -> {:ok, driver_id}
      _invalid -> {:error, :invalid_topic}
    end
  end

  @spec parse_status(term()) :: {:ok, Driver.status()} | {:error, :invalid_status}
  defp parse_status(status) when is_binary(status) do
    case Enum.find(Driver.statuses(), &(Atom.to_string(&1) == status)) do
      nil -> {:error, :invalid_status}
      known -> {:ok, known}
    end
  end

  defp parse_status(_status), do: {:error, :invalid_status}

  @spec to_reason(error() | atom()) :: String.t()
  defp to_reason(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp to_reason(_reason), do: "unprocessable"

  @spec reply_transition({:ok, Order.t()} | {:error, atom()}, Phoenix.Socket.t()) ::
          {:reply, :ok | {:error, %{reason: String.t()}}, Phoenix.Socket.t()}
  defp reply_transition({:ok, %Order{}}, socket), do: {:reply, :ok, socket}

  defp reply_transition({:error, reason}, socket) do
    {:reply, {:error, %{reason: to_reason(reason)}}, socket}
  end

  @spec active_order_payload(Types.id()) :: %{order: order_wire() | nil}
  defp active_order_payload(driver_id) do
    order_or_nil(Dispatch.active_order_for_driver(driver_id))
  end

  @spec order_or_nil(Order.t() | nil) :: %{order: order_wire() | nil}
  defp order_or_nil(nil), do: %{order: nil}
  defp order_or_nil(%Order{} = order), do: %{order: order_payload(order)}

  @spec order_payload(Order.t()) :: map()
  defp order_payload(%Order{} = order) do
    %{
      id: order.id,
      status: order.status,
      weight_kg: order.weight_kg,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at
    }
  end
end
