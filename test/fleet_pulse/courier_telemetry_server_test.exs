defmodule FleetPulse.CourierTelemetryServerTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.CourierTelemetryServer
  alias FleetPulse.Dispatch
  alias FleetPulse.Proto.Fleet.V1.DispatchCourierRequest
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok
  end

  defp order_attrs do
    %{
      pickup_latitude: elem(@pickup, 0),
      pickup_longitude: elem(@pickup, 1),
      dropoff_latitude: -6.9,
      dropoff_longitude: 107.6,
      weight_kg: 50
    }
  end

  defp order! do
    {:ok, order} = Dispatch.create_order(order_attrs())
    order
  end

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
    {:ok, driver} = Tracking.link_driver_to_principal(driver_fixture(), principal)
    {track!(driver), principal}
  end

  defp dispatch(order_id) do
    CourierTelemetryServer.dispatch_courier(
      %DispatchCourierRequest{
        merchant_principal_id: "11111111-2222-3333-4444-555555555555",
        order_id: to_string(order_id),
        order_number: "ORD-ELIXIR-#{order_id}"
      },
      nil
    )
  end

  describe "a dispatch that succeeds" do
    test "answers with the driver's principal, which is who gets paid" do
      {driver, principal} = payable_driver()
      order = order!()

      res = dispatch(order.id)

      assert res.success == true
      assert res.assigned_driver_principal_id == principal
      assert res.assigned_driver_name == driver.name
      assert res.dispatch_ref == "DISP-#{order.id}"
    end

    test "writes the assignment, rather than only reporting one" do
      {driver, _principal} = payable_driver()
      order = order!()

      assert dispatch(order.id).success == true

      {:ok, reloaded} = Dispatch.fetch_order(order.id)
      assert reloaded.status == :assigned
      assert reloaded.driver_id == driver.id
    end
  end

  describe "a dispatch that fails" do
    test "refuses an order that does not exist" do
      payable_driver()

      res = dispatch(999_999)

      assert res.success == false
      assert res.error.error_code == "NO_SUCH_ORDER"
      assert res.assigned_driver_principal_id == ""
      assert res.assigned_driver_name == ""
      assert res.dispatch_ref == ""
    end

    test "refuses when no driver is available, rather than naming an offline one" do
      _idle = driver_fixture()
      order = order!()

      res = dispatch(order.id)

      assert res.success == false
      assert res.error.error_code == "NO_DRIVER_AVAILABLE"
      assert res.assigned_driver_name == ""
    end

    test "refuses an order that already has a driver" do
      payable_driver()
      order = order!()
      assert dispatch(order.id).success == true

      payable_driver()
      res = dispatch(order.id)

      assert res.success == false
      assert res.error.error_code == "ALREADY_ASSIGNED"
    end

    test "refuses an order_id that is not a number instead of raising" do
      res =
        CourierTelemetryServer.dispatch_courier(
          %DispatchCourierRequest{order_id: "not-a-number", order_number: "ORD-X"},
          nil
        )

      assert res.success == false
      assert res.error.error_code == "INVALID_ORDER_ID"
    end

    test "refuses an assignment to a driver who cannot be paid" do
      track!(driver_fixture())
      order = order!()

      res = dispatch(order.id)

      assert res.success == false
      assert res.error.error_code == "DRIVER_NOT_PAYABLE"
      assert res.assigned_driver_principal_id == ""
    end
  end
end
