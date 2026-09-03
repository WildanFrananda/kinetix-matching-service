defmodule FleetPulse.GrpcReflectionServer do
  @moduledoc """
  Server reflection, v1.

  Without this, a caller needs a local copy of courier_telemetry.proto to say anything to this
  port, and the platform gate cannot tell a live gRPC server from an open socket — which is
  exactly what it could not tell here: the port accepted connections and answered UNIMPLEMENTED
  to every reflection request.
  """
  use GrpcReflection.Server,
    version: :v1,
    services: [FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service]
end
