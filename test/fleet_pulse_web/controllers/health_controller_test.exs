defmodule FleetPulseWeb.HealthControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  test "GET /health is alive without touching the database", %{conn: conn} do
    assert response(get(conn, ~p"/health"), 200) == "ok"
  end

  test "GET /health/ready confirms the database is reachable", %{conn: conn} do
    assert response(get(conn, ~p"/health/ready"), 200) == "ready"
  end
end
