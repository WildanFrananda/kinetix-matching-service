defmodule FleetPulseWeb.Api.V1.DriverControllerTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  setup %{conn: conn} do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    conn =
      conn
      |> authenticate(role: "seller")
      |> put_req_header("accept", "application/json")

    %{conn: conn}
  end

  defp track!(lat, lng) do
    driver = driver_fixture()
    {:ok, _} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(driver.id, %{
        latitude: lat,
        longitude: lng,
        recorded_at: DateTime.utc_now()
      })

    {:ok, _} = Tracking.fetch_state(driver.id)

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      StateCache.delete(driver.id)
    end)

    driver
  end

  test "GET /drivers lists tracked drivers", %{conn: conn} do
    driver = track!(-6.2, 106.8)
    body = conn |> get(~p"/api/v1/drivers") |> json_response(200)
    assert driver.id in Enum.map(body["data"], & &1["id"])
  end

  test "GET /drivers/:id returns one driver", %{conn: conn} do
    driver = track!(-6.2, 106.8)
    body = conn |> get(~p"/api/v1/drivers/#{driver.id}") |> json_response(200)
    assert body["data"]["id"] == driver.id
    assert body["data"]["coordinates"]["latitude"] == -6.2
  end

  test "GET /drivers/:id is 404 for an untracked driver", %{conn: conn} do
    assert conn |> get(~p"/api/v1/drivers/999999") |> json_response(404)
  end

  test "GET /drivers/nearby returns drivers with distance", %{conn: conn} do
    track!(-6.2, 106.8)

    body =
      conn
      |> get(~p"/api/v1/drivers/nearby?#{[latitude: -6.2, longitude: 106.8, radius_km: 3]}")
      |> json_response(200)

    assert body["data"] != []
    assert hd(body["data"])["distance_km"] >= 0
  end

  test "rejects a request without an API key" do
    body =
      build_conn()
      |> put_req_header("accept", "application/json")
      |> get(~p"/api/v1/drivers")
      |> json_response(401)

    assert body["error"] == "unauthorized"
  end
end
