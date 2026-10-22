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

  defp eventually(fun, retries \\ 50) do
    cond do
      fun.() -> true
      retries == 0 -> false
      true -> Process.sleep(20) && eventually(fun, retries - 1)
    end
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

  test "auto-assigns a stranded order when a driver comes online, with no manual sweep" do
    :ok = stop_supervised(ReDispatcher)
    start_supervised!({ReDispatcher, debounce_ms: 20})

    order = order_at_pickup()
    assert {:ok, %{status: :pending}} = Dispatch.fetch_order(order.id)

    _driver = online_driver_at_pickup()

    assert eventually(fn ->
             match?({:ok, %{status: :assigned}}, Dispatch.fetch_order(order.id))
           end),
           "expected the stranded order to be auto-assigned within the debounce window"
  end

  test "a job taken off a courier is offered to another at once, not to the same one" do
    :ok = stop_supervised(ReDispatcher)
    start_supervised!({ReDispatcher, debounce_ms: 20})

    first = online_driver_at_pickup()
    order = order_at_pickup()
    {:ok, %{driver_id: taken_from}} = Dispatch.assign_order_to_driver(order.id, first.id)

    second = online_driver_at_pickup()
    {:ok, _pending} = Dispatch.unassign_order(order.id, "admin-principal")

    assert eventually(fn ->
             match?({:ok, %{status: :assigned}}, Dispatch.fetch_order(order.id))
           end)

    assert {:ok, %{driver_id: now_with}} = Dispatch.fetch_order(order.id)
    assert taken_from == first.id
    assert now_with == second.id
  end
end
