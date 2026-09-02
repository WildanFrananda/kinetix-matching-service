defmodule FleetPulse.Proto.Common.V1.Address do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :recipient_name, 1, type: :string, json_name: "recipientName"
  field :phone_number, 2, type: :string, json_name: "phoneNumber"
  field :street_address, 3, type: :string, json_name: "streetAddress"
  field :city, 4, type: :string
  field :postal_code, 5, type: :string, json_name: "postalCode"
end

defmodule FleetPulse.Proto.Fleet.V1.DispatchCourierRequest do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :merchant_api_key, 1, type: :string, json_name: "merchantApiKey"
  field :order_id, 2, type: :int64, json_name: "orderId"
  field :order_number, 3, type: :string, json_name: "orderNumber"
  field :pickup_address, 4, type: FleetPulse.Proto.Common.V1.Address, json_name: "pickupAddress"
  field :delivery_address, 5, type: FleetPulse.Proto.Common.V1.Address, json_name: "deliveryAddress"
end

defmodule FleetPulse.Proto.Fleet.V1.DispatchCourierResponse do
  @moduledoc false
  use Protobuf, syntax: :proto3

  field :success, 1, type: :bool
  field :dispatch_ref, 2, type: :string, json_name: "dispatchRef"
  field :assigned_driver_name, 3, type: :string, json_name: "assignedDriverName"
  field :assigned_driver_phone, 4, type: :string, json_name: "assignedDriverPhone"
  field :vehicle, 5, type: :string
  field :eta_minutes, 6, type: :int32, json_name: "etaMinutes"
end

defmodule FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service do
  @moduledoc false
  use GRPC.Service, name: "fleet.v1.CourierTelemetryService"

  rpc :DispatchCourier,
      FleetPulse.Proto.Fleet.V1.DispatchCourierRequest,
      FleetPulse.Proto.Fleet.V1.DispatchCourierResponse
end

defmodule FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Stub do
  @moduledoc false
  use GRPC.Stub, service: FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service
end
