defmodule FleetPulse.Proto.Shipping.V1.EstimateShippingOptionsRequest do
  @moduledoc false

  use Protobuf,
    full_name: "shipping.v1.EstimateShippingOptionsRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :origin, 1, type: FleetPulse.Proto.Common.V1.GeoPoint
  field :destination, 2, type: FleetPulse.Proto.Common.V1.GeoPoint
  field :total_weight_grams, 3, type: :int64, json_name: "totalWeightGrams"
  field :merchant_principal_id, 4, type: :string, json_name: "merchantPrincipalId"
end

defmodule FleetPulse.Proto.Shipping.V1.CourierOption do
  @moduledoc false

  use Protobuf,
    full_name: "shipping.v1.CourierOption",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :service_tier, 1, type: :string, json_name: "serviceTier"
  field :service_name, 2, type: :string, json_name: "serviceName"
  field :distance_km, 3, type: :double, json_name: "distanceKm"

  field :base_shipping_fee, 4,
    type: FleetPulse.Proto.Common.V1.Money,
    json_name: "baseShippingFee"

  field :estimated_delivery_time, 5, type: :string, json_name: "estimatedDeliveryTime"
  field :is_available, 6, type: :bool, json_name: "isAvailable"
  field :unavailable_reason, 7, type: :string, json_name: "unavailableReason"
end

defmodule FleetPulse.Proto.Shipping.V1.EstimateShippingOptionsResponse do
  @moduledoc false

  use Protobuf,
    full_name: "shipping.v1.EstimateShippingOptionsResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :distance_km, 1, type: :double, json_name: "distanceKm"
  field :options, 2, repeated: true, type: FleetPulse.Proto.Shipping.V1.CourierOption
end

defmodule FleetPulse.Proto.Shipping.V1.ShippingService.Service do
  @moduledoc false

  use GRPC.Service, name: "shipping.v1.ShippingService", protoc_gen_elixir_version: "0.17.0"

  rpc :EstimateShippingOptions,
      FleetPulse.Proto.Shipping.V1.EstimateShippingOptionsRequest,
      FleetPulse.Proto.Shipping.V1.EstimateShippingOptionsResponse
end

defmodule FleetPulse.Proto.Shipping.V1.ShippingService.Stub do
  @moduledoc false

  use GRPC.Stub, service: FleetPulse.Proto.Shipping.V1.ShippingService.Service
end
