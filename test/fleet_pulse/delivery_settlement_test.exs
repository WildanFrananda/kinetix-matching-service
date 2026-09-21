defmodule FleetPulse.DeliverySettlementTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.FakeOrder
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok = FakeOrder.start()
    :ok = FakeOrder.reset()
    :ok
  end

  defp payable_driver do
    principal = "principal-#{System.unique_integer([:positive])}"
    driver = active_driver_fixture(principal)

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      _ = StateCache.delete(driver.id)
    end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(
        driver.id,
        telemetry_attrs(%{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)})
      )

    {:ok, _state} = Tracking.fetch_state(driver.id)
    {driver, principal}
  end

  defp deliver(order_number) do
    {driver, principal} = payable_driver()

    {:ok, order} =
      Dispatch.dispatch_for_order(
        order_number,
        "merchant-1",
        @pickup,
        {-6.2088, 106.8456}
      )

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    result = Dispatch.mark_delivered(order.id, driver.id, %{})
    {result, order, driver, principal}
  end

  test "a delivery is reported to order, naming the courier who made it" do
    number = "ORD-#{System.unique_integer([:positive])}"

    {{:ok, delivered}, _order, _driver, principal} = deliver(number)

    assert delivered.status == :delivered
    assert FakeOrder.calls() == [{number, principal}]
  end

  test "order being unreachable does not un-deliver the order" do
    FakeOrder.always({:error, :unavailable})
    number = "ORD-#{System.unique_integer([:positive])}"

    {{:ok, delivered}, order, _driver, _principal} = deliver(number)

    assert delivered.status == :delivered
    assert Repo.get(Order, order.id).status == :delivered
  end

  test "order refusing the report does not un-deliver the order" do
    FakeOrder.always({:error, :refused})
    number = "ORD-#{System.unique_integer([:positive])}"

    {{:ok, delivered}, _order, _driver, _principal} = deliver(number)

    assert delivered.status == :delivered
  end

  test "a fleet job with no order number reports nothing" do
    {driver, _principal} = payable_driver()

    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: elem(@pickup, 0),
        pickup_longitude: elem(@pickup, 1),
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 10
      })

    {:ok, _} = Dispatch.assign_order_to_driver(order.id, driver.id)
    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    {:ok, delivered} = Dispatch.mark_delivered(order.id, driver.id, %{})

    assert delivered.status == :delivered
    assert FakeOrder.calls() == []
  end

  test "a driver with no identity principal is not reported" do
    driver = driver_fixture()

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      _ = StateCache.delete(driver.id)
    end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(
        driver.id,
        telemetry_attrs(%{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)})
      )

    {:ok, _state} = Tracking.fetch_state(driver.id)

    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456})

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    {:ok, delivered} = Dispatch.mark_delivered(order.id, driver.id, %{})

    assert delivered.status == :delivered
    assert FakeOrder.calls() == []
  end

  test "a refused delivery reports nothing" do
    payable_driver()
    {impostor, _} = payable_driver()

    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456})

    assigned = order.driver_id
    refute assigned == nil
    {:ok, _} = Dispatch.mark_picked_up(order.id, assigned)

    other = if impostor.id == assigned, do: impostor.id + 1_000, else: impostor.id
    assert {:error, :forbidden} = Dispatch.mark_delivered(order.id, other, %{})
    assert FakeOrder.calls() == []
  end
end
