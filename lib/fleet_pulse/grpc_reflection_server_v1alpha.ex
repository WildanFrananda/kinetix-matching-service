defmodule FleetPulse.GrpcReflectionServerV1alpha do
  @moduledoc """
  Server reflection, v1alpha.

  Registered alongside `FleetPulse.GrpcReflectionServer` because grpcurl falls back to v1alpha
  against servers that do not answer v1, and serving only one version makes this service look
  reflection-less to half the tooling.
  """
  use GrpcReflection.Server,
    version: :v1alpha,
    services: [
      FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service,
      FleetPulse.Proto.Shipping.V1.ShippingService.Service
    ]
end
