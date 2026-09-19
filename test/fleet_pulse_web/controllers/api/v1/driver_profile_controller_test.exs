defmodule FleetPulseWeb.Api.V1.DriverProfileControllerTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  defp principal, do: "principal-#{System.unique_integer([:positive])}"

  defp get_me(conn), do: get(conn, ~p"/api/v1/driver/me")

  defp authed(sub) do
    build_conn()
    |> authenticate(sub: sub, role: "courier")
    |> put_req_header("accept", "application/json")
  end

  test "refuses a request with no token" do
    body =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get_me()
      |> json_response(401)

    assert body["error"] == "unauthorized"
  end

  test "answers with the caller's own driver row" do
    sub = principal()
    driver = active_driver_fixture(sub)

    body = authed(sub) |> get_me() |> json_response(200)

    assert body["data"]["id"] == driver.id
    assert body["data"]["vehicle_plate"] == driver.vehicle_plate
    assert body["data"]["active"] == true
  end

  test "does not answer with the driver's name or phone number" do
    sub = principal()
    _driver = active_driver_fixture(sub)

    body = authed(sub) |> get_me() |> json_response(200)

    refute Map.has_key?(body["data"], "name")
    refute Map.has_key?(body["data"], "phone")
  end

  test "never answers with somebody else's row" do
    mine = principal()
    my_driver = active_driver_fixture(mine)

    theirs = principal()
    their_driver = active_driver_fixture(theirs)

    body = authed(mine) |> get_me() |> json_response(200)

    assert body["data"]["id"] == my_driver.id
    refute body["data"]["id"] == their_driver.id
  end

  test "tells a registered driver it is waiting for approval" do
    sub = principal()
    _pending = registered_driver_fixture(sub)

    body = authed(sub) |> get_me() |> json_response(403)

    assert body["error"] == "pending_approval"
  end

  test "tells an account with no vehicle that it has none" do
    body = authed(principal()) |> get_me() |> json_response(404)

    assert body["error"] == "no_driver_record"
  end

  test "the two refusals are different, so the app can act on one of them" do
    filed = principal()
    _pending = registered_driver_fixture(filed)

    pending = authed(filed) |> get_me() |> json_response(403)
    absent = authed(principal()) |> get_me() |> json_response(404)

    refute pending["error"] == absent["error"]
  end
end
