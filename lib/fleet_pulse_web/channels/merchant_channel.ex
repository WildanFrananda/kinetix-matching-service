defmodule FleetPulseWeb.MerchantChannel do
  @moduledoc """
  The status of a merchant's own fleet jobs, live: `active_orders` once on join with every job not
  yet delivered or cancelled, then `order_updated` for each change. A message from the client is
  answered `unknown_event`: this channel only pushes.
  """

  use FleetPulseWeb, :channel

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Types

  @type order_payload :: %{
          id: Types.id(),
          order_number: String.t() | nil,
          awb_number: String.t() | nil,
          status: Order.status(),
          merchant_principal_id: String.t() | nil,
          driver_id: Types.id() | nil,
          weight_kg: non_neg_integer() | nil,
          pickup: %{latitude: Types.latitude() | nil, longitude: Types.longitude() | nil},
          dropoff: %{latitude: Types.latitude() | nil, longitude: Types.longitude() | nil},
          assigned_at: DateTime.t() | nil,
          delivered_at: DateTime.t() | nil
        }

  @impl Phoenix.Channel
  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, %{reason: String.t()}}
  def join("merchant:" <> topic_id, _payload, socket) do
    with {:ok, merchant_principal_id} <- parse_principal(topic_id),
         :ok <- authorise(merchant_principal_id, socket.assigns.merchant_principal_id) do
      :ok = Events.subscribe_orders()
      send(self(), :after_join)
      {:ok, assign(socket, :merchant_principal_id, merchant_principal_id)}
    else
      {:error, reason} -> {:error, %{reason: to_reason(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl Phoenix.Channel
  @spec handle_in(String.t(), term(), Phoenix.Socket.t()) ::
          {:reply, {:error, %{reason: String.t()}}, Phoenix.Socket.t()}
  def handle_in(_event, _payload, socket) do
    {:reply, {:error, %{reason: "unknown_event"}}, socket}
  end

  @impl Phoenix.Channel
  @spec handle_info(term(), Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def handle_info(:after_join, socket) do
    orders = Dispatch.list_active_orders_for_merchant(socket.assigns.merchant_principal_id)
    push(socket, "active_orders", %{orders: Enum.map(orders, &serialize_order/1)})
    {:noreply, socket}
  end

  def handle_info({:order_changed, %Order{} = order}, socket) do
    if order.merchant_principal_id == socket.assigns.merchant_principal_id do
      push(socket, "order_updated", serialize_order(order))
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @spec parse_principal(String.t()) :: {:ok, String.t()} | {:error, :invalid_topic}
  defp parse_principal(id_str) when is_binary(id_str) do
    trimmed = String.trim(id_str)

    if trimmed != "" and String.length(trimmed) <= 64 do
      {:ok, trimmed}
    else
      {:error, :invalid_topic}
    end
  end

  @spec authorise(String.t(), String.t()) :: :ok | {:error, :forbidden}
  defp authorise(topic_principal_id, socket_principal_id) do
    if topic_principal_id == socket_principal_id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @spec serialize_order(Order.t()) :: order_payload()
  defp serialize_order(%Order{} = order) do
    %{
      id: order.id,
      order_number: order.order_number,
      awb_number: order.awb_number,
      status: order.status,
      merchant_principal_id: order.merchant_principal_id,
      driver_id: order.driver_id,
      weight_kg: order.weight_kg,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at,
      delivered_at: order.delivered_at
    }
  end

  @spec to_reason(:forbidden | :invalid_topic) :: String.t()
  defp to_reason(:forbidden), do: "forbidden"
  defp to_reason(:invalid_topic), do: "invalid_topic"
end
