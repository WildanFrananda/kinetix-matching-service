defmodule FleetPulseWeb.MerchantChannel do
  @moduledoc """
  Real-time Phoenix channel for merchant order status streaming.
  """

  use FleetPulseWeb, :channel

  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Types

  @typedoc "Serialized order data payload pushed to the merchant over WebSocket."
  @type order_payload :: %{
          id: Types.id(),
          status: Order.status(),
          merchant_id: Types.id() | nil,
          driver_id: Types.id() | nil,
          weight_kg: non_neg_integer() | nil,
          pickup: %{latitude: Types.latitude() | nil, longitude: Types.longitude() | nil},
          dropoff: %{latitude: Types.latitude() | nil, longitude: Types.longitude() | nil},
          assigned_at: DateTime.t() | nil
        }

  @impl Phoenix.Channel
  @spec join(String.t(), map(), Phoenix.Socket.t()) ::
          {:ok, Phoenix.Socket.t()} | {:error, %{reason: String.t()}}
  def join("merchant:" <> topic_id, _payload, socket) do
    with {:ok, merchant_id} <- parse_id(topic_id),
         :ok <- authorise(merchant_id, socket.assigns.merchant_id) do
      :ok = Events.subscribe_orders()
      {:ok, assign(socket, :merchant_id, merchant_id)}
    else
      {:error, reason} -> {:error, %{reason: to_reason(reason)}}
    end
  end

  def join(_topic, _payload, _socket), do: {:error, %{reason: "unknown_topic"}}

  @impl Phoenix.Channel
  @spec handle_info(term(), Phoenix.Socket.t()) :: {:noreply, Phoenix.Socket.t()}
  def handle_info({:order_changed, %Order{} = order}, socket) do
    if order.merchant_id == socket.assigns.merchant_id do
      push(socket, "order_updated", serialize_order(order))
    end

    {:noreply, socket}
  end

  def handle_info(_message, socket), do: {:noreply, socket}

  @spec parse_id(String.t()) :: {:ok, Types.id()} | {:error, :invalid_topic}
  defp parse_id(id_str) when is_binary(id_str) do
    case Integer.parse(id_str) do
      {id, ""} when id > 0 -> {:ok, id}
      _invalid -> {:error, :invalid_topic}
    end
  end

  @spec authorise(Types.id(), Types.id()) :: :ok | {:error, :forbidden}
  defp authorise(topic_merchant_id, socket_merchant_id) do
    if topic_merchant_id == socket_merchant_id do
      :ok
    else
      {:error, :forbidden}
    end
  end

  @spec serialize_order(Order.t()) :: order_payload()
  defp serialize_order(%Order{} = order) do
    %{
      id: order.id,
      status: order.status,
      merchant_id: order.merchant_id,
      driver_id: order.driver_id,
      weight_kg: order.weight_kg,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at
    }
  end

  @spec to_reason(:forbidden | :invalid_topic) :: String.t()
  defp to_reason(:forbidden), do: "forbidden"
  defp to_reason(:invalid_topic), do: "invalid_topic"
end
