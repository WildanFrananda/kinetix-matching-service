defmodule FleetPulse.Clients.IdentityGrpc do
  @moduledoc """
  Dials identity over the mesh to read a principal's profile.
  """

  @behaviour FleetPulse.Clients.Identity

  require Logger

  alias FleetPulse.Observability.Metrics
  alias FleetPulse.Proto.Identity.V1.GetUserProfileRequest
  alias FleetPulse.Proto.Identity.V1.IdentityService.Stub
  alias FleetPulse.Security.ServiceIdentity

  @connect_timeout 3_000
  @call_timeout 5_000

  @peer "identity"
  @method "/identity.v1.IdentityService/GetUserProfile"

  @impl FleetPulse.Clients.Identity
  @spec profile_of(String.t()) ::
          {:ok, FleetPulse.Clients.Identity.profile()}
          | {:error, FleetPulse.Clients.Identity.error()}
  def profile_of(principal_id) do
    case host() do
      nil ->
        Logger.error(
          "[Identity] IDENTITY_GRPC_HOST is unset; cannot read profile #{principal_id}"
        )

        count("failed_precondition")
        {:error, :not_configured}

      host ->
        dial(host, principal_id)
    end
  end

  @spec dial(String.t(), String.t()) ::
          {:ok, FleetPulse.Clients.Identity.profile()}
          | {:error, FleetPulse.Clients.Identity.error()}
  defp dial(host, principal_id) do
    case GRPC.Stub.connect(host, cred: credentials(), timeout: @connect_timeout) do
      {:ok, channel} ->
        try do
          call(channel, principal_id)
        after
          GRPC.Stub.disconnect(channel)
        end

      {:error, reason} ->
        Logger.error(
          "[Identity] could not reach #{host} for profile #{principal_id}: #{inspect(reason)}"
        )

        count("unavailable")
        {:error, :unavailable}
    end
  end

  @spec call(GRPC.Channel.t(), String.t()) ::
          {:ok, FleetPulse.Clients.Identity.profile()}
          | {:error, FleetPulse.Clients.Identity.error()}
  defp call(channel, principal_id) do
    request = %GetUserProfileRequest{principal_id: principal_id}

    case Stub.get_user_profile(channel, request, timeout: @call_timeout) do
      {:ok, %{found: true} = response} ->
        count("ok")
        {:ok, %{full_name: response.full_name, phone_number: response.phone_number}}

      {:ok, %{found: false}} ->
        Logger.warning("[Identity] no profile for principal #{principal_id}")
        count("not_found")
        {:error, :not_found}

      {:error, %GRPC.RPCError{} = rpc_error} ->
        Logger.error(
          "[Identity] refused the profile for #{principal_id}: " <>
            "#{rpc_error.status} #{rpc_error.message}"
        )

        count(to_string(rpc_error.status))
        {:error, :unavailable}

      {:error, reason} ->
        Logger.error("[Identity] reading profile #{principal_id} failed: #{inspect(reason)}")
        count("unknown")
        {:error, :unavailable}
    end
  end

  @spec host() :: String.t() | nil
  defp host do
    case System.get_env("IDENTITY_GRPC_HOST") do
      nil -> nil
      "" -> nil
      value -> value
    end
  end

  @spec count(String.t()) :: :ok
  defp count(grpc_code) do
    :telemetry.execute(
      Metrics.grpc_client_call_event(),
      %{count: 1},
      %{peer: @peer, grpc_method: @method, grpc_code: grpc_code}
    )
  end

  @spec credentials() :: GRPC.Credential.t()
  defp credentials do
    GRPC.Credential.new(ssl: ServiceIdentity.client_options(ServiceIdentity.load!()))
  end
end
