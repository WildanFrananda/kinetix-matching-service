defmodule FleetPulse.Dispatch.ReDispatcherTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.ReDispatcher
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    start_supervised!(ReDispatcher)
    :ok
  end

  defp order_at_pickup do
    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: elem(@pickup, 0),
        pickup_longitude: elem(@pickup, 1),
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 50
      })

    order
  end

  defp online_driver_at_pickup do
    driver = driver_fixture()
    {:ok, _} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(driver.id, %{
        latitude: elem(@pickup, 0),
        longitude: elem(@pickup, 1),
        recorded_at: DateTime.utc_now()
      })

    {:ok, _} = Tracking.fetch_state(driver.id)

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      StateCache.delete(driver.id)
    end)

    driver
  end

  test "assigns a stranded pending order once a driver becomes available" do
    order = order_at_pickup()
    assert {:ok, %{status: :pending}} = Dispatch.fetch_order(order.id)

    driver = online_driver_at_pickup()
    assert {:ok, 1} = ReDispatcher.sweep_now()

    assert {:ok, %{status: :assigned, driver_id: id}} = Dispatch.fetch_order(order.id)
    assert id == driver.id
  end

  test "does nothing when there are no pending orders" do
    _driver = online_driver_at_pickup()
    assert {:ok, 0} = ReDispatcher.sweep_now()
  end

  test "leaves an order pending when no driver is in range" do
    order = order_at_pickup()

    assert {:ok, 0} = ReDispatcher.sweep_now()
    assert {:ok, %{status: :pending}} = Dispatch.fetch_order(order.id)
  end
end
