defmodule FleetPulseWeb.Plugs.ApiKeyAuth do
  @moduledoc """
  Authenticates a partner API request by its `Authorization: Bearer <key>`
  header, assigning the key record to `:api_key` or halting with 401.

  Header only — never a query parameter — because a key in a URL leaks into
  server logs, proxies, and browser history. SSE consumers must therefore be
  server-side HTTP clients that can set headers, not browser `EventSource`.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias FleetPulse.Api

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, _opts) do
    authenticate(get_req_header(conn, "authorization"), conn)
  end

  @spec authenticate([String.t()], Plug.Conn.t()) :: Plug.Conn.t()
  defp authenticate(["Bearer " <> key], conn), do: grant(Api.authenticate(key), conn)
  defp authenticate(_header, conn), do: unauthorized(conn)

  @spec grant({:ok, Api.Key.t()} | {:error, :invalid}, Plug.Conn.t()) :: Plug.Conn.t()
  defp grant({:ok, api_key}, conn), do: assign(conn, :api_key, api_key)
  defp grant({:error, :invalid}, conn), do: unauthorized(conn)

  @spec unauthorized(Plug.Conn.t()) :: Plug.Conn.t()
  defp unauthorized(conn) do
    conn
    |> put_status(:unauthorized)
    |> json(%{error: "unauthorized"})
    |> halt()
  end
end
