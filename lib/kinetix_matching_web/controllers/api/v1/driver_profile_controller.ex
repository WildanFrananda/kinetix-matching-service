defmodule KinetixMatchingWeb.Api.V1.DriverProfileController do
  @moduledoc """
  Where the caller stands in this fleet — "which courier am I, and may I work?"
  """

  use KinetixMatchingWeb, :controller

  alias KinetixMatching.Clients.Identity
  alias KinetixMatching.Security.AccessClaims
  alias KinetixMatching.Tracking

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    %AccessClaims{principal_id: principal_id} = conn.assigns.current_caller

    case Tracking.driver_for_principal(principal_id) do
      {:ok, standing} ->
        json(conn, %{data: serialize(standing)})

      {:error, :pending_approval} ->
        refuse(
          conn,
          :forbidden,
          "pending_approval",
          "this vehicle is filed and waiting for an administrator to approve the account"
        )

      {:error, :unlinked} ->
        refuse(
          conn,
          :not_found,
          "no_driver_record",
          "this account has no vehicle in this fleet yet"
        )

      {:error, :identity_unavailable} ->
        refuse(
          conn,
          :service_unavailable,
          "identity_unavailable",
          "identity service could not be reached to verify courier standing"
        )
    end
  end

  @spec refuse(Plug.Conn.t(), atom(), String.t(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end

  @spec serialize(Identity.standing()) :: map()
  defp serialize(standing) do
    %{
      courier_principal_id: standing.courier_principal_id,
      vehicle_plate: standing.vehicle_plate,
      capacity_kg: standing.capacity_kg,
      status: Tracking.live_status(standing.courier_principal_id),
      active: standing.may_drive
    }
  end
end
