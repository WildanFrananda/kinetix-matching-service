defmodule FleetPulse.GrpcEndpoint do
  @moduledoc """
  gRPC Endpoint routing RPC handlers to active services.
  """
  use GRPC.Endpoint

  run FleetPulse.CourierTelemetryServer
  run FleetPulse.Servers.ShippingServer
  run FleetPulse.GrpcReflectionServer
  run FleetPulse.GrpcReflectionServerV1alpha
end
