defmodule FleetPulseWeb.AdminAuth do
  @moduledoc """
  Plugs and a LiveView `on_mount` hook that gate the dispatch console.

  The session carries the operator's verified claims — principal, account id, email and role —
  put there once at login by `FleetPulse.Security.IdentityLogin`. It used to carry a local
  `admin_id` pointing into an `admins` table this service kept its own passwords in.

  The signed session cookie cannot be forged, but there is no server-side session store, so a
  session lives until its cookie expires and cannot be revoked remotely. That is the same debt as
  before and is stated rather than fixed here: revocation belongs with identity, which already
  tracks it for tokens.
  """

  use FleetPulseWeb, :verified_routes

  import Plug.Conn
  import Phoenix.Controller

  alias FleetPulse.Security.AccessClaims
  alias Phoenix.Component
  alias Phoenix.LiveView
  alias Phoenix.LiveView.Socket

  @session_key "operator"

  @spec log_in_operator(Plug.Conn.t(), AccessClaims.t()) :: Plug.Conn.t()
  def log_in_operator(conn, %AccessClaims{} = claims) do
    conn
    |> renew_session()
    |> put_session(@session_key, Map.from_struct(claims))
    |> redirect(to: ~p"/dispatch")
  end

  @spec log_out_operator(Plug.Conn.t()) :: Plug.Conn.t()
  def log_out_operator(conn) do
    conn
    |> renew_session()
    |> redirect(to: ~p"/")
  end

  @spec fetch_current_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def fetch_current_admin(conn, _opts) do
    assign(conn, :current_admin, operator(get_session(conn, @session_key)))
  end

  @spec require_authenticated_admin(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def require_authenticated_admin(conn, _opts) do
    gate(conn.assigns[:current_admin], conn)
  end

  @spec on_mount(:ensure_authenticated, map(), map(), Socket.t()) :: {:cont | :halt, Socket.t()}
  def on_mount(:ensure_authenticated, _params, session, socket) do
    mount_gate(operator(session[@session_key]), socket)
  end

  @spec operator(term()) :: AccessClaims.t() | nil
  defp operator(stored) when is_map(stored) do
    stored
    |> Map.new(fn {key, value} -> {to_string(key), value} end)
    |> Map.put_new("sub", Map.get(stored, :principal_id))
    |> then(fn map ->
      %{
        "sub" => map["sub"] || map["principal_id"],
        "uid" => map["user_id"],
        "email" => map["email"],
        "role" => map["role"]
      }
    end)
    |> AccessClaims.from_payload()
    |> case do
      {:ok, %AccessClaims{role: "admin"} = claims} -> claims
      _not_an_operator -> nil
    end
  end

  defp operator(_other), do: nil

  @spec gate(AccessClaims.t() | nil, Plug.Conn.t()) :: Plug.Conn.t()
  defp gate(%AccessClaims{}, conn), do: conn

  defp gate(nil, conn) do
    conn
    |> put_flash(:error, "You must log in to access the dispatch console.")
    |> redirect(to: ~p"/admin/log_in")
    |> halt()
  end

  @spec mount_gate(AccessClaims.t() | nil, Socket.t()) :: {:cont | :halt, Socket.t()}
  defp mount_gate(%AccessClaims{} = operator, socket) do
    {:cont, Component.assign(socket, :current_admin, operator)}
  end

  defp mount_gate(nil, socket) do
    {:halt,
     socket
     |> LiveView.put_flash(:error, "You must log in to access the dispatch console.")
     |> LiveView.redirect(to: ~p"/admin/log_in")}
  end

  @spec renew_session(Plug.Conn.t()) :: Plug.Conn.t()
  defp renew_session(conn) do
    conn
    |> configure_session(renew: true)
    |> clear_session()
  end
end
