defmodule FleetPulse.Clients.OrderGrpc do
  @moduledoc """
  Dials the order service over the mesh to report a completed delivery.
  """

  @behaviour FleetPulse.Clients.Order

  require Logger

  alias FleetPulse.Observability.Metrics
  alias FleetPulse.Proto.Order.V1.OrderDeliveredRequest
  alias FleetPulse.Proto.Order.V1.OrderService.Stub
  alias FleetPulse.Security.ServiceIdentity

  @connect_timeout 3_000
  @call_timeout 8_000

  @peer "order"
  @method "/order.v1.OrderService/OrderDelivered"

  @impl FleetPulse.Clients.Order
  @spec delivered(String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, FleetPulse.Clients.Order.error()}
  def delivered(order_number, driver_principal_id, delivered_at) do
    case host() do
      nil ->
        Logger.error("[Order] ORDER_GRPC_HOST is unset; #{order_number} cannot be reported")
        count("failed_precondition")
        {:error, :not_configured}

      host ->
        dial(host, order_number, driver_principal_id, delivered_at)
    end
  end

  @spec dial(String.t(), String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, FleetPulse.Clients.Order.error()}
  defp dial(host, order_number, driver_principal_id, delivered_at) do
    case GRPC.Stub.connect(host, cred: credentials(), timeout: @connect_timeout) do
      {:ok, channel} ->
        try do
          call(channel, order_number, driver_principal_id, delivered_at)
        after
          GRPC.Stub.disconnect(channel)
        end

      {:error, reason} ->
        Logger.error(
          "[Order] could not reach #{host} to report #{order_number}: #{inspect(reason)}"
        )

        count("unavailable")
        {:error, :unavailable}
    end
  end

  @spec call(GRPC.Channel.t(), String.t(), String.t(), DateTime.t()) ::
          :ok | {:error, FleetPulse.Clients.Order.error()}
  defp call(channel, order_number, driver_principal_id, delivered_at) do
    request = %OrderDeliveredRequest{
      order_number: order_number,
      driver_principal_id: driver_principal_id,
      delivered_at: DateTime.to_iso8601(delivered_at)
    }

    case Stub.order_delivered(channel, request, timeout: @call_timeout) do
      {:ok, %{accepted: true, already_delivered: already}} ->
        Logger.info(
          "[Order] #{order_number} reported delivered by #{driver_principal_id}" <>
            if(already, do: " (already recorded)", else: "")
        )

        count("ok")
        :ok

      {:ok, %{accepted: false, error: error}} ->
        Logger.error("[Order] refused the delivery report for #{order_number}: #{inspect(error)}")

        count("invalid_argument")
        {:error, :refused}

      {:error, %GRPC.RPCError{} = rpc_error} ->
        Logger.error(
          "[Order] refused the delivery report for #{order_number}: " <>
            "#{rpc_error.status} #{rpc_error.message}"
        )

        count(to_string(rpc_error.status))
        {:error, :refused}

      {:error, reason} ->
        Logger.error("[Order] reporting #{order_number} failed: #{inspect(reason)}")
        count("unknown")
        {:error, :unavailable}
    end
  end

  @spec host() :: String.t() | nil
  defp host do
    case System.get_env("ORDER_GRPC_HOST") do
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
