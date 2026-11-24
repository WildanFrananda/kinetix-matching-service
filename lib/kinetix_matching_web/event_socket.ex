defmodule KinetixMatchingWeb.EventSocket do
  @moduledoc """
  Unified camelCase JSON WebSocket endpoint (`WebSock`) for couriers and merchants.
  """

  @behaviour WebSock

  alias KinetixMatching.Dispatch
  alias KinetixMatching.Dispatch.Delivery, as: Order
  alias KinetixMatching.Dispatch.Events
  alias KinetixMatching.RateLimit
  alias KinetixMatching.Tracking
  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Tracking.PositionPublisher
  alias KinetixMatching.Tracking.Telemetry
  alias KinetixMatching.Types
  alias KinetixMatchingWeb.Events.Envelope
  alias KinetixMatchingWeb.Events.Mapper

  @type role :: :courier | :seller

  @type state :: %{
          role: role(),
          courier_principal_id: Types.principal_id() | nil,
          merchant_principal_id: String.t() | nil,
          active_order: Order.t() | nil,
          attached: boolean()
        }

  @type init_arg ::
          %{role: :courier, courier_principal_id: Types.principal_id()}
          | %{role: :seller, merchant_principal_id: String.t()}

  @schema_version 1

  @impl WebSock
  @spec init(init_arg()) :: {:push, {:text, String.t()}, state()} | {:stop, :normal, state()}
  def init(%{role: :courier, courier_principal_id: courier_principal_id}) do
    with {:ok, _standing} <- Tracking.courier_standing(courier_principal_id),
         {:ok, driver_state} <- Tracking.attach_channel(courier_principal_id, self()) do
      :ok = Events.subscribe_driver(courier_principal_id)
      active_order = Dispatch.active_order_for_driver(courier_principal_id)

      state = %{
        role: :courier,
        courier_principal_id: courier_principal_id,
        merchant_principal_id: nil,
        active_order: active_order,
        attached: true
      }

      snapshot =
        Envelope.server_event(
          "matching.job.snapshot",
          order_number_of(active_order),
          sequence_of(active_order),
          %{
            dutyStatus: Atom.to_string(driver_state.status),
            activeOrder: order_or_nil(active_order)
          }
        )

      {:push, {:text, Jason.encode!(snapshot)}, state}
    else
      {:error, _reason} ->
        {:stop, :normal,
         %{
           role: :courier,
           courier_principal_id: courier_principal_id,
           merchant_principal_id: nil,
           active_order: nil,
           attached: false
         }}
    end
  end

  def init(%{role: :seller, merchant_principal_id: merchant_principal_id}) do
    :ok = Events.subscribe_orders()
    orders = Dispatch.list_active_orders_for_merchant(merchant_principal_id)

    state = %{
      role: :seller,
      courier_principal_id: nil,
      merchant_principal_id: merchant_principal_id,
      active_order: nil,
      attached: false
    }

    snapshot =
      Envelope.server_event(
        "matching.job.snapshot",
        nil,
        nil,
        %{orders: Enum.map(orders, &Mapper.order_payload/1)}
      )

    {:push, {:text, Jason.encode!(snapshot)}, state}
  end

  @impl WebSock
  @spec handle_in({binary(), WebSock.opcode()}, state()) ::
          {:ok, state()} | {:push, {:text, String.t()}, state()}
  def handle_in({raw, opcode: :text}, state) when is_binary(raw) do
    case decode_frame(raw) do
      {:ok, request_id, event, data} ->
        dispatch_command(event, request_id, data, state)

      {:error, request_id, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  def handle_in(_other, state), do: {:ok, state}

  @impl WebSock
  @spec handle_info(term(), state()) :: {:ok, state()} | {:push, [WebSock.frame()], state()}
  def handle_info({:order_assigned, %Order{} = order}, %{role: :courier} = state) do
    frame =
      Envelope.server_event(
        "matching.job.assigned",
        order.order_number,
        order.event_sequence,
        %{order: Mapper.order_payload(order)}
      )

    {:push, [{:text, Jason.encode!(frame)}], %{state | active_order: order}}
  end

  def handle_info({:order_updated, %Order{} = order}, %{role: :courier} = state) do
    frame =
      Envelope.server_event(
        "matching.job.updated",
        order.order_number,
        order.event_sequence,
        %{order: Mapper.order_payload(order)}
      )

    {:push, [{:text, Jason.encode!(frame)}], %{state | active_order: active_or_nil(order)}}
  end

  def handle_info(
        {:order_unassigned, %Order{} = order},
        %{role: :courier, courier_principal_id: courier_principal_id} = state
      ) do
    active = Dispatch.active_order_for_driver(courier_principal_id)

    unassigned_frame =
      Envelope.server_event(
        "matching.job.unassigned",
        order.order_number,
        order.event_sequence,
        %{id: order.id, orderNumber: order.order_number}
      )

    snapshot_frame =
      Envelope.server_event(
        "matching.job.snapshot",
        order_number_of(active),
        sequence_of(active),
        %{
          dutyStatus: Atom.to_string(Tracking.live_status(courier_principal_id)),
          activeOrder: order_or_nil(active)
        }
      )

    frames = [
      {:text, Jason.encode!(unassigned_frame)},
      {:text, Jason.encode!(snapshot_frame)}
    ]

    {:push, frames, %{state | active_order: active}}
  end

  def handle_info(
        {:order_changed, %Order{merchant_principal_id: merchant_id} = order},
        %{role: :seller, merchant_principal_id: merchant_id} = state
      ) do
    frame =
      Envelope.server_event(
        "matching.job.updated",
        order.order_number,
        order.event_sequence,
        %{order: Mapper.order_payload(order)}
      )

    {:push, [{:text, Jason.encode!(frame)}], state}
  end

  def handle_info(_message, state), do: {:ok, state}

  @impl WebSock
  @spec terminate(term(), state()) :: :ok
  def terminate(_reason, %{
        role: :courier,
        attached: true,
        courier_principal_id: courier_principal_id
      })
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    Tracking.detach_channel(courier_principal_id, self())
  end

  def terminate(_reason, _state), do: :ok

  @spec decode_frame(binary()) ::
          {:ok, String.t() | nil, String.t(), map()}
          | {:error, String.t() | nil, :invalid_payload | :unsupported_schema_version}
  defp decode_frame(raw) do
    case Jason.decode(raw) do
      {:ok, %{"event" => event} = frame} when is_binary(event) ->
        validate_frame(frame, event)

      {:ok, %{"requestId" => request_id}} when is_binary(request_id) ->
        {:error, request_id, :invalid_payload}

      _invalid ->
        {:error, nil, :invalid_payload}
    end
  end

  @spec validate_frame(map(), String.t()) ::
          {:ok, String.t() | nil, String.t(), map()}
          | {:error, String.t() | nil, :invalid_payload | :unsupported_schema_version}
  defp validate_frame(frame, event) do
    request_id = valid_request_id(Map.get(frame, "requestId"))
    version = Map.get(frame, "schemaVersion", @schema_version)
    data = Map.get(frame, "data", %{})

    cond do
      version != @schema_version ->
        {:error, request_id, :unsupported_schema_version}

      not is_map(data) ->
        {:error, request_id, :invalid_payload}

      true ->
        {:ok, request_id, event, data}
    end
  end

  @spec valid_request_id(term()) :: String.t() | nil
  defp valid_request_id(request_id) when is_binary(request_id) and request_id != "",
    do: request_id

  defp valid_request_id(_request_id), do: nil

  @spec dispatch_command(String.t(), String.t() | nil, map(), state()) ::
          {:push, {:text, String.t()}, state()}
  defp dispatch_command("system.ping", request_id, _data, state) do
    {:push, {:text, Jason.encode!(Envelope.pong(request_id))}, state}
  end

  defp dispatch_command(_event, request_id, _data, %{role: :seller} = state) do
    {:push, {:text, Jason.encode!(Envelope.error(request_id, :forbidden))}, state}
  end

  defp dispatch_command(
         "courier.location.ping",
         request_id,
         data,
         %{courier_principal_id: courier_principal_id} = state
       ) do
    with :ok <- within_ping_budget(courier_principal_id),
         {:ok, telemetry} <- data |> Mapper.telemetry_params() |> Telemetry.from_params(),
         :ok <- Tracking.track_location(courier_principal_id, telemetry) do
      :ok = publish_active_position(state.active_order, courier_principal_id, telemetry)
      {:push, {:text, Jason.encode!(Envelope.ack(request_id, %{accepted: true}))}, state}
    else
      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command(
         "courier.location.batch",
         request_id,
         %{"pings" => pings},
         %{courier_principal_id: courier_principal_id} = state
       )
       when is_list(pings) do
    normalized = Enum.map(pings, &Mapper.telemetry_params/1)

    with :ok <- within_batch_budget(courier_principal_id),
         {:ok, outcome} <- Tracking.record_offline_positions(courier_principal_id, normalized) do
      {:push,
       {:text, Jason.encode!(Envelope.ack(request_id, Mapper.offline_outcome_payload(outcome)))},
       state}
    else
      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command("courier.location.batch", request_id, _data, state) do
    {:push, {:text, Jason.encode!(Envelope.error(request_id, :invalid_batch))}, state}
  end

  defp dispatch_command(
         "courier.duty.set",
         request_id,
         %{"status" => status},
         %{courier_principal_id: courier_principal_id} = state
       ) do
    with {:ok, parsed} <- parse_status(status),
         {:ok, driver_state} <- Tracking.set_status(courier_principal_id, parsed) do
      {:push,
       {:text,
        Jason.encode!(Envelope.ack(request_id, %{status: Atom.to_string(driver_state.status)}))},
       state}
    else
      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command("courier.duty.set", request_id, _data, state) do
    {:push, {:text, Jason.encode!(Envelope.error(request_id, :invalid_status))}, state}
  end

  defp dispatch_command(
         "matching.job.pickup",
         request_id,
         %{"orderId" => order_id},
         %{courier_principal_id: courier_principal_id} = state
       )
       when is_integer(order_id) and order_id > 0 do
    case Dispatch.mark_picked_up(order_id, courier_principal_id) do
      {:ok, %Order{} = order} ->
        next_state = %{state | active_order: order}

        {:push,
         {:text, Jason.encode!(Envelope.ack(request_id, %{order: Mapper.order_payload(order)}))},
         next_state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command(
         "matching.job.podUpload",
         request_id,
         %{"orderId" => order_id} = data,
         %{courier_principal_id: courier_principal_id} = state
       )
       when is_integer(order_id) and order_id > 0 do
    case Dispatch.pod_upload(order_id, courier_principal_id, Map.get(data, "photoSha256")) do
      {:ok, upload} ->
        {:push,
         {:text, Jason.encode!(Envelope.ack(request_id, Mapper.pod_upload_payload(upload)))},
         state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command(
         "matching.job.delivered",
         request_id,
         %{"orderId" => order_id} = data,
         %{courier_principal_id: courier_principal_id} = state
       )
       when is_integer(order_id) and order_id > 0 do
    pod_attrs = Mapper.delivered_params(data)

    case Dispatch.mark_delivered(order_id, courier_principal_id, pod_attrs) do
      {:ok, %Order{} = order} ->
        next_state = %{state | active_order: nil}

        {:push,
         {:text, Jason.encode!(Envelope.ack(request_id, %{order: Mapper.order_payload(order)}))},
         next_state}

      {:error, reason} ->
        {:push, {:text, Jason.encode!(Envelope.error(request_id, reason))}, state}
    end
  end

  defp dispatch_command(event, request_id, _data, state)
       when event in ["matching.job.pickup", "matching.job.podUpload", "matching.job.delivered"] do
    {:push, {:text, Jason.encode!(Envelope.error(request_id, :invalid_order_id))}, state}
  end

  defp dispatch_command(_event, request_id, _data, state) do
    {:push, {:text, Jason.encode!(Envelope.error(request_id, :unknown_event))}, state}
  end

  @spec publish_active_position(Order.t() | nil, Types.principal_id(), Telemetry.t()) :: :ok
  defp publish_active_position(
         %Order{order_number: order_number, status: status},
         courier_principal_id,
         telemetry
       )
       when is_binary(order_number) and order_number != "" and status in [:assigned, :picked_up] do
    envelope =
      Envelope.server_event(
        "courier.location.updated",
        order_number,
        nil,
        Mapper.position_payload(courier_principal_id, telemetry)
      )

    _ = PositionPublisher.publish_position(order_number, envelope)
    :ok
  end

  defp publish_active_position(_order, _courier_principal_id, _telemetry), do: :ok

  @spec within_ping_budget(Types.principal_id()) :: :ok | {:error, :rate_limited}
  defp within_ping_budget(courier_principal_id) do
    within_budget("ping:#{courier_principal_id}", :ping_window_ms, :ping_limit)
  end

  @spec within_batch_budget(Types.principal_id()) :: :ok | {:error, :rate_limited}
  defp within_batch_budget(courier_principal_id) do
    within_budget("ping_batch:#{courier_principal_id}", :ping_batch_window_ms, :ping_batch_limit)
  end

  @spec within_budget(String.t(), atom(), atom()) :: :ok | {:error, :rate_limited}
  defp within_budget(key, window, limit) do
    config = Application.fetch_env!(:kinetix_matching, __MODULE__)

    key
    |> RateLimit.hit(Keyword.fetch!(config, window), Keyword.fetch!(config, limit))
    |> verdict()
  end

  @spec verdict({:allow, non_neg_integer()} | {:deny, non_neg_integer()}) ::
          :ok | {:error, :rate_limited}
  defp verdict({:allow, _count}), do: :ok
  defp verdict({:deny, _retry_after_ms}), do: {:error, :rate_limited}

  @spec parse_status(term()) :: {:ok, Types.driver_status()} | {:error, :invalid_status}
  defp parse_status(status) when is_binary(status) do
    case Enum.find(DriverState.statuses(), &(Atom.to_string(&1) == status)) do
      nil -> {:error, :invalid_status}
      known -> {:ok, known}
    end
  end

  defp parse_status(_status), do: {:error, :invalid_status}

  @spec order_number_of(Order.t() | nil) :: String.t() | nil
  defp order_number_of(nil), do: nil
  defp order_number_of(%Order{order_number: order_number}), do: order_number

  @spec sequence_of(Order.t() | nil) :: non_neg_integer() | nil
  defp sequence_of(nil), do: nil
  defp sequence_of(%Order{event_sequence: sequence}), do: sequence

  @spec order_or_nil(Order.t() | nil) :: map() | nil
  defp order_or_nil(nil), do: nil
  defp order_or_nil(%Order{} = order), do: Mapper.order_payload(order)

  @spec active_or_nil(Order.t()) :: Order.t() | nil
  defp active_or_nil(%Order{status: status} = order) when status in [:assigned, :picked_up],
    do: order

  defp active_or_nil(%Order{}), do: nil
end
