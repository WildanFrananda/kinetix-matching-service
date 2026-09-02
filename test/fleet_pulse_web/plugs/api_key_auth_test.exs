defmodule FleetPulseWeb.Plugs.ApiKeyAuthTest do
  use FleetPulseWeb.ConnCase, async: true

  alias FleetPulse.Api
  alias FleetPulseWeb.Plugs.ApiKeyAuth

  setup do
    {:ok, _key, plaintext} = Api.create_key("Test")
    %{key: plaintext}
  end

  defp call(conn), do: ApiKeyAuth.call(conn, ApiKeyAuth.init([]))

  test "assigns the api key for a valid Bearer token", %{conn: conn, key: key} do
    conn = conn |> put_req_header("authorization", "Bearer #{key}") |> call()

    refute conn.halted
    assert conn.assigns.api_key
  end

  test "rejects a missing header with 401", %{conn: conn} do
    conn = call(conn)

    assert conn.halted
    assert json_response(conn, 401)["error"] == "unauthorized"
  end

  test "rejects an invalid key with 401", %{conn: conn} do
    conn = conn |> put_req_header("authorization", "Bearer wrong") |> call()

    assert conn.halted
    assert json_response(conn, 401)["error"] == "unauthorized"
  end
end
