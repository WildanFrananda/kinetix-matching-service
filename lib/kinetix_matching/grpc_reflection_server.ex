defmodule KinetixMatching.GrpcReflectionServer do
  @moduledoc """
  Server reflection, v1.
  """
  use GrpcReflection.Server,
    version: :v1,
    services: [
      KinetixMatching.Proto.Fleet.V1.CourierTelemetryService.Service,
      KinetixMatching.Proto.Shipping.V1.ShippingService.Service,
      KinetixMatching.Proto.Fulfillment.V1.DeliveryEvidenceService.Service
    ]
end
