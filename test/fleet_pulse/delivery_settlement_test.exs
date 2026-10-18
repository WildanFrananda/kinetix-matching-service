defmodule FleetPulse.DeliverySettlementTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.DeliveryProof
  import FleetPulse.TrackingFixtures

  alias FleetPulse.Clients.OrderGrpc
  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.DeliveryReporter
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.FakeOrder
  alias FleetPulse.FakeStorage
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
        {-6.2088, 106.8456},
        1_200
      )

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    result = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))
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
    {:ok, delivered} = Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

    assert delivered.status == :delivered
    assert FakeOrder.calls() == []
  end

  test "a driver with no identity principal cannot deliver, and nothing is reported" do
    driver = unlinked_driver_fixture()

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
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456}, 1_200)

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

    assert {:error, :unlinked} =
             Dispatch.mark_delivered(order.id, driver.id, proof_for(order.id))

    assert Repo.get(Order, order.id).status == :picked_up
    assert Repo.all(DeliveryEvidence) == []
    assert FakeOrder.calls() == []
  end

  test "a refused delivery reports nothing" do
    payable_driver()
    {impostor, _} = payable_driver()

    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456}, 1_200)

    assigned = order.driver_id
    refute assigned == nil
    {:ok, _} = Dispatch.mark_picked_up(order.id, assigned)

    other = if impostor.id == assigned, do: impostor.id + 1_000, else: impostor.id
    assert {:error, :forbidden} = Dispatch.mark_delivered(order.id, other, %{})
    assert FakeOrder.calls() == []
  end

  defp due_now(order) do
    Order
    |> Ecto.Query.where([o], o.id == ^order.id)
    |> Repo.update_all(
      set: [delivery_report_next_at: DateTime.add(DateTime.utc_now(), -1, :second)]
    )
  end

  defp sweep do
    start_supervised!(DeliveryReporter)
    DeliveryReporter.report_now()
  end

  test "a delivery order cannot be told about stays owed and comes due again" do
    FakeOrder.always({:error, :unavailable})
    number = "ORD-#{System.unique_integer([:positive])}"

    {{:ok, _delivered}, order, _driver, _principal} = deliver(number)

    owed = Repo.get(Order, order.id)
    assert owed.delivery_reported_at == nil
    assert owed.delivery_report_attempts == 1
    assert owed.delivery_report_error =~ "unavailable"
    assert DateTime.compare(owed.delivery_report_next_at, DateTime.utc_now()) == :gt
  end

  test "the reporter tells order once it answers, with the time the parcel was delivered" do
    FakeOrder.always({:error, :unavailable})
    number = "ORD-#{System.unique_integer([:positive])}"
    {{:ok, delivered}, order, _driver, principal} = deliver(number)

    FakeOrder.always(:ok)
    due_now(order)

    assert {:ok, 1} = sweep()

    reported = Repo.get(Order, order.id)
    assert reported.delivery_reported_at != nil
    assert reported.delivery_report_next_at == nil
    assert reported.delivery_report_error == nil
    assert FakeOrder.calls() == [{number, principal}, {number, principal}]
    assert FakeOrder.delivered_times() == [delivered.delivered_at, delivered.delivered_at]
  end

  test "a delivery order recorded is not reported again" do
    number = "ORD-#{System.unique_integer([:positive])}"
    {{:ok, _delivered}, order, _driver, _principal} = deliver(number)

    due_now(order)

    assert {:ok, 0} = sweep()
    assert length(FakeOrder.calls()) == 1
  end

  test "a refusal stops the reporting and keeps the reason" do
    FakeOrder.always({:error, :refused})
    number = "ORD-#{System.unique_integer([:positive])}"

    {{:ok, _delivered}, order, _driver, principal} = deliver(number)

    halted = Repo.get(Order, order.id)
    assert halted.delivery_report_next_at == nil
    assert halted.delivery_reported_at == nil
    assert halted.delivery_report_error == "order refused the delivery by #{principal}"
  end

  test "a delivery with no photo is refused and the parcel stays picked up" do
    {driver, _principal} = payable_driver()
    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456}, 1_200)

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)

    assert {:error, :invalid_proof} = Dispatch.mark_delivered(order.id, driver.id, %{})
    assert Repo.get(Order, order.id).status == :picked_up
    assert FakeOrder.calls() == []
  end

  test "only order's own decisions stop the reporting" do
    assert OrderGrpc.outcome_of(GRPC.Status.not_found()) == :refused
    assert OrderGrpc.outcome_of(GRPC.Status.failed_precondition()) == :refused
    assert OrderGrpc.outcome_of(GRPC.Status.invalid_argument()) == :refused
    assert OrderGrpc.outcome_of(GRPC.Status.unavailable()) == :unavailable
    assert OrderGrpc.outcome_of(GRPC.Status.deadline_exceeded()) == :unavailable
    assert OrderGrpc.outcome_of(GRPC.Status.permission_denied()) == :unavailable
    assert OrderGrpc.outcome_of(GRPC.Status.internal()) == :unavailable
  end

  test "a photo the bucket cannot be asked about is not taken on trust" do
    {driver, _principal} = payable_driver()
    number = "ORD-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.dispatch_for_order(number, "merchant-1", @pickup, {-6.2088, 106.8456}, 1_200)

    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    proof = proof_for(order.id)
    FakeStorage.unreachable()
    on_exit(&FakeStorage.reset/0)

    assert {:error, :proof_unverifiable} = Dispatch.mark_delivered(order.id, driver.id, proof)
    assert Repo.get(Order, order.id).status == :picked_up
    assert FakeOrder.calls() == []
  end
end
