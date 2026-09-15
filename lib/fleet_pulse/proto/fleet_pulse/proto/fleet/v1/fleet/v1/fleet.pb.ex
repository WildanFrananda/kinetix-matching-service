defmodule FleetPulse.Proto.Fleet.V1.DispatchCourierRequest do
  @moduledoc false

  use Protobuf,
    full_name: "fleet.v1.DispatchCourierRequest",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :merchant_principal_id, 1, type: :string, json_name: "merchantPrincipalId"
  field :order_id, 2, type: :string, json_name: "orderId"
  field :order_number, 3, type: :string, json_name: "orderNumber"
  field :pickup_address, 4, type: FleetPulse.Proto.Common.V1.Address, json_name: "pickupAddress"

  field :delivery_address, 5,
    type: FleetPulse.Proto.Common.V1.Address,
    json_name: "deliveryAddress"

  field :idempotency_key, 6,
    type: FleetPulse.Proto.Common.V1.IdempotencyKey,
    json_name: "idempotencyKey"
end

defmodule FleetPulse.Proto.Fleet.V1.DispatchCourierResponse do
  @moduledoc false

  use Protobuf,
    full_name: "fleet.v1.DispatchCourierResponse",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :success, 1, type: :bool
  field :dispatch_ref, 2, type: :string, json_name: "dispatchRef"
  field :assigned_driver_principal_id, 3, type: :string, json_name: "assignedDriverPrincipalId"
  field :assigned_driver_name, 4, type: :string, json_name: "assignedDriverName"
  field :assigned_driver_phone, 5, type: :string, json_name: "assignedDriverPhone"
  field :vehicle, 6, type: :string
  field :eta_minutes, 7, type: :int32, json_name: "etaMinutes"
  field :error, 8, type: FleetPulse.Proto.Common.V1.ErrorDetail
end

defmodule FleetPulse.Proto.Fleet.V1.DriverLocationPing do
  @moduledoc false

  use Protobuf,
    full_name: "fleet.v1.DriverLocationPing",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :driver_principal_id, 1, type: :string, json_name: "driverPrincipalId"
  field :order_number, 2, type: :string, json_name: "orderNumber"
  field :location, 3, type: FleetPulse.Proto.Common.V1.GeoPoint
  field :speed_kmh, 4, type: :double, json_name: "speedKmh"
  field :status, 5, type: FleetPulse.Proto.Common.V1.CourierStatus, enum: true
  field :observed_at, 6, type: Google.Protobuf.Timestamp, json_name: "observedAt"
end

defmodule FleetPulse.Proto.Fleet.V1.DriverLocationAck do
  @moduledoc false

  use Protobuf,
    full_name: "fleet.v1.DriverLocationAck",
    protoc_gen_elixir_version: "0.17.0",
    syntax: :proto3

  field :driver_principal_id, 1, type: :string, json_name: "driverPrincipalId"
  field :received, 2, type: :bool
  field :server_time, 3, type: Google.Protobuf.Timestamp, json_name: "serverTime"
end

defmodule FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service do
  @moduledoc false

  use GRPC.Service, name: "fleet.v1.CourierTelemetryService", protoc_gen_elixir_version: "0.17.0"

  rpc :DispatchCourier,
      FleetPulse.Proto.Fleet.V1.DispatchCourierRequest,
      FleetPulse.Proto.Fleet.V1.DispatchCourierResponse

  rpc :StreamDriverLocation,
      stream(FleetPulse.Proto.Fleet.V1.DriverLocationPing),
      stream(FleetPulse.Proto.Fleet.V1.DriverLocationAck)
end

defmodule FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Stub do
  @moduledoc false

  use GRPC.Stub, service: FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service
end
