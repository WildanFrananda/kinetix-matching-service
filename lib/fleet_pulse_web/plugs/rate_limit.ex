defmodule FleetPulseWeb.Plugs.RateLimit do
  @moduledoc """
  Rejects a request with `429 Too Many Requests` once a client IP exceeds the
  configured rate for a route bucket. A no-op when disabled in config (tests).

  Keyed by IP, not by phone: an attacker hammering from one source is throttled,
  and a phone key would let an attacker lock out a victim by spending their
  budget.
  """

  import Plug.Conn
  import Phoenix.Controller, only: [json: 2]

  alias FleetPulse.RateLimit

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(conn, opts) do
    config = Application.get_env(:fleet_pulse, __MODULE__, [])
    enforce(Keyword.get(config, :enabled, true), conn, opts, config)
  end

  @spec enforce(boolean(), Plug.Conn.t(), keyword(), keyword()) :: Plug.Conn.t()
  defp enforce(false, conn, _opts, _config), do: conn

  defp enforce(true, conn, opts, config) do
    bucket = Keyword.fetch!(opts, :bucket)
    scale_ms = Keyword.get(config, :scale_ms, 60_000)
    limit = Keyword.get(config, bucket, 10)
    key = "#{bucket}:#{client_ip(conn)}"

    verdict(RateLimit.hit(key, scale_ms, limit), conn)
  end

  @spec verdict({:allow, non_neg_integer()} | {:deny, non_neg_integer()}, Plug.Conn.t()) ::
          Plug.Conn.t()
  defp verdict({:allow, _count}, conn), do: conn

  defp verdict({:deny, retry_after_ms}, conn) do
    conn
    |> put_req_header("retry-after", to_string(div(retry_after_ms, 1000)))
    |> put_status(:too_many_requests)
    |> json(%{error: "rate_limited"})
    |> halt()
  end

  @spec client_ip(Plug.Conn.t()) :: String.t()
  defp client_ip(conn) do
    conn.remote_ip |> :inet.ntoa() |> to_string()
  end
end
