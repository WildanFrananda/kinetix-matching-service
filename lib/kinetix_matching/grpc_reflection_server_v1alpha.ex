defmodule KinetixMatching.GrpcReflectionServerV1alpha do
  @moduledoc """
  Server reflection, v1alpha.
  """
  use GrpcReflection.Server,
    version: :v1alpha,
    services: [
      KinetixMatching.Proto.Fleet.V1.CourierTelemetryService.Service,
      KinetixMatching.Proto.Shipping.V1.ShippingService.Service,
      KinetixMatching.Proto.Fulfillment.V1.DeliveryEvidenceService.Service
    ]
end
