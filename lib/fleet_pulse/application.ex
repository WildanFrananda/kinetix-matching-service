defmodule FleetPulse.Application do
  @moduledoc false
  use Application

  @impl true
  @spec start(Application.start_type(), term()) ::
          {:ok, pid()} | {:ok, pid(), Application.state()} | {:error, term()}
  def start(_type, _args) do
    grpc_port = String.to_integer(System.get_env("GRPC_PORT") || "50053")

    children =
      [
        FleetPulseWeb.Telemetry,
        FleetPulse.Repo,
        {DNSCluster, query: Application.get_env(:fleet_pulse, :dns_cluster_query) || :ignore},
        {Phoenix.PubSub, name: FleetPulse.PubSub},
        FleetPulse.Tracking.Supervisor,
        {FleetPulse.RateLimit, clean_period: :timer.minutes(10)},
        {GRPC.Server.Supervisor, endpoint: FleetPulse.GrpcEndpoint, port: grpc_port, start_server: true}
      ] ++ redispatcher() ++ [FleetPulseWeb.Endpoint]

    opts = [strategy: :one_for_one, name: FleetPulse.Supervisor]
    Supervisor.start_link(children, opts)
  end

  @impl true
  @spec config_change(keyword(), keyword(), [atom()]) :: :ok
  def config_change(changed, _new, removed) do
    FleetPulseWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @spec redispatcher() :: [FleetPulse.Dispatch.ReDispatcher]
  defp redispatcher do
    :fleet_pulse
    |> Application.get_env(FleetPulse.Dispatch.ReDispatcher, [])
    |> Keyword.get(:enabled, true)
    |> redispatcher_child()
  end

  @spec redispatcher_child(boolean()) :: [FleetPulse.Dispatch.ReDispatcher]
  defp redispatcher_child(true), do: [FleetPulse.Dispatch.ReDispatcher]
  defp redispatcher_child(false), do: []
end
