defmodule FleetPulse.CourierTelemetryServerTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.CourierTelemetryServer
  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.FakeGeocoder
  alias FleetPulse.FakeIdentity
  alias FleetPulse.FakeOrder
  alias FleetPulse.Proto.Common.V1.Address
  alias FleetPulse.Proto.Fleet.V1.DispatchCourierRequest
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}
  @merchant "11111111-2222-3333-4444-555555555555"

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok = FakeGeocoder.start()
    :ok = FakeGeocoder.reset()
    FakeGeocoder.always({:ok, %{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)}})
    :ok = FakeOrder.start()
    :ok = FakeOrder.reset()
    :ok = FakeIdentity.start()
    :ok = FakeIdentity.reset()
    :ok
  end

  defp order_number, do: "ORD-#{System.unique_integer([:positive])}"

  defp track!(driver) do
    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      _ = StateCache.delete(driver.id)
    end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _driver} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(
        driver.id,
        telemetry_attrs(%{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)})
      )

    {:ok, _state} = Tracking.fetch_state(driver.id)
    driver
  end

  defp payable_driver do
    principal = "principal-#{System.unique_integer([:positive])}"
    {track!(active_driver_fixture(principal)), principal}
  end

  defp dispatch(number) do
    CourierTelemetryServer.dispatch_courier(
      %DispatchCourierRequest{
        merchant_principal_id: @merchant,
        order_id: "the caller's own id, not ours",
        order_number: number,
        pickup_address: %Address{street_address: "Gudang Kinetix, Jakarta"},
        delivery_address: %Address{street_address: "Jl. Sudirman 5, Jakarta"}
      },
      nil
    )
  end

  describe "a dispatch that succeeds" do
    test "books a fleet job for an order number it has never seen" do
      payable_driver()
      number = order_number()

      assert Repo.get_by(Order, order_number: number) == nil

      assert dispatch(number).success == true

      booked = Repo.get_by(Order, order_number: number)
      assert booked.status == :assigned
      assert booked.merchant_principal_id == @merchant
    end

    test "answers with the driver's principal, which is who gets paid" do
      {_driver, principal} = payable_driver()
      FakeIdentity.profile("Budi Santoso", "081200000000")

      res = dispatch(order_number())

      assert res.assigned_driver_principal_id == principal
      assert String.starts_with?(res.dispatch_ref, "DISP-")
    end

    test "names the driver from identity, not from a column here" do
      {_driver, principal} = payable_driver()
      FakeIdentity.profile("Budi Santoso", "081200000000")

      res = dispatch(order_number())

      assert res.assigned_driver_name == "Budi Santoso"
      assert res.assigned_driver_phone == "081200000000"
      assert FakeIdentity.calls() == [principal]
    end

    test "still assigns a driver when identity cannot be reached" do
      {_driver, principal} = payable_driver()
      FakeIdentity.always({:error, :unavailable})

      res = dispatch(order_number())

      assert res.success
      assert res.assigned_driver_principal_id == principal
      assert res.assigned_driver_name == ""
      assert res.assigned_driver_phone == ""
    end

    test "geocodes both ends, because drivers are chosen by distance" do
      payable_driver()

      dispatch(order_number())

      assert "gudang kinetix, jakarta" in FakeGeocoder.calls()
      assert "jl. sudirman 5, jakarta" in FakeGeocoder.calls()
    end

    test "a repeated dispatch finds the job it already booked" do
      payable_driver()
      number = order_number()

      first = dispatch(number)
      second = dispatch(number)

      assert first.success == true
      assert second.success == true
      assert first.dispatch_ref == second.dispatch_ref
      assert Repo.aggregate(Order, :count) == 1
    end
  end

  describe "a dispatch that fails" do
    test "refuses when no driver is available, rather than naming an offline one" do
      _idle = driver_fixture()

      res = dispatch(order_number())

      assert res.success == false
      assert res.error.error_code == "NO_DRIVER_AVAILABLE"
      assert res.assigned_driver_name == ""
      assert res.dispatch_ref == ""
    end

    test "refuses a dispatch that does not name an order" do
      payable_driver()

      res = dispatch("   ")

      assert res.success == false
      assert res.error.error_code == "BLANK_ORDER_NUMBER"
      assert Repo.aggregate(Order, :count) == 0
    end

    test "refuses when the address cannot be turned into a location" do
      payable_driver()
      FakeGeocoder.always({:error, :not_found})

      res = dispatch(order_number())

      assert res.success == false
      assert res.error.error_code == "ADDRESS_NOT_GEOCODABLE"
      assert Repo.aggregate(Order, :count) == 0
    end

    test "refuses when the geocoder is unreachable, rather than dispatching blind" do
      payable_driver()
      FakeGeocoder.always({:error, :unavailable})

      res = dispatch(order_number())

      assert res.success == false
      assert res.error.error_code == "ADDRESS_NOT_GEOCODABLE"
    end

    test "refuses an assignment to a driver who cannot be paid" do
      track!(driver_fixture())

      res = dispatch(order_number())

      assert res.success == false
      assert res.error.error_code == "DRIVER_NOT_PAYABLE"
      assert res.assigned_driver_principal_id == ""
    end

    test "refuses a job that has already been delivered" do
      {driver, _principal} = payable_driver()
      number = order_number()
      assert dispatch(number).success == true

      order = Repo.get_by(Order, order_number: number)
      {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
      {:ok, _} = Dispatch.mark_delivered(order.id, driver.id, %{})

      res = dispatch(number)

      assert res.success == false
      assert res.error.error_code == "ORDER_ALREADY_FINISHED"
    end
  end
end
