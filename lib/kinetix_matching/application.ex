defmodule KinetixMatching.Application do
  @moduledoc false
  use Application

  alias KinetixMatching.Security.PeerAuthorizationInterceptor
  alias KinetixMatching.Security.ServiceIdentity

  @typep child :: Supervisor.child_spec() | {module(), term()} | module()

  @impl true
  @spec start(Application.start_type(), term()) ::
          {:ok, pid()} | {:ok, pid(), Application.state()} | {:error, term()}
  def start(_type, _args) do
    _zone = KinetixMatching.PlatformTimeZone.fetch!()
    Supervisor.start_link(children(), strategy: :one_for_one, name: KinetixMatching.Supervisor)
  end

  @spec children() :: [child()]
  def children do
    core() ++
      grpc_children() ++
      redispatcher() ++
      delivery_reporter() ++
      [KinetixMatchingWeb.Endpoint] ++
      grpc_shutdown_children()
  end

  @impl true
  @spec config_change(keyword(), keyword(), [atom()]) :: :ok
  def config_change(changed, _new, removed) do
    KinetixMatchingWeb.Endpoint.config_change(changed, removed)
    :ok
  end

  @spec start_grpc_server() :: Supervisor.on_start()
  def start_grpc_server do
    PeerAuthorizationInterceptor.load_allowed_callers!()

    GRPC.Server.Supervisor.start_link(
      endpoint: KinetixMatching.GrpcEndpoint,
      port: String.to_integer(System.fetch_env!("GRPC_PORT")),
      start_server: true,
      adapter_opts: [cred: grpc_credentials()]
    )
  end

  @spec core() :: [child()]
  defp core do
    [
      KinetixMatching.Observability.Metrics,
      KinetixMatchingWeb.AdminActionsSeed,
      KinetixMatchingWeb.Telemetry,
      KinetixMatching.Repo,
      {DNSCluster, query: Application.get_env(:kinetix_matching, :dns_cluster_query) || :ignore},
      {Phoenix.PubSub, name: KinetixMatching.PubSub},
      KinetixMatching.Tracking.RedisPositionPublisher,
      KinetixMatching.Tracking.Supervisor,
      {KinetixMatching.RateLimit, clean_period: :timer.minutes(10)},
      KinetixMatching.Security.TokenVerifier
    ]
  end

  @spec grpc_children() :: [child()]
  defp grpc_children do
    grpc_children(grpc_server?())
  end

  @spec grpc_children(boolean()) :: [child()]
  defp grpc_children(true) do
    [
      grpc_server_spec(),
      KinetixMatching.Observability.GrpcServerMetricsSeed,
      KinetixMatching.Observability.GrpcClientMetricsSeed,
      GrpcReflection,
      KinetixMatching.GrpcDrain
    ]
  end

  defp grpc_children(false), do: []

  @spec grpc_shutdown_children() :: [child()]
  defp grpc_shutdown_children do
    grpc_shutdown_children(grpc_server?())
  end

  @spec grpc_shutdown_children(boolean()) :: [child()]
  defp grpc_shutdown_children(true), do: [KinetixMatching.GrpcListenerSuspender]
  defp grpc_shutdown_children(false), do: []

  @spec grpc_server?() :: boolean()
  defp grpc_server?, do: Application.get_env(:kinetix_matching, :start_grpc_server, true)

  @spec grpc_server_spec() :: Supervisor.child_spec()
  defp grpc_server_spec do
    %{
      id: GRPC.Server.Supervisor,
      start: {__MODULE__, :start_grpc_server, []},
      type: :supervisor
    }
  end

  @spec grpc_credentials() :: GRPC.Credential.t()
  defp grpc_credentials do
    ServiceIdentity.load!()
    |> ServiceIdentity.server_options()
    |> then(&GRPC.Credential.new(ssl: &1))
  end

  @spec redispatcher() :: [KinetixMatching.Dispatch.ReDispatcher]
  defp redispatcher do
    :kinetix_matching
    |> Application.get_env(KinetixMatching.Dispatch.ReDispatcher, [])
    |> Keyword.get(:enabled, true)
    |> redispatcher_child()
  end

  @spec redispatcher_child(boolean()) :: [KinetixMatching.Dispatch.ReDispatcher]
  defp redispatcher_child(true), do: [KinetixMatching.Dispatch.ReDispatcher]
  defp redispatcher_child(false), do: []

  @spec delivery_reporter() :: [KinetixMatching.Dispatch.DeliveryReporter]
  defp delivery_reporter do
    :kinetix_matching
    |> Application.get_env(KinetixMatching.Dispatch.DeliveryReporter, [])
    |> Keyword.get(:enabled, true)
    |> delivery_reporter_child()
  end

  @spec delivery_reporter_child(boolean()) :: [KinetixMatching.Dispatch.DeliveryReporter]
  defp delivery_reporter_child(true), do: [KinetixMatching.Dispatch.DeliveryReporter]
  defp delivery_reporter_child(false), do: []
end
