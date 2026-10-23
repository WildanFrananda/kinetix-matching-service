defmodule FleetPulseWeb.Api.V1.DriverControllerTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  setup %{conn: conn} do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))

    conn =
      conn
      |> authenticate(role: "admin")
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

  test "a seller is refused every courier's position", %{conn: conn} do
    track!(-6.2, 106.8)

    seller =
      conn
      |> recycle()
      |> authenticate(role: "seller")
      |> put_req_header("accept", "application/json")

    assert seller |> get(~p"/api/v1/drivers") |> json_response(403)

    assert seller
           |> recycle()
           |> authenticate(role: "seller")
           |> get(~p"/api/v1/drivers/nearby")
           |> json_response(403)
  end

  test "a nearby query that cannot be read is a bad request, not a crash", %{conn: conn} do
    assert %{"error" => "invalid_nearby_query"} =
             conn
             |> get(~p"/api/v1/drivers/nearby?latitude=north&longitude=106.8")
             |> json_response(400)
  end

  test "a list or a map where a number belongs is a bad request, not a crash", %{conn: conn} do
    for query <- [
          "latitude[]=1&longitude=106.8",
          "latitude[north]=1&longitude=106.8",
          "latitude=-6.2&longitude[]=106.8",
          "latitude=-6.2&longitude=106.8&radius_km[]=3",
          "latitude=-6.2&longitude=106.8&radius_km[wide]=3"
        ] do
      assert %{"error" => "invalid_nearby_query"} =
               conn
               |> get("/api/v1/drivers/nearby?" <> query)
               |> json_response(400),
             query
    end
  end

  test "a number followed by anything else is refused, not read up to where it stops",
       %{conn: conn} do
    for query <- [
          "latitude=-6.2abc&longitude=106.8",
          "latitude=-6.2&longitude=106.8east",
          "latitude=-6.2&longitude=106.8&radius_km=3km",
          "latitude=-6.2%20&longitude=106.8"
        ] do
      assert %{"error" => "invalid_nearby_query"} =
               conn
               |> get("/api/v1/drivers/nearby?" <> query)
               |> json_response(400),
             query
    end
  end

  test "a point off the globe or a radius that is not positive is refused", %{conn: conn} do
    for query <- [
          "latitude=90.5&longitude=106.8",
          "latitude=-91&longitude=106.8",
          "latitude=-6.2&longitude=180.1",
          "latitude=-6.2&longitude=-181",
          "latitude=-6.2&longitude=106.8&radius_km=0",
          "latitude=-6.2&longitude=106.8&radius_km=-3"
        ] do
      assert %{"error" => "invalid_nearby_query"} =
               conn
               |> get("/api/v1/drivers/nearby?" <> query)
               |> json_response(400),
             query
    end
  end

  test "whole numbers and the edges of the globe are read as points", %{conn: conn} do
    track!(-6.0, 107.0)

    for query <- [
          "latitude=-6&longitude=107",
          "latitude=90&longitude=180",
          "latitude=-90&longitude=-180&radius_km=1"
        ] do
      assert %{"data" => data} =
               conn
               |> get("/api/v1/drivers/nearby?" <> query)
               |> json_response(200),
             query

      assert is_list(data)
    end
  end
end
