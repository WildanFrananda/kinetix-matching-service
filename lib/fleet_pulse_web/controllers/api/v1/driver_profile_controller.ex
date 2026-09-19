defmodule FleetPulseWeb.Api.V1.DriverProfileController do
  @moduledoc """
  Where the caller stands in this fleet — "which driver am I, and may I work?"
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Security.AccessClaims
  alias FleetPulse.Tracking

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, _params) do
    %AccessClaims{principal_id: principal_id} = conn.assigns.current_caller

    case Tracking.driver_for_principal(principal_id) do
      {:ok, driver} ->
        json(conn, %{data: serialize(driver)})

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
    end
  end

  @spec refuse(Plug.Conn.t(), atom(), String.t(), String.t()) :: Plug.Conn.t()
  defp refuse(conn, status, error, message) do
    conn
    |> put_status(status)
    |> json(%{error: error, message: message})
  end

  @spec serialize(FleetPulse.Tracking.Driver.t()) :: map()
  defp serialize(driver) do
    %{
      id: driver.id,
      vehicle_plate: driver.vehicle_plate,
      capacity_kg: driver.capacity_kg,
      status: driver.status,
      active: driver.active
    }
  end
end
