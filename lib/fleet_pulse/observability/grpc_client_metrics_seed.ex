defmodule FleetPulse.Observability.GrpcClientMetricsSeed do
  @moduledoc """
  Publishes `kinetix_grpc_client_calls_total` at zero for the calls this service places, at boot.
  """

  alias FleetPulse.Observability.Metrics

  @seed %{count: 0}

  @calls [
    {"payment", "/payment.v1.PaymentService/SettleShippingFee"},
    {"identity", "/identity.v1.IdentityService/GetUserProfile"}
  ]

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> seed() end]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec seed() :: [String.t()]
  def seed do
    Enum.map(@calls, &publish/1)
  end

  @spec calls() :: [{String.t(), String.t()}]
  def calls, do: @calls

  @spec publish({String.t(), String.t()}) :: String.t()
  defp publish({peer, method}) do
    :telemetry.execute(Metrics.grpc_client_call_event(), @seed, %{
      peer: peer,
      grpc_method: method,
      grpc_code: GRPC.Status.code_name(GRPC.Status.ok())
    })

    method
  end
end
