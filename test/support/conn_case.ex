defmodule FleetPulseWeb.ConnCase do
  @moduledoc """
  This module defines the test case to be used by
  tests that require setting up a connection.
  """

  use ExUnit.CaseTemplate

  alias FleetPulse.IdentityJwks
  alias FleetPulse.Security.AccessClaims

  using do
    quote do
      @endpoint FleetPulseWeb.Endpoint

      use FleetPulseWeb, :verified_routes

      import Plug.Conn
      import Phoenix.ConnTest
      import FleetPulseWeb.ConnCase
    end
  end

  @spec log_in_operator(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def log_in_operator(conn, overrides \\ []) do
    claims = %AccessClaims{
      principal_id: Keyword.get(overrides, :principal_id, "aaaaaaaa-bbbb-cccc-dddd-eeeeeeeeeeee"),
      email: Keyword.get(overrides, :email, "operator@kinetix.test"),
      role: Keyword.get(overrides, :role, "admin")
    }

    conn
    |> Phoenix.ConnTest.init_test_session(%{})
    |> Plug.Conn.put_session("operator", Map.from_struct(claims))
  end

  @spec authenticate(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def authenticate(conn, overrides \\ []) do
    {header, value} = IdentityJwks.bearer(IdentityJwks.token(overrides))
    Plug.Conn.put_req_header(conn, header, value)
  end

  setup tags do
    FleetPulse.DataCase.setup_sandbox(tags)
    {:ok, conn: Phoenix.ConnTest.build_conn()}
  end
end
