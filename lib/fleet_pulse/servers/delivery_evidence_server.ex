defmodule FleetPulse.Servers.DeliveryEvidenceServer do
  @moduledoc """
  Serves the delivery evidence log to the notary, which anchors it on chain.
  """

  use GRPC.Server, service: FleetPulse.Proto.Fulfillment.V1.DeliveryEvidenceService.Service

  alias FleetPulse.Dispatch.EvidenceFeed
  alias FleetPulse.Proto.Common.V1.LogCursor
  alias FleetPulse.Proto.Fulfillment.V1.DeliveriesSinceRequest
  alias FleetPulse.Proto.Fulfillment.V1.DeliveriesSinceResponse
  alias FleetPulse.Proto.Fulfillment.V1.DeliveryEvidence

  @default_limit 100
  @max_limit 500
  @max_sequence 9_223_372_036_854_775_807

  @spec deliveries_since(DeliveriesSinceRequest.t(), GRPC.Server.Stream.t()) ::
          DeliveriesSinceResponse.t()
  def deliveries_since(%DeliveriesSinceRequest{} = request, _stream) do
    page = EvidenceFeed.since(position(request.after), limit(request.limit))

    %DeliveriesSinceResponse{
      deliveries: Enum.map(page.deliveries, &wire/1),
      next: cursor(page.next),
      has_more: page.has_more
    }
  end

  @spec position(LogCursor.t() | nil) :: EvidenceFeed.position()
  defp position(nil), do: {0, 0}

  defp position(%LogCursor{sequence: sequence}) when sequence > @max_sequence do
    raise GRPC.RPCError,
      status: GRPC.Status.invalid_argument(),
      message: "the cursor's sequence is beyond any row"
  end

  defp position(%LogCursor{transaction_id: transaction_id, sequence: sequence}) do
    {transaction_id, sequence}
  end

  @spec limit(integer()) :: pos_integer()
  defp limit(requested) when requested <= 0, do: @default_limit
  defp limit(requested), do: min(requested, @max_limit)

  @spec cursor(EvidenceFeed.position()) :: LogCursor.t()
  defp cursor({transaction_id, sequence}) do
    %LogCursor{transaction_id: transaction_id, sequence: sequence}
  end

  @spec wire(EvidenceFeed.delivery()) :: DeliveryEvidence.t()
  defp wire(delivery) do
    %DeliveryEvidence{
      position: cursor(delivery.position),
      order_number: delivery.order_number || "",
      driver_principal_id: delivery.driver_principal_id,
      photo_sha256: delivery.photo_sha256,
      signature_sha256: delivery.signature_sha256 || "",
      delivered_at: Google.Protobuf.from_datetime(delivery.delivered_at)
    }
  end
end
