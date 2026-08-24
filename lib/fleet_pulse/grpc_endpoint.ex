defmodule FleetPulse.GrpcEndpoint do
  @moduledoc """
  gRPC Endpoint routing RPC handlers to active services.
  """
  use GRPC.Endpoint

  run FleetPulse.CourierTelemetryServer
end
