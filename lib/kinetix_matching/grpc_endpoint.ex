defmodule KinetixMatching.GrpcEndpoint do
  @moduledoc """
  gRPC Endpoint routing RPC handlers to active services.
  """
  use GRPC.Endpoint

  intercept(KinetixMatching.Observability.GrpcMetricsInterceptor)
  intercept(KinetixMatching.Observability.RequestIdInterceptor)
  intercept(KinetixMatching.Security.PeerAuthorizationInterceptor)

  run(KinetixMatching.CourierTelemetryServer)
  run(KinetixMatching.Servers.ShippingServer)
  run(KinetixMatching.Servers.DeliveryEvidenceServer)
  run(KinetixMatching.GrpcReflectionServer)
  run(KinetixMatching.GrpcReflectionServerV1alpha)
end
