defmodule FleetPulse.CourierTelemetryServer do
  @moduledoc """
  gRPC Server Handler receiving DispatchCourier RPCs from OMS Engine (fashion_fulfillment_oms).
  """

  use GRPC.Server, service: FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service
  require Logger

  @spec dispatch_courier(
          FleetPulse.Proto.Fleet.V1.DispatchCourierRequest.t(),
          GRPC.Server.Stream.t()
        ) :: FleetPulse.Proto.Fleet.V1.DispatchCourierResponse.t()
  def dispatch_courier(request, _stream) do
    Logger.info("[FleetPulse gRPC Server] Received DispatchCourier for Order #{request.order_number} (ID: #{request.order_id})")

    dispatch_ref = "DISP-" <> Integer.to_string(:rand.uniform(899_999) + 100_000)

    %FleetPulse.Proto.Fleet.V1.DispatchCourierResponse{
      success: true,
      dispatch_ref: dispatch_ref,
      assigned_driver_name: "Budi Santoso",
      assigned_driver_phone: "081299887766",
      vehicle: "Honda Vario 160",
      eta_minutes: 12
    }
  end
end
