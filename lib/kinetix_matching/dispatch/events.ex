defmodule KinetixMatching.Dispatch.Events do
  @moduledoc """
  Topic names and typed events for dispatch broadcasts.
  """

  alias KinetixMatching.Dispatch.Delivery, as: Order
  alias KinetixMatching.Types

  @pubsub KinetixMatching.PubSub

  @orders_topic "dispatch:orders"

  @typedoc "Every message a dispatch subscriber can receive."
  @type event ::
          {:order_assigned, Order.t()}
          | {:order_updated, Order.t()}
          | {:order_unassigned, Order.t()}

  @typedoc "Result of a subscription; mirrors `Phoenix.PubSub.subscribe/2`."
  @type subscribe_result :: :ok | {:error, {:already_registered, pid()}}

  @spec driver_topic(Types.principal_id()) :: String.t()
  def driver_topic(courier_principal_id), do: "dispatch:driver:#{courier_principal_id}"

  @spec subscribe_driver(Types.principal_id()) :: subscribe_result()
  def subscribe_driver(courier_principal_id) do
    Phoenix.PubSub.subscribe(@pubsub, driver_topic(courier_principal_id))
  end

  @spec broadcast(Types.principal_id(), event()) :: :ok
  def broadcast(courier_principal_id, event) do
    :ok = Phoenix.PubSub.broadcast(@pubsub, driver_topic(courier_principal_id), event)
  end

  @spec subscribe_orders() :: subscribe_result()
  def subscribe_orders do
    Phoenix.PubSub.subscribe(@pubsub, @orders_topic)
  end

  @spec broadcast_order(Order.t()) :: :ok
  def broadcast_order(%Order{} = order) do
    :ok = Phoenix.PubSub.broadcast(@pubsub, @orders_topic, {:order_changed, order})
  end
end
