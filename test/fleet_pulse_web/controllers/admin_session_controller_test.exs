defmodule FleetPulseWeb.AdminSessionControllerTest do
  use FleetPulseWeb.ConnCase, async: true

  describe "GET /admin/log_in" do
    test "renders the login form", %{conn: conn} do
      assert html_response(get(conn, ~p"/admin/log_in"), 200) =~ "Log in"
    end
  end

  describe "POST /admin/log_in" do
    test "answers 503 rather than a session when identity cannot be reached", %{conn: conn} do
      conn =
        post(conn, ~p"/admin/log_in", %{
          "admin" => %{"email" => "operator@kinetix.test", "password" => "whatever"}
        })

      assert html_response(conn, 503) =~ "temporarily unavailable"
      refute get_session(conn, "operator")
    end

    test "opens no session for a malformed post", %{conn: conn} do
      conn = post(conn, ~p"/admin/log_in", %{"admin" => %{"email" => "operator@kinetix.test"}})

      assert html_response(conn, 200) =~ "Invalid email or password"
      refute get_session(conn, "operator")
    end
  end

  describe "DELETE /admin/log_out" do
    test "clears the session", %{conn: conn} do
      conn = conn |> log_in_operator() |> delete(~p"/admin/log_out")

      refute get_session(conn, "operator")
      assert redirected_to(conn) == ~p"/"
    end
  end
end
