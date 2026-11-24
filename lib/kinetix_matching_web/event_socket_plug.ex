defmodule KinetixMatchingWeb.EventSocketPlug do
  @moduledoc """
  Authenticates WebSocket upgrade requests on `/ws/v1/events` and upgrades to
  `KinetixMatchingWeb.EventSocket`.
  """

  import Plug.Conn

  alias KinetixMatching.Security.AccessClaims
  alias KinetixMatching.Security.TokenVerifier
  alias KinetixMatching.Tracking
  alias KinetixMatchingWeb.EventSocket

  @behaviour Plug

  @socket_path "/ws/v1/events"

  @impl Plug
  @spec init(term()) :: term()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), term()) :: Plug.Conn.t()
  def call(%Plug.Conn{request_path: @socket_path} = conn, _opts) do
    case authenticate(conn) do
      {:ok, init_state} ->
        upgrade_connection(conn, init_state)

      {:error, reason} ->
        reject(conn, reason)
    end
  end

  def call(conn, _opts), do: conn

  @spec authenticate(Plug.Conn.t()) :: {:ok, EventSocket.init_arg()} | {:error, atom()}
  def authenticate(conn) do
    with {:ok, token} <- bearer_token(conn),
         {:ok, %AccessClaims{} = claims} <- TokenVerifier.verify_access(token) do
      authorize_claims(claims, role_hint(conn))
    end
  end

  @spec upgrade_connection(Plug.Conn.t(), EventSocket.init_arg()) :: Plug.Conn.t()
  defp upgrade_connection(conn, init_state) do
    conn
    |> WebSockAdapter.upgrade(EventSocket, init_state, timeout: 60_000)
    |> halt()
  rescue
    ArgumentError ->
      conn
      |> put_resp_content_type("application/json")
      |> send_resp(426, Jason.encode!(%{error: "upgrade_required"}))
      |> halt()
  end

  @spec bearer_token(Plug.Conn.t()) :: {:ok, String.t()} | {:error, :missing_token}
  defp bearer_token(conn) do
    case get_req_header(conn, "authorization") do
      [header | _] -> parse_bearer(header)
      [] -> {:error, :missing_token}
    end
  end

  @spec parse_bearer(String.t()) :: {:ok, String.t()} | {:error, :missing_token}
  defp parse_bearer(header) when is_binary(header) do
    case String.split(String.trim(header), ~r/\s+/, parts: 2) do
      [scheme, token] when token != "" ->
        if String.downcase(scheme) == "bearer" do
          {:ok, String.trim(token)}
        else
          {:error, :missing_token}
        end

      _other ->
        {:error, :missing_token}
    end
  end

  @spec role_hint(Plug.Conn.t()) :: String.t() | nil
  defp role_hint(conn) do
    case get_req_header(conn, "x-edge-role") do
      [value | _] -> String.downcase(String.trim(value))
      [] -> nil
    end
  end

  @spec authorize_claims(AccessClaims.t(), String.t() | nil) ::
          {:ok, EventSocket.init_arg()} | {:error, atom()}
  defp authorize_claims(%AccessClaims{role: "courier", principal_id: principal_id}, _hint) do
    authorize_courier(principal_id)
  end

  defp authorize_claims(%AccessClaims{role: "seller", principal_id: principal_id}, _hint) do
    {:ok, %{role: :seller, merchant_principal_id: principal_id}}
  end

  defp authorize_claims(%AccessClaims{role: "admin", principal_id: principal_id}, "seller") do
    {:ok, %{role: :seller, merchant_principal_id: principal_id}}
  end

  defp authorize_claims(%AccessClaims{role: "admin", principal_id: principal_id}, _hint) do
    case authorize_courier(principal_id) do
      {:ok, state} -> {:ok, state}
      {:error, :unlinked} -> {:ok, %{role: :seller, merchant_principal_id: principal_id}}
      {:error, reason} -> {:error, reason}
    end
  end

  defp authorize_claims(%AccessClaims{}, _hint), do: {:error, :forbidden}

  @spec authorize_courier(String.t()) :: {:ok, EventSocket.init_arg()} | {:error, atom()}
  defp authorize_courier(principal_id) do
    with {:ok, _standing} <- Tracking.driver_for_principal(principal_id) do
      {:ok, %{role: :courier, courier_principal_id: principal_id}}
    end
  end

  @spec reject(Plug.Conn.t(), atom()) :: Plug.Conn.t()
  defp reject(conn, :identity_unavailable), do: send_json(conn, 503, "identity_unavailable")
  defp reject(conn, :missing_token), do: send_json(conn, 401, "missing_token")
  defp reject(conn, :invalid_token), do: send_json(conn, 401, "invalid_token")
  defp reject(conn, :malformed_claims), do: send_json(conn, 401, "malformed_claims")
  defp reject(conn, reason), do: send_json(conn, 403, Atom.to_string(reason))

  @spec send_json(Plug.Conn.t(), non_neg_integer(), String.t()) :: Plug.Conn.t()
  defp send_json(conn, status, reason) do
    trace_id =
      case conn.assigns[:request_id] do
        id when is_binary(id) and id != "" -> id
        _missing -> "-"
      end

    conn
    |> put_resp_content_type("application/json")
    |> send_resp(status, Jason.encode!(%{error: reason, traceId: trace_id}))
    |> halt()
  end
end
