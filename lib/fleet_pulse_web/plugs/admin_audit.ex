defmodule FleetPulseWeb.Plugs.AdminAudit do
  @moduledoc """
  Audits an administrator's request on an admin-only route once it is answered.
  """

  import Plug.Conn

  alias FleetPulse.Observability.AdminActions
  alias FleetPulse.Security.AccessClaims

  @behaviour Plug

  @impl Plug
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @impl Plug
  @spec call(Plug.Conn.t(), keyword()) :: Plug.Conn.t()
  def call(
        %Plug.Conn{
          private: %{phoenix_router: router},
          assigns: %{current_caller: %AccessClaims{principal_id: actor}}
        } = conn,
        _opts
      ) do
    target = target(conn.path_params)

    case Phoenix.Router.route_info(router, conn.method, conn.path_info, conn.host) do
      %{admin_action: action} when is_binary(action) ->
        register_before_send(conn, &answered(&1, actor, action, target))

      _unnamed ->
        raise ArgumentError,
              "a route behind the admin audit names no admin_action in its metadata, " <>
                "so there is nothing to record it under"
    end
  end

  @spec answered(Plug.Conn.t(), String.t(), String.t(), String.t() | nil) :: Plug.Conn.t()
  defp answered(conn, actor, action, target) do
    :ok = AdminActions.record(actor, action, target, outcome(conn.status))
    conn
  end

  @spec target(map()) :: String.t() | nil
  defp target(%{"id" => id}), do: id
  defp target(%{"driver_id" => driver_id}), do: driver_id
  defp target(_path_params), do: nil

  @spec outcome(non_neg_integer() | nil) :: AdminActions.outcome()
  defp outcome(status) when is_integer(status) and status >= 200 and status < 400, do: :done
  defp outcome(status) when is_integer(status) and status >= 400 and status < 500, do: :refused
  defp outcome(_status), do: :failed
end
