defmodule KinetixMatching.CourierTelemetryServer do
  @moduledoc """
  gRPC Server Handler receiving DispatchCourier RPCs.
  """

  use GRPC.Server, service: KinetixMatching.Proto.Fleet.V1.CourierTelemetryService.Service

  require Logger

  alias KinetixMatching.Dispatch
  alias KinetixMatching.Proto.Common.V1.ErrorDetail
  alias KinetixMatching.Proto.Fleet.V1.DispatchCourierResponse
  alias KinetixMatching.Tracking

  @spec dispatch_courier(
          KinetixMatching.Proto.Fleet.V1.DispatchCourierRequest.t(),
          GRPC.Server.Stream.t()
        ) :: DispatchCourierResponse.t()
  def dispatch_courier(request, _stream) do
    Logger.info(
      "[KinetixMatching gRPC Server] Received DispatchCourier for Order #{request.order_number} (ID: #{request.order_id})"
    )

    with {:ok, order} <-
           Dispatch.dispatch_for_order(
             request.order_number,
             request.merchant_principal_id,
             point(request.pickup_point),
             point(request.delivery_point),
             request.parcel_weight_grams
           ),
         {:ok, driver} <- fetch_assigned_driver(order),
         {:ok, principal_id} <- payable_principal(order, driver) do
      Logger.info(
        "[KinetixMatching gRPC Server] Order #{order.id} assigned to driver #{driver.id} (#{principal_id})"
      )

      %DispatchCourierResponse{
        success: true,
        dispatch_ref: "DISP-" <> Integer.to_string(order.id),
        assigned_driver_principal_id: principal_id,
        vehicle: driver.vehicle_plate || "",
        awb_number: order.awb_number || ""
      }
    else
      {:error, reason} -> refuse(request, reason)
    end
  end

  @spec point(term()) :: KinetixMatching.Dispatch.point() | nil
  defp point(%{latitude: latitude, longitude: longitude})
       when is_float(latitude) and is_float(longitude) and
              (latitude != 0.0 or longitude != 0.0),
       do: {latitude, longitude}

  defp point(_absent), do: nil

  @spec fetch_assigned_driver(KinetixMatching.Dispatch.Order.t()) ::
          {:ok, KinetixMatching.Tracking.Driver.t()} | {:error, :not_found}
  defp fetch_assigned_driver(%{driver_id: nil}), do: {:error, :not_found}
  defp fetch_assigned_driver(%{driver_id: driver_id}), do: Tracking.fetch_driver(driver_id)

  @spec payable_principal(KinetixMatching.Dispatch.Order.t(), KinetixMatching.Tracking.Driver.t()) ::
          {:ok, String.t()} | {:error, {:driver_not_payable, integer(), integer()}}
  defp payable_principal(_order, %{principal_id: principal_id})
       when is_binary(principal_id) and principal_id != "",
       do: {:ok, principal_id}

  defp payable_principal(order, driver),
    do: {:error, {:driver_not_payable, order.id, driver.id}}

  @spec refuse(KinetixMatching.Proto.Fleet.V1.DispatchCourierRequest.t(), term()) ::
          DispatchCourierResponse.t()
  defp refuse(request, reason) do
    {code, message} = describe(reason)

    Logger.warning(
      "[KinetixMatching gRPC Server] DispatchCourier refused for #{inspect(request.order_number)} " <>
        "(caller ref #{inspect(request.order_id)}): #{code} — #{message}"
    )

    %DispatchCourierResponse{
      success: false,
      dispatch_ref: "",
      assigned_driver_principal_id: "",
      assigned_driver_name: "",
      assigned_driver_phone: "",
      vehicle: "",
      error: %ErrorDetail{error_code: code, message: message}
    }
  end

  @spec describe(term()) :: {String.t(), String.t()} | no_return()
  defp describe(:blank_order_number),
    do: {"BLANK_ORDER_NUMBER", "order_number is required: a fleet job delivers a named order"}

  defp describe(:negative_parcel_weight),
    do: {"INVALID_PARCEL_WEIGHT", "parcel_weight_grams cannot be negative"}

  defp describe(:order_already_finished),
    do: {"ORDER_ALREADY_FINISHED", "that order has already been delivered or cancelled"}

  defp describe({:no_point, which}) do
    {
      "NO_POINT",
      "no #{which} point was given, so no driver can be chosen by distance. The caller owns the " <>
        "address and the point it resolves to; dispatch refuses rather than sending a courier to " <>
        "0,0, which is a real place in the Atlantic."
    }
  end

  defp describe(:not_found), do: {"NO_SUCH_ORDER", "no order with that id"}

  defp describe(:already_assigned),
    do: {"ALREADY_ASSIGNED", "that order already has a driver"}

  defp describe(:no_driver_available),
    do: {"NO_DRIVER_AVAILABLE", "no online driver is within range with enough capacity"}

  defp describe({:driver_not_payable, order_id, driver_id}) do
    {
      "DRIVER_NOT_PAYABLE",
      "order #{order_id} is assigned to driver #{driver_id}, who has no identity principal and " <>
        "cannot be paid. The assignment stands; link or reassign the driver."
    }
  end

  defp describe(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> inspect()

    {"ASSIGNMENT_FAILED", "the assignment could not be written: #{details}"}
  end

  defp describe(other) do
    raise GRPC.RPCError,
      status: GRPC.Status.internal(),
      message: "dispatch failed in a way it does not answer for: #{inspect(other)}"
  end
end
