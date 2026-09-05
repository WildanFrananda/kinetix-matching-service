defmodule FleetPulseWeb.Plugs.IdentityAuth do
  @moduledoc """
  Authenticates a JSON API request against identity's RS256 access tokens.

  What this replaces: `FleetPulseWeb.Plugs.ApiKeyAuth`, and with it the whole partner-API-key
  mechanism — the `api_keys` table, `FleetPulse.Api`, and `FleetPulse.Api.Key`. Kinetix will have
  no third-party integrations, so a second class of credential existed only to be a second thing
  that could leak. First-party callers present an identity token like everybody else.

  The verified caller is assigned to `:current_caller` and is the ONLY identity anything
  downstream may read. A `X-User-Id` header grants nothing.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias FleetPulse.Security.TokenVerifier

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    conn
    |> get_req_header("authorization")
    |> authenticate(conn)
  end

  @spec authenticate([String.t()], Plug.Conn.t()) :: Plug.Conn.t()
  defp authenticate([header], conn) do
    case String.split(header, " ") do
      [scheme, token] -> grant(String.downcase(scheme), token, conn)
      _malformed -> unauthorized(conn)
    end
  end

  defp authenticate(_headers, conn), do: unauthorized(conn)

  @spec grant(String.t(), String.t(), Plug.Conn.t()) :: Plug.Conn.t()
  defp grant("bearer", token, conn) do
    case TokenVerifier.verify_access(token) do
      {:ok, claims} -> assign(conn, :current_caller, claims)
      {:error, _reason} -> unauthorized(conn)
    end
  end

  defp grant(_scheme, _token, conn), do: unauthorized(conn)

  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
