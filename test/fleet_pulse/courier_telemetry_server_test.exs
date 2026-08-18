defmodule FleetPulse.CourierTelemetryServerTest do
  use ExUnit.Case, async: true
  alias FleetPulse.CourierTelemetryServer
  alias FleetPulse.Proto.Fleet.V1.DispatchCourierRequest

  test "dispatch_courier/2 handles dispatch requests from OMS" do
    req = %DispatchCourierRequest{
      merchant_api_key: "TEST_OMS_KEY",
      order_id: 888,
      order_number: "ORD-ELIXIR-888"
    }

    res = CourierTelemetryServer.dispatch_courier(req, nil)

    assert res.success == true
    assert String.starts_with?(res.dispatch_ref, "DISP-")
    assert res.assigned_driver_name == "Budi Santoso"
    assert res.eta_minutes == 12
  end
end
