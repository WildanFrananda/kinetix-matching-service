defmodule FleetPulse.CourierTelemetryServer do
  @moduledoc """
  gRPC Server Handler receiving DispatchCourier RPCs.
  """

  use GRPC.Server, service: FleetPulse.Proto.Fleet.V1.CourierTelemetryService.Service

  require Logger

  alias FleetPulse.Clients.Identity
  alias FleetPulse.Dispatch
  alias FleetPulse.Proto.Common.V1.ErrorDetail
  alias FleetPulse.Proto.Fleet.V1.DispatchCourierResponse
  alias FleetPulse.Tracking

  @spec dispatch_courier(
          FleetPulse.Proto.Fleet.V1.DispatchCourierRequest.t(),
          GRPC.Server.Stream.t()
        ) :: DispatchCourierResponse.t()
  def dispatch_courier(request, _stream) do
    Logger.info(
      "[FleetPulse gRPC Server] Received DispatchCourier for Order #{request.order_number} (ID: #{request.order_id})"
    )

    with {:ok, order} <-
           Dispatch.dispatch_for_order(
             request.order_number,
             request.merchant_principal_id,
             street(request.pickup_address),
             street(request.delivery_address)
           ),
         {:ok, driver} <- fetch_assigned_driver(order),
         {:ok, principal_id} <- payable_principal(order, driver) do
      Logger.info(
        "[FleetPulse gRPC Server] Order #{order.id} assigned to driver #{driver.id} (#{principal_id})"
      )

      %{full_name: full_name, phone_number: phone_number} = person(principal_id)

      %DispatchCourierResponse{
        success: true,
        dispatch_ref: "DISP-" <> Integer.to_string(order.id),
        assigned_driver_principal_id: principal_id,
        assigned_driver_name: full_name,
        assigned_driver_phone: phone_number,
        vehicle: driver.vehicle_plate || "",
        eta_minutes: 10
      }
    else
      {:error, reason} -> refuse(request, reason)
    end
  end

  @spec person(String.t()) :: FleetPulse.Clients.Identity.profile()
  defp person(principal_id) do
    case Identity.profile_of(principal_id) do
      {:ok, profile} ->
        profile

      {:error, reason} ->
        Logger.warning(
          "[Identity] dispatch names no driver for #{principal_id}: #{reason}. The assignment stands."
        )

        %{full_name: "", phone_number: ""}
    end
  end

  @spec street(FleetPulse.Proto.Common.V1.Address.t() | nil) :: String.t()
  defp street(%{street_address: street}) when is_binary(street), do: street
  defp street(_absent), do: ""

  @spec fetch_assigned_driver(FleetPulse.Dispatch.Order.t()) ::
          {:ok, FleetPulse.Tracking.Driver.t()} | {:error, :not_found}
  defp fetch_assigned_driver(%{driver_id: nil}), do: {:error, :not_found}
  defp fetch_assigned_driver(%{driver_id: driver_id}), do: Tracking.fetch_driver(driver_id)

  @spec payable_principal(FleetPulse.Dispatch.Order.t(), FleetPulse.Tracking.Driver.t()) ::
          {:ok, String.t()} | {:error, {:driver_not_payable, integer(), integer()}}
  defp payable_principal(_order, %{principal_id: principal_id})
       when is_binary(principal_id) and principal_id != "",
       do: {:ok, principal_id}

  defp payable_principal(order, driver),
    do: {:error, {:driver_not_payable, order.id, driver.id}}

  @spec refuse(FleetPulse.Proto.Fleet.V1.DispatchCourierRequest.t(), term()) ::
          DispatchCourierResponse.t()
  defp refuse(request, reason) do
    {code, message} = describe(reason)

    Logger.warning(
      "[FleetPulse gRPC Server] DispatchCourier refused for #{inspect(request.order_number)} " <>
        "(caller ref #{inspect(request.order_id)}): #{code} — #{message}"
    )

    %DispatchCourierResponse{
      success: false,
      dispatch_ref: "",
      assigned_driver_principal_id: "",
      assigned_driver_name: "",
      assigned_driver_phone: "",
      vehicle: "",
      eta_minutes: 0,
      error: %ErrorDetail{error_code: code, message: message}
    }
  end

  @spec describe(term()) :: {String.t(), String.t()}
  defp describe(:blank_order_number),
    do: {"BLANK_ORDER_NUMBER", "order_number is required: a fleet job delivers a named order"}

  defp describe(:order_already_finished),
    do: {"ORDER_ALREADY_FINISHED", "that order has already been delivered or cancelled"}

  defp describe({:not_geocodable, which, reason}) do
    {"ADDRESS_NOT_GEOCODABLE",
     "the #{which} address could not be turned into a location (#{reason}), so no driver can be " <>
       "chosen by distance. Dispatch refuses rather than guessing a point and sending a courier " <>
       "to the wrong place."}
  end

  defp describe(:not_found), do: {"NO_SUCH_ORDER", "no order with that id"}

  defp describe(:already_assigned),
    do: {"ALREADY_ASSIGNED", "that order already has a driver"}

  defp describe(:no_driver_available),
    do: {"NO_DRIVER_AVAILABLE", "no online driver is within range with enough capacity"}

  defp describe({:driver_not_payable, order_id, driver_id}) do
    {"DRIVER_NOT_PAYABLE",
     "order #{order_id} is assigned to driver #{driver_id}, who has no identity principal and " <>
       "cannot be paid. The assignment stands; link or reassign the driver."}
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> inspect()

    {"ASSIGNMENT_FAILED", "the assignment could not be written: #{details}"}
  end

  defp describe(other), do: {"DISPATCH_FAILED", inspect(other)}
end
