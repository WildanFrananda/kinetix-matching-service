defmodule FleetPulseWeb.Api.V1.ShippingControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  describe "POST /api/v1/matching/shipping/options" do
    test "returns shipping options successfully", %{conn: conn} do
      api_key = create_api_key()

      conn =
        conn
        |> put_req_header("x-api-key", api_key.key)
        |> post(~p"/api/v1/shipping/options", %{
          "origin" => %{"latitude" => -6.2088, "longitude" => 106.8456},
          "destination" => %{"latitude" => -6.2500, "longitude" => 106.8800},
          "total_weight_kg" => 2.5
        })

      assert json_response(conn, 200)["distance_km"] > 0
      options = json_response(conn, 200)["options"]
      assert length(options) == 4
    end
  end

  defp create_api_key do
    {:ok, key} = FleetPulse.Api.create_key(%{name: "Test Client"})
    key
  end
end
