defmodule FleetPulseWeb.Api.V1.OrderControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  alias FleetPulse.Api
  alias FleetPulse.Dispatch

  setup %{conn: conn} do
    {:ok, _key, plaintext} = Api.create_key("Test")

    conn =
      conn
      |> put_req_header("authorization", "Bearer #{plaintext}")
      |> put_req_header("accept", "application/json")

    %{conn: conn}
  end

  test "GET /orders/:id returns an order", %{conn: conn} do
    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: -6.2,
        pickup_longitude: 106.8,
        dropoff_latitude: -6.9,
        dropoff_longitude: 107.6,
        weight_kg: 50
      })

    body = conn |> get(~p"/api/v1/orders/#{order.id}") |> json_response(200)
    assert body["data"]["id"] == order.id
    assert body["data"]["status"] == "pending"
    assert body["data"]["pickup"]["latitude"] == -6.2
  end

  test "GET /orders/:id is 404 for an unknown order", %{conn: conn} do
    assert conn |> get(~p"/api/v1/orders/999999") |> json_response(404)
  end
end
