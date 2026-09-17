defmodule FleetPulseWeb.DriverRegistrationControllerTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Tracking

  defp principal, do: "44444444-5555-6666-7777-#{System.unique_integer([:positive])}"

  defp register(conn, attrs), do: post(conn, ~p"/api/v1/driver/register", attrs)

  test "refuses a registration with no token", %{conn: conn} do
    body =
      conn
      |> put_req_header("accept", "application/json")
      |> register(driver_attrs())
      |> json_response(401)

    assert body["error"] == "unauthorized"
  end

  test "binds the new driver to the caller's own principal", %{conn: conn} do
    caller = principal()

    body =
      conn
      |> authenticate(sub: caller, role: "customer")
      |> put_req_header("accept", "application/json")
      |> register(driver_attrs())
      |> json_response(201)

    assert {:ok, driver} = Tracking.fetch_driver(body["driver_id"])
    assert driver.principal_id == caller
  end

  test "leaves the new driver inactive, pending a human", %{conn: conn} do
    body =
      conn
      |> authenticate(sub: principal(), role: "customer")
      |> put_req_header("accept", "application/json")
      |> register(driver_attrs())
      |> json_response(201)

    assert {:ok, driver} = Tracking.fetch_driver(body["driver_id"])
    assert driver.active == false
  end

  test "ignores a principal_id in the body and keeps the token's", %{conn: conn} do
    caller = principal()

    body =
      conn
      |> authenticate(sub: caller, role: "customer")
      |> put_req_header("accept", "application/json")
      |> register(driver_attrs(%{principal_id: "99999999-9999-9999-9999-999999999999"}))
      |> json_response(201)

    assert {:ok, driver} = Tracking.fetch_driver(body["driver_id"])
    assert driver.principal_id == caller
  end

  test "refuses a second driver row for the same principal", %{conn: conn} do
    caller = principal()

    authed =
      conn
      |> authenticate(sub: caller, role: "customer")
      |> put_req_header("accept", "application/json")

    assert authed |> register(driver_attrs()) |> json_response(201)

    assert build_conn()
           |> authenticate(sub: caller, role: "customer")
           |> put_req_header("accept", "application/json")
           |> register(driver_attrs())
           |> json_response(422)
  end
end
