defmodule FleetPulseWeb.HealthController do
  @moduledoc """
  Probe endpoints for load balancers and orchestrators.

  `live` answers "is the BEAM up?" — trivially 200, no dependencies. Use it for
  a liveness probe: if it fails, restart the node.

  `ready` answers "can we actually serve?" — it pings the database. Use it for
  a readiness probe / load-balancer health check: a node with no database
  should be pulled from rotation, not restarted.
  """

  use FleetPulseWeb, :controller

  alias Ecto.Adapters.SQL
  alias FleetPulse.Repo

  @spec live(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def live(conn, _params), do: send_resp(conn, 200, "ok")

  @spec ready(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def ready(conn, _params) do
    reply(database_ok?(), conn)
  end

  @spec reply(boolean(), Plug.Conn.t()) :: Plug.Conn.t()
  defp reply(true, conn), do: send_resp(conn, 200, "ready")
  defp reply(false, conn), do: send_resp(conn, 503, "not ready")

  @spec database_ok?() :: boolean()
  defp database_ok? do
    case SQL.query(Repo, "SELECT 1", []) do
      {:ok, _result} -> true
      {:error, _reason} -> false
    end
  rescue
    _error -> false
  end
end
