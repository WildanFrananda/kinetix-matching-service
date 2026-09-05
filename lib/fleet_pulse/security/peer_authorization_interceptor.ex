defmodule FleetPulse.Security.PeerAuthorizationInterceptor do
  @moduledoc """
  Refuses any gRPC call whose peer is not a service on this server's allow list.

  mTLS answers "was this certificate issued by our CA". It does not answer "may this particular
  service call this server", and every service on the mesh holds a certificate from the same CA —
  so without this, converting to mTLS would let any service drive the fleet.

  Declared with `intercept` on the endpoint, so it wraps every server the endpoint runs,
  reflection included. Reflection is bidirectional streaming and is easy to leave unguarded when
  authorization is attached per call shape — which is exactly what happened on the .NET service.
  """

  @behaviour GRPC.Server.Interceptor

  require Logger

  alias FleetPulse.Security.Spiffe
  alias GRPC.Server.Adapters.Cowboy, as: CowboyAdapter

  @allowed_key {__MODULE__, :allowed_callers}

  @impl GRPC.Server.Interceptor
  @spec init(keyword()) :: keyword()
  def init(opts), do: opts

  @doc """
  Reads and validates the allow list, once, at application start.

  Raising here rather than at the first call: an empty allow list refuses everything, which looks
  exactly like a network fault at three in the morning.
  """
  @spec load_allowed_callers!() :: MapSet.t(String.t())
  def load_allowed_callers! do
    allowed =
      "GRPC_ALLOWED_CALLERS"
      |> System.get_env("")
      |> String.split(",", trim: true)
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> MapSet.new()

    if MapSet.size(allowed) == 0 do
      raise "GRPC_ALLOWED_CALLERS is empty. Name the services permitted to call this server, " <>
              "or the gRPC surface is unreachable."
    end

    Logger.info("gRPC callers allowed on this server: #{Enum.join(allowed, ", ")}")
    :persistent_term.put(@allowed_key, allowed)
    allowed
  end

  @impl GRPC.Server.Interceptor
  @spec call(struct() | nil, GRPC.Server.Stream.t(), (struct() | nil, GRPC.Server.Stream.t() -> any()), keyword()) ::
          any()
  def call(req, stream, next, _opts) do
    case peer_service(stream) do
      {:ok, service} -> authorize(service, allowed_callers(), req, stream, next)
      :error -> refuse_anonymous(stream)
    end
  end

  @spec allowed_callers() :: MapSet.t(String.t())
  defp allowed_callers, do: :persistent_term.get(@allowed_key, MapSet.new())

  @spec authorize(String.t(), MapSet.t(String.t()), struct() | nil, GRPC.Server.Stream.t(), fun()) ::
          any()
  defp authorize(service, allowed, req, stream, next) do
    if MapSet.member?(allowed, service) do
      next.(req, stream)
    else
      Logger.warning(
        "refused a gRPC call to #{method(stream)} from #{service}, which is not on the allow list"
      )

      raise GRPC.RPCError,
        status: GRPC.Status.permission_denied(),
        message: "service '#{service}' may not call this server"
    end
  end

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
