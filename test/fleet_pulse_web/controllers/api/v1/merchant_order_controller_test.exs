defmodule FleetPulseWeb.Api.V1.MerchantOrderControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  @merchant_uid 101

  setup %{conn: conn} do
    conn =
      conn
      |> authenticate(role: "seller", uid: @merchant_uid)
      |> put_req_header("accept", "application/json")

    %{conn: conn}
  end

  describe "POST /api/v1/merchant/orders" do
    test "creates an order successfully with valid params", %{conn: conn} do
      params = %{
        "order" => %{
          "pickup_latitude" => -6.2000,
          "pickup_longitude" => 106.8100,
          "dropoff_latitude" => -6.2100,
          "dropoff_longitude" => 106.8200,
          "weight_kg" => 12,
          "merchant_id" => 999
        }
      }

      conn = post(conn, ~p"/api/v1/merchant/orders", params)
      body = json_response(conn, 201)

      assert %{"id" => id, "status" => "pending", "merchant_id" => @merchant_uid} = body["data"]
      assert body["data"]["pickup"]["latitude"] == -6.2000
      assert body["data"]["dropoff"]["longitude"] == 106.8200
      assert is_integer(id)
    end

    test "returns 422 unprocessable_entity when required coordinates are missing", %{conn: conn} do
      params = %{
        "order" => %{
          "weight_kg" => 10
        }
      }

      conn = post(conn, ~p"/api/v1/merchant/orders", params)
      body = json_response(conn, 422)

      assert %{"errors" => errors} = body
      assert errors["pickup_latitude"] != nil
      assert errors["dropoff_latitude"] != nil
    end

    test "returns 401 unauthorized without a token" do
      params = %{
        "order" => %{
          "pickup_latitude" => -6.2000,
          "pickup_longitude" => 106.8100,
          "dropoff_latitude" => -6.2100,
          "dropoff_longitude" => 106.8200,
          "weight_kg" => 5
        }
      }

      conn =
        build_conn()
        |> put_req_header("accept", "application/json")
        |> post(~p"/api/v1/merchant/orders", params)

      assert json_response(conn, 401)["error"] == "unauthorized"
    end
  end
end
