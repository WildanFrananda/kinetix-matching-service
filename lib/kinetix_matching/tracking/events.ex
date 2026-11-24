defmodule KinetixMatching.Tracking.Events do
  @moduledoc """
  Topic names and typed events for tracking broadcasts.
  """

  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Types
  alias Phoenix.PubSub

  @pubsub KinetixMatching.PubSub
  @fleet_topic "tracking:fleet"

  @typedoc "Every message a tracking subscriber can receive."
  @type event :: {:driver_updated, DriverState.t()} | {:driver_stopped, Types.principal_id()}

  @typedoc "Result of a subscription."
  @type subscribe_result :: :ok | {:error, {:already_registered, pid()}}

  @spec fleet_topic() :: String.t()
  def fleet_topic, do: @fleet_topic

  @spec driver_topic(Types.principal_id() | term()) :: String.t()
  def driver_topic(courier_principal_id), do: "tracking:driver:#{courier_principal_id}"

  @spec subscribe_fleet() :: subscribe_result()
  def subscribe_fleet, do: PubSub.subscribe(@pubsub, @fleet_topic)

  @spec subscribe_driver(Types.principal_id()) :: subscribe_result()
  def subscribe_driver(courier_principal_id) do
    PubSub.subscribe(@pubsub, driver_topic(courier_principal_id))
  end

  @spec unsubscribe_fleet() :: :ok
  def unsubscribe_fleet, do: PubSub.unsubscribe(@pubsub, @fleet_topic)

  @spec unsubscribe_driver(Types.principal_id()) :: :ok
  def unsubscribe_driver(courier_principal_id) do
    PubSub.unsubscribe(@pubsub, driver_topic(courier_principal_id))
  end

  @spec broadcast(Types.principal_id(), event()) :: :ok
  def broadcast(courier_principal_id, event) do
    :ok = PubSub.broadcast(@pubsub, @fleet_topic, event)
    :ok = PubSub.broadcast(@pubsub, driver_topic(courier_principal_id), event)
  end
end
