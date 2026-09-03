defmodule FleetPulseWeb.DriverRegistrationController do
  @moduledoc """
  API Endpoint for new driver registrations from the mobile app.
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Tracking

  @spec create(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def create(conn, params) do
    case Tracking.register_driver(params) do
      {:ok, driver} ->
        conn
        |> put_status(:created)
        |> json(%{
          message: "Registration successful. Your account is pending admin approval.",
          driver_id: driver.id
        })

      {:error, %Ecto.Changeset{} = changeset} ->
        errors = Ecto.Changeset.traverse_errors(changeset, fn {msg, _opts} -> msg end)

        conn
        |> put_status(:unprocessable_entity)
        |> json(%{errors: errors})
    end
  end
end
