defmodule FleetPulseWeb.Plugs.RequireRole do
  @moduledoc """
  Narrows an authenticated route to particular roles.

      plug FleetPulseWeb.Plugs.RequireRole, ["seller", "admin"]

  Runs after `FleetPulseWeb.Plugs.IdentityAuth`, and reads only what that plug verified. A route
  reached without it has no caller to check, so this halts rather than assuming one.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias FleetPulse.Security.AccessClaims

  @behaviour Plug

  @impl Plug
  @spec init([String.t()]) :: [String.t()]
  def init(roles) when is_list(roles) and roles != [], do: roles

  @impl Plug
  @spec call(Plug.Conn.t(), [String.t()]) :: Plug.Conn.t()
  def call(%Plug.Conn{assigns: %{current_caller: %AccessClaims{role: role}}} = conn, roles) do
    if role in roles, do: conn, else: forbidden(conn, role, roles)
  end

  def call(conn, _roles) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end

  @spec forbidden(Plug.Conn.t(), String.t(), [String.t()]) :: Plug.Conn.t()
  defp forbidden(conn, role, roles) do
    conn
    |> put_status(:forbidden)
    |> json(%{
      error: "forbidden",
      message: "this account is a #{role}; this route is for #{Enum.join(roles, " or ")}"
    })
    |> halt()
  end
end
