defmodule FleetPulse.Servers.FleetRegistryServer do
  @moduledoc """
  gRPC handler for `fleet.v1.FleetRegistryService` — identity filing a vehicle, and identity saying
  an approved account may drive.
  """

  use GRPC.Server, service: FleetPulse.Proto.Fleet.V1.FleetRegistryService.Service

  require Logger

  alias FleetPulse.Proto.Common.V1.ErrorDetail
  alias FleetPulse.Proto.Fleet.V1.ActivateDriverResponse
  alias FleetPulse.Proto.Fleet.V1.RegisterDriverResponse
  alias FleetPulse.Tracking

  @spec register_driver(
          FleetPulse.Proto.Fleet.V1.RegisterDriverRequest.t(),
          GRPC.Server.Stream.t()
        ) :: RegisterDriverResponse.t()
  def register_driver(request, _stream) do
    with {:ok, principal_id} <- require_principal(request.principal_id),
         {:ok, plate} <- require_plate(request.vehicle_plate),
         {:ok, capacity} <- require_capacity(request.capacity_kg),
         {:ok, driver, outcome} <-
           Tracking.register_driver_for_principal(principal_id, %{
             vehicle_plate: plate,
             capacity_kg: capacity
           }) do
      Logger.info(
        "[FleetRegistry] #{outcome}: driver #{driver.id} for principal #{principal_id} " <>
          "(#{driver.vehicle_plate})"
      )

      %RegisterDriverResponse{
        success: true,
        driver_id: driver.id,
        already_registered: outcome == :existing
      }
    else
      {:error, reason} ->
        {code, message} = describe(reason)
        Logger.warning("[FleetRegistry] RegisterDriver refused: #{code} — #{message}")

        %RegisterDriverResponse{
          success: false,
          driver_id: 0,
          already_registered: false,
          error: %ErrorDetail{error_code: code, message: message}
        }
    end
  end

  @spec activate_driver(
          FleetPulse.Proto.Fleet.V1.ActivateDriverRequest.t(),
          GRPC.Server.Stream.t()
        ) :: ActivateDriverResponse.t()
  def activate_driver(request, _stream) do
    with {:ok, principal_id} <- require_principal(request.principal_id),
         {:ok, driver, outcome} <- Tracking.activate_driver(principal_id) do
      Logger.info("[FleetRegistry] #{outcome}: driver #{driver.id} for principal #{principal_id}")

      %ActivateDriverResponse{
        success: true,
        driver_id: driver.id,
        already_active: outcome == :already_active
      }
    else
      {:error, reason} ->
        {code, message} = describe(reason)
        Logger.warning("[FleetRegistry] ActivateDriver refused: #{code} — #{message}")

        %ActivateDriverResponse{
          success: false,
          driver_id: 0,
          already_active: false,
          error: %ErrorDetail{error_code: code, message: message}
        }
    end
  end

  @spec require_principal(String.t() | nil) :: {:ok, String.t()} | {:error, :blank_principal}
  defp require_principal(principal_id)
       when is_binary(principal_id) and principal_id != "",
       do: {:ok, principal_id}

  defp require_principal(_absent), do: {:error, :blank_principal}

  @spec require_plate(String.t() | nil) :: {:ok, String.t()} | {:error, :blank_plate}
  defp require_plate(plate) when is_binary(plate) do
    case String.trim(plate) do
      "" -> {:error, :blank_plate}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_plate(_absent), do: {:error, :blank_plate}

  @spec require_capacity(integer() | nil) :: {:ok, pos_integer()} | {:error, :no_capacity}
  defp require_capacity(capacity) when is_integer(capacity) and capacity > 0, do: {:ok, capacity}
  defp require_capacity(_absent_or_zero), do: {:error, :no_capacity}

  @spec describe(term()) :: {String.t(), String.t()}
  defp describe(:blank_principal),
    do:
      {"BLANK_PRINCIPAL",
       "principal_id is required: a fleet row belongs to an identity account, and the account is " <>
         "created before the vehicle is filed"}

  defp describe(:blank_plate),
    do: {"BLANK_VEHICLE_PLATE", "vehicle_plate is required: the fleet files a vehicle"}

  defp describe(:no_capacity),
    do:
      {"NO_CAPACITY",
       "capacity_kg must be greater than zero; a courier that can carry nothing would be " <>
         "dispatched and fail at the counter"}

  defp describe(:unlinked),
    do:
      {"NO_DRIVER_RECORD",
       "that principal has no vehicle in this fleet; register one before activating it"}

  defp describe(%Ecto.Changeset{} = changeset) do
    details =
      changeset
      |> Ecto.Changeset.traverse_errors(fn {msg, _opts} -> msg end)
      |> inspect()

    {"REGISTRATION_REFUSED", "the fleet row could not be written: #{details}"}
  end

  defp describe(other), do: {"FLEET_REGISTRY_FAILED", inspect(other)}
end
