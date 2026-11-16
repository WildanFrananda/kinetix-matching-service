defmodule KinetixMatchingWeb.Events.EnvelopeTest do
  use ExUnit.Case, async: true

  alias KinetixMatching.Dispatch.Order
  alias KinetixMatchingWeb.Events.Envelope
  alias KinetixMatchingWeb.Events.Mapper

  test "builds unified camelCase server event envelopes with UUIDv7 and schemaVersion" do
    envelope =
      Envelope.server_event("matching.job.assigned", "ORD-123", 2, %{
        order: %{id: 9}
      })

    assert envelope.event == "matching.job.assigned"
    assert envelope.schemaVersion == 1
    assert envelope.orderId == "ORD-123"
    assert envelope.sequence == 2
    assert is_binary(envelope.eventId)
    assert is_binary(envelope.occurredAt)
    assert envelope.data == %{order: %{id: 9}}
  end

  test "maps structured command.error envelopes with retryable flag" do
    rate_limited = Envelope.error("req-1", :rate_limited)
    assert rate_limited.event == "command.error"
    assert rate_limited.requestId == "req-1"
    assert rate_limited.schemaVersion == 1
    assert rate_limited.error.code == "RATE_LIMITED"
    assert rate_limited.error.reason == "rate_limited"
    assert rate_limited.error.retryable == true

    invalid_telemetry = Envelope.error("req-2", :invalid_telemetry)
    assert invalid_telemetry.error.code == "INVALID_TELEMETRY"
    assert invalid_telemetry.error.retryable == false
  end

  test "maps Order struct to camelCase wire payload" do
    now = DateTime.utc_now()

    order = %Order{
      id: 42,
      order_number: "ORD-42",
      awb_number: "KNX-42",
      status: :assigned,
      merchant_principal_id: "merchant-1",
      driver_id: 7,
      weight_kg: 12,
      pickup_latitude: -6.2,
      pickup_longitude: 106.8,
      dropoff_latitude: -6.21,
      dropoff_longitude: 106.82,
      assigned_at: now,
      delivered_at: nil,
      pod_photo_url: nil,
      pod_signature: nil,
      event_sequence: 3
    }

    mapped = Mapper.order_payload(order)
    assert mapped.id == 42
    assert mapped.orderNumber == "ORD-42"
    assert mapped.awbNumber == "KNX-42"
    assert mapped.status == "assigned"
    assert mapped.merchantPrincipalId == "merchant-1"
    assert mapped.driverId == 7
    assert mapped.weightKg == 12
    assert mapped.eventSequence == 3
    assert mapped.assignedAt == DateTime.to_iso8601(now)
  end
end
