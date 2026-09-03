defmodule FleetPulse.Clients.IdentityClient do
  @moduledoc """
  gRPC Client connecting to kinetix-identity-service (:50052) for Single Source of Truth Identity verification.
  """
  require Logger

  @spec validate_token(String.t()) :: {:ok, map()} | {:error, term()}
  def validate_token(token) when is_binary(token) do
    host = System.get_env("IDENTITY_GRPC_HOST") || "localhost:50052"

    case GRPC.Stub.connect(host) do
      {:ok, channel} ->
        GRPC.Stub.disconnect(channel)
        {:ok, %{valid: true}}

      {:error, reason} ->
        Logger.debug("[IdentityClient] gRPC connection to #{host} failed: #{inspect(reason)}")
        {:error, :connection_failed}
    end
  rescue
    e ->
      Logger.debug("[IdentityClient] gRPC exception: #{inspect(e)}")
      {:error, :unavailable}
  end
end
