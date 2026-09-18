defmodule FleetPulse.Clients.PaymentGrpc do
  @moduledoc """
  Dials payment over the mesh to settle a delivered order's shipping fee.
  """

  @behaviour FleetPulse.Clients.Payment

  require Logger

  alias FleetPulse.Observability.Metrics
  alias FleetPulse.Proto.Payment.V1.PaymentService.Stub
  alias FleetPulse.Proto.Payment.V1.SettleShippingFeeRequest
  alias FleetPulse.Security.ServiceIdentity

  @connect_timeout 3_000
  @call_timeout 8_000

  @peer "payment"
  @method "/payment.v1.PaymentService/SettleShippingFee"

  @impl FleetPulse.Clients.Payment
  @spec settle_shipping_fee(String.t(), String.t()) ::
          :ok | {:error, FleetPulse.Clients.Payment.error()}
  def settle_shipping_fee(order_number, driver_principal_id) do
    case host() do
      nil ->
        Logger.error("[Payment] PAYMENT_GRPC_HOST is unset; #{order_number} cannot be settled")
        count("failed_precondition")
        {:error, :not_configured}

      host ->
        dial(host, order_number, driver_principal_id)
    end
  end

  @spec dial(String.t(), String.t(), String.t()) ::
          :ok | {:error, FleetPulse.Clients.Payment.error()}
  defp dial(host, order_number, driver_principal_id) do
    case GRPC.Stub.connect(host, cred: credentials(), timeout: @connect_timeout) do
      {:ok, channel} ->
        try do
          call(channel, order_number, driver_principal_id)
        after
          GRPC.Stub.disconnect(channel)
        end

      {:error, reason} ->
        Logger.error(
          "[Payment] could not reach #{host} to settle #{order_number}: #{inspect(reason)}"
        )

        {:error, :unavailable}
    end
  end

  @spec call(GRPC.Channel.t(), String.t(), String.t()) ::
          :ok | {:error, FleetPulse.Clients.Payment.error()}
  defp call(channel, order_number, driver_principal_id) do
    request = %SettleShippingFeeRequest{
      order_number: order_number,
      driver_principal_id: driver_principal_id
    }

    case Stub.settle_shipping_fee(channel, request, timeout: @call_timeout) do
      {:ok, %{found: true}} ->
        Logger.info(
          "[Payment] shipping fee for #{order_number} settled to #{driver_principal_id}"
        )

        :ok

      {:ok, %{found: false}} ->
        Logger.error("[Payment] no escrow hold for #{order_number}; nothing was settled")
        count("not_found")
        {:error, :refused}

      {:error, %GRPC.RPCError{} = rpc_error} ->
        Logger.error(
          "[Payment] refused to settle #{order_number} for #{driver_principal_id}: " <>
            "#{rpc_error.status} #{rpc_error.message}"
        )

        count(to_string(rpc_error.status))
        {:error, :refused}

      {:error, reason} ->
        Logger.error("[Payment] settling #{order_number} failed: #{inspect(reason)}")
        count("unknown")
        {:error, :unavailable}
    end
  end

  @spec host() :: String.t() | nil
  defp host do
    case System.get_env("PAYMENT_GRPC_HOST") do
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
