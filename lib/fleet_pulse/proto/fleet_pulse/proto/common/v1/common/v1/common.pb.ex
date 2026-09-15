defmodule FleetPulse.Proto.Common.V1.OrderStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "common.v1.OrderStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :ORDER_STATUS_UNSPECIFIED, 0
  field :ORDER_STATUS_PENDING_PAYMENT, 1
  field :ORDER_STATUS_PAID, 2
  field :ORDER_STATUS_RECEIVED, 3
  field :ORDER_STATUS_PACKING, 4
  field :ORDER_STATUS_PACKED, 5
  field :ORDER_STATUS_ASSIGNED, 6
  field :ORDER_STATUS_DISPATCHED, 7
  field :ORDER_STATUS_IN_TRANSIT, 8
  field :ORDER_STATUS_DELIVERED, 9
  field :ORDER_STATUS_COMPLETED, 10
  field :ORDER_STATUS_CANCELLED, 11
  field :ORDER_STATUS_REFUNDED, 12
end

defmodule FleetPulse.Proto.Common.V1.CourierStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "common.v1.CourierStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :COURIER_STATUS_UNSPECIFIED, 0
  field :COURIER_STATUS_IDLE, 1
  field :COURIER_STATUS_ASSIGNED, 2
  field :COURIER_STATUS_EN_ROUTE_PICKUP, 3
  field :COURIER_STATUS_PICKED_UP, 4
  field :COURIER_STATUS_EN_ROUTE_DELIVERY, 5
  field :COURIER_STATUS_COMPLETED, 6
end

defmodule FleetPulse.Proto.Common.V1.ReturnStatus do
  @moduledoc false

  use Protobuf,
    enum: true,
    full_name: "common.v1.ReturnStatus",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :RETURN_STATUS_UNSPECIFIED, 0
  field :RETURN_STATUS_REQUESTED, 1
  field :RETURN_STATUS_PICKED_UP_FROM_BUYER, 2
  field :RETURN_STATUS_RECEIVED_AT_WAREHOUSE, 3
  field :RETURN_STATUS_INSPECTED, 4
  field :RETURN_STATUS_RESOLVED, 5
  field :RETURN_STATUS_REJECTED, 6
end

defmodule FleetPulse.Proto.Common.V1.Money do
  @moduledoc false

  use Protobuf, full_name: "common.v1.Money", protoc_gen_elixir_version: "0.17.0", syntax: :proto3

  field :amount_minor, 1, type: :int64, json_name: "amountMinor"
  field :currency, 2, type: :string
end

defmodule FleetPulse.Proto.Common.V1.GeoPoint do
  @moduledoc false

  use Protobuf,
    full_name: "common.v1.GeoPoint",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :latitude, 1, type: :double
  field :longitude, 2, type: :double
end

defmodule FleetPulse.Proto.Common.V1.Address do
  @moduledoc false

  use Protobuf,
    full_name: "common.v1.Address",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :recipient_name, 1, type: :string, json_name: "recipientName"
  field :phone_number, 2, type: :string, json_name: "phoneNumber"
  field :street_address, 3, type: :string, json_name: "streetAddress"
  field :city, 4, type: :string
  field :postal_code, 5, type: :string, json_name: "postalCode"
  field :location, 6, type: FleetPulse.Proto.Common.V1.GeoPoint
end

defmodule FleetPulse.Proto.Common.V1.OrderItem do
  @moduledoc false

  use Protobuf,
    full_name: "common.v1.OrderItem",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :sku, 1, type: :string
  field :product_name, 2, type: :string, json_name: "productName"
  field :quantity, 3, type: :int32
  field :unit_price, 4, type: FleetPulse.Proto.Common.V1.Money, json_name: "unitPrice"
  field :bin_location, 5, type: :string, json_name: "binLocation"
end

defmodule FleetPulse.Proto.Common.V1.ErrorDetail do
  @moduledoc false

  use Protobuf,
    full_name: "common.v1.ErrorDetail",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :error_code, 1, type: :string, json_name: "errorCode"
  field :message, 2, type: :string
  field :field_violations, 3, repeated: true, type: :string, json_name: "fieldViolations"
end

defmodule FleetPulse.Proto.Common.V1.IdempotencyKey do
  @moduledoc false

  use Protobuf,
    full_name: "common.v1.IdempotencyKey",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :key, 1, type: :string
end
