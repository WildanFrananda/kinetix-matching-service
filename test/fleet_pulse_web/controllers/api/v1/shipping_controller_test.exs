defmodule FleetPulseWeb.Api.V1.ShippingControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  @quote %{
    "origin" => %{"latitude" => -6.2088, "longitude" => 106.8456},
    "destination" => %{"latitude" => -6.2500, "longitude" => 106.8800},
    "total_weight_kg" => 2.5
  }

  describe "POST /api/v1/shipping/options" do
    test "returns shipping options successfully", %{conn: conn} do
      conn =
        conn
        |> authenticate(role: "customer")
        |> post(~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 200)["distance_km"] > 0
      assert length(json_response(conn, 200)["options"]) == 4
    end

    test "is reachable by a customer, unlike the fleet routes", %{conn: conn} do
      customer = authenticate(conn, role: "customer")

      assert customer |> post(~p"/api/v1/shipping/options", @quote) |> json_response(200)
      assert customer |> get(~p"/api/v1/drivers") |> json_response(403)
    end

    test "refuses a request with no token", %{conn: conn} do
      conn = post(conn, ~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "refuses a refresh token, which is long-lived by design", %{conn: conn} do
      conn =
        conn
        |> authenticate(role: "customer", token_use: "refresh")
        |> post(~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "refuses an expired token", %{conn: conn} do
      conn =
        conn
        |> authenticate(role: "customer", exp: System.system_time(:second) - 1)
        |> post(~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "refuses a token minted for another issuer", %{conn: conn} do
      conn =
        conn
        |> authenticate(role: "customer", iss: "https://someone-else.example")
        |> post(~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end

    test "refuses a token signed by a key identity did not publish", %{conn: conn} do
      forged = JOSE.JWK.generate_key({:rsa, 2048})

      conn =
        conn
        |> authenticate(role: "customer", key: forged)
        |> post(~p"/api/v1/shipping/options", @quote)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
