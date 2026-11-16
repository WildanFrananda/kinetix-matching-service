defmodule KinetixMatching.OrderServiceDouble do
  @moduledoc """
  Order's gRPC server as the client suite needs it: it records each delivery it is told of and accepts it.
  """

  use GRPC.Server, service: KinetixMatching.Proto.Order.V1.OrderService.Service

  alias KinetixMatching.Proto.Order.V1.OrderDeliveredRequest
  alias KinetixMatching.Proto.Order.V1.OrderDeliveredResponse

  @listener :order_service_double_listener

  @spec listen() :: true
  def listen, do: Process.register(self(), @listener)

  @spec order_delivered(OrderDeliveredRequest.t(), GRPC.Server.Stream.t()) ::
          OrderDeliveredResponse.t()
  def order_delivered(%OrderDeliveredRequest{} = request, _stream) do
    send(@listener, {:order_delivered, request})

    %OrderDeliveredResponse{accepted: true, already_delivered: false}
  end
end
