defmodule KinetixMatching.Clients.IdentityGrpc do
  @moduledoc """
  Dials the identity service over the mesh to fetch a courier's vehicle and approval standing.
  """

  @behaviour KinetixMatching.Clients.Identity

  require Logger

  alias KinetixMatching.Clients.Identity
  alias KinetixMatching.Observability.Metrics
  alias KinetixMatching.Proto.Identity.V1.GetCourierStandingRequest
  alias KinetixMatching.Proto.Identity.V1.IdentityService.Stub
  alias KinetixMatching.Security.ServiceIdentity

  @connect_timeout 3_000
  @call_timeout 5_000

  @peer "identity"
  @method "/identity.v1.IdentityService/GetCourierStanding"

  @impl KinetixMatching.Clients.Identity
  @spec courier_standing(String.t()) :: {:ok, Identity.standing()} | {:error, Identity.error()}
  def courier_standing(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    dial(host(), courier_principal_id)
  end

  def courier_standing(_courier_principal_id), do: {:error, :not_found}

  @spec dial(String.t(), String.t()) :: {:ok, Identity.standing()} | {:error, Identity.error()}
  defp dial(host, courier_principal_id) do
    case GRPC.Stub.connect(host, connect_options()) do
      {:ok, channel} ->
        try do
          call(channel, courier_principal_id)
        after
          GRPC.Stub.disconnect(channel)
        end

      {:error, reason} ->
        Logger.error(
          "[Identity] could not reach #{host} for courier #{courier_principal_id}: #{inspect(reason)}"
        )

        count("unavailable")
        {:error, :unavailable}
    end
  end

  @spec call(GRPC.Channel.t(), String.t()) ::
          {:ok, Identity.standing()} | {:error, Identity.error()}
  defp call(channel, courier_principal_id) do
    request = %GetCourierStandingRequest{principal_id: courier_principal_id}

    case Stub.get_courier_standing(channel, request, timeout: @call_timeout) do
      {:ok, %{found: false}} ->
        count("ok")
        {:error, :not_found}

      {:ok,
       %{
         found: true,
         courier_principal_id: principal_id,
         vehicle_plate: vehicle_plate,
         capacity_kg: capacity_kg,
         may_drive: may_drive
       }} ->
        count("ok")

        {:ok,
         %{
           courier_principal_id: principal_id,
           vehicle_plate: vehicle_plate || "",
           capacity_kg: max(0, capacity_kg || 0),
           may_drive: may_drive == true
         }}

      {:error, %GRPC.RPCError{} = rpc_error} ->
        Logger.error(
          "[Identity] GetCourierStanding for #{courier_principal_id} failed: " <>
            "#{rpc_error.status} #{rpc_error.message}"
        )

        count(to_string(rpc_error.status))
        {:error, outcome_of(rpc_error.status)}

      {:error, reason} ->
        Logger.error(
          "[Identity] GetCourierStanding for #{courier_principal_id} failed: #{inspect(reason)}"
        )

        count("unknown")
        {:error, :unavailable}
    end
  end

  @spec outcome_of(non_neg_integer()) :: Identity.error()
  def outcome_of(status) do
    if status in [GRPC.Status.not_found(), GRPC.Status.invalid_argument()] do
      :not_found
    else
      :unavailable
    end
  end

  @spec host() :: String.t()
  defp host do
    :kinetix_matching
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(:host)
  end

  @spec count(String.t()) :: :ok
  defp count(grpc_code) do
    :telemetry.execute(
      Metrics.grpc_client_call_event(),
      %{count: 1},
      %{peer: @peer, grpc_method: @method, grpc_code: grpc_code}
    )
  end

  @spec connect_options() :: keyword()
  defp connect_options do
    [
      cred: credentials(),
      adapter: GRPC.Client.Adapters.Mint,
      connect_timeout: @connect_timeout
    ]
  end

  @spec credentials() :: GRPC.Credential.t()
  defp credentials do
    GRPC.Credential.new(ssl: ServiceIdentity.client_options(ServiceIdentity.load!()))
  end
end
