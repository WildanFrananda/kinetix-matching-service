defmodule FleetPulse.Security.PeerAuthorizationInterceptor do
  @moduledoc """
  Refuses any gRPC call whose peer is not a service on this server's allow list.

  `GRPC_ALLOWED_CALLERS` takes `peer` (every method), `peer@package.Service` (every method of that
  service) or `peer@package.Service/Method` (that method only). A listed peer may also use server
  reflection, which describes the published contract and nothing else.
  """

  @behaviour GRPC.Server.Interceptor

  require Logger

  alias FleetPulse.Security.Spiffe
  alias GRPC.Server.Adapters.Cowboy, as: CowboyAdapter

  @allowed_key {__MODULE__, :allowed_callers}

  @impl GRPC.Server.Interceptor
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @type scope :: :any | MapSet.t(String.t())

  @type allow_list :: %{optional(String.t()) => scope()}

  @spec load_allowed_callers!() :: allow_list()
  def load_allowed_callers! do
    allowed =
      "GRPC_ALLOWED_CALLERS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.reduce(%{}, &add_entry/2)

    if map_size(allowed) == 0 do
      raise "GRPC_ALLOWED_CALLERS is empty. Name the services permitted to call this server, " <>
              "or the gRPC surface is unreachable."
    end

    Logger.info("gRPC callers allowed on this server: #{describe_allowed(allowed)}")
    :persistent_term.put(@allowed_key, allowed)
    allowed
  end

  @spec add_entry(String.t(), allow_list()) :: allow_list()
  defp add_entry(entry, acc) do
    case String.split(entry, "@", parts: 2) do
      [caller] ->
        Map.put(acc, caller, :any)

      [caller, service] ->
        Map.update(acc, caller, MapSet.new([service]), fn
          :any -> :any
          services -> MapSet.put(services, service)
        end)
    end
  end

  @spec describe_allowed(allow_list()) :: String.t()
  defp describe_allowed(allowed) do
    allowed
    |> Enum.map(fn
      {caller, :any} -> "#{caller} (any service)"
      {caller, services} -> "#{caller} (#{Enum.join(Enum.sort(services), " ")})"
    end)
    |> Enum.sort()
    |> Enum.join(", ")
  end

  @impl GRPC.Server.Interceptor
  @spec call(
          struct() | nil,
          GRPC.Server.Stream.t(),
          (struct() | nil, GRPC.Server.Stream.t() -> any()),
          keyword()
        ) ::
          any()
  def call(req, stream, next, _opts) do
    case peer_service(stream) do
      {:ok, peer} -> authorize(peer, req, stream, next)
      :error -> refuse_anonymous(stream)
    end
  end

  @spec allowed_callers() :: allow_list()
  defp allowed_callers, do: :persistent_term.get(@allowed_key, %{})

  @spec authorize(String.t(), struct() | nil, GRPC.Server.Stream.t(), fun()) :: any()
  defp authorize(peer, req, stream, next) do
    called = called_method(stream)

    if permitted?(allowed_callers(), peer, called) do
      next.(req, stream)
    else
      Logger.warning(
        "refused a gRPC call to #{method(stream)} from #{peer}, which this server's allow list " <>
          "does not grant it"
      )

      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "service '#{peer}' may not call #{called}"
    end
  end

  @reflection ["grpc.reflection.v1.ServerReflection", "grpc.reflection.v1alpha.ServerReflection"]

  @spec permitted?(allow_list(), String.t(), String.t()) :: boolean()
  def permitted?(allowed, peer, called) do
    case Map.get(allowed, peer) do
      nil -> false
      :any -> true
      scopes -> reflection?(called) or Enum.any?(scopes_of(called), &MapSet.member?(scopes, &1))
    end
  end

  @spec reflection?(String.t()) :: boolean()
  defp reflection?(called) do
    [service | _method] = String.split(called, "/", parts: 2)
    service in @reflection
  end

  @spec scopes_of(String.t()) :: [String.t()]
  defp scopes_of(called) do
    case String.split(called, "/", parts: 2) do
      [service, _method] -> [service, called]
      [service] -> [service]
    end
  end

  @spec called_method(GRPC.Server.Stream.t()) :: String.t()
  defp called_method(%GRPC.Server.Stream{service_name: service, method_name: method})
       when is_binary(service) and is_binary(method) do
    "#{service}/#{method}"
  end

  defp called_method(%GRPC.Server.Stream{service_name: service}) when is_binary(service) do
    service
  end

  defp called_method(_stream), do: ""

  @spec refuse_anonymous(GRPC.Server.Stream.t()) :: no_return()
  defp refuse_anonymous(stream) do
    Logger.warning("refused a gRPC call to #{method(stream)} from a peer with no SPIFFE identity")

    raise GRPC.RPCError,
      status: GRPC.Status.unauthenticated(),
      message: "a client certificate carrying a SPIFFE id is required"
  end

  @spec peer_service(GRPC.Server.Stream.t()) :: {:ok, String.t()} | :error
  defp peer_service(%GRPC.Server.Stream{payload: payload}) when is_map(payload) do
    case CowboyAdapter.get_cert(payload) do
      der when is_binary(der) -> Spiffe.service_of(der)
      _no_certificate -> :error
    end
  end

  defp peer_service(_stream), do: :error

  @spec method(GRPC.Server.Stream.t()) :: String.t()
  defp method(%GRPC.Server.Stream{service_name: service, method_name: method}),
    do: "#{service}/#{method}"

  defp method(_stream), do: "an unknown method"
end
