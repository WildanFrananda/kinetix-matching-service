defmodule KinetixMatchingWeb.Events.Mapper do
  @moduledoc """
  Translates internal Dispatch/Tracking domain structs and camelCase command payloads
  into unified X21 wire maps.
  """

  alias KinetixMatching.Dispatch.Order
  alias KinetixMatching.Tracking.Telemetry
  alias KinetixMatching.Types
  alias KinetixMatchingWeb.Events.Envelope

  @spec order_payload(Order.t()) :: map()
  def order_payload(%Order{} = order) do
    %{
      id: order.id,
      orderNumber: order.order_number,
      awbNumber: order.awb_number,
      status: Atom.to_string(order.status),
      merchantPrincipalId: order.merchant_principal_id,
      driverId: order.driver_id,
      weightKg: order.weight_kg,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assignedAt: Envelope.iso8601(order.assigned_at),
      deliveredAt: Envelope.iso8601(order.delivered_at),
      podPhotoUrl: order.pod_photo_url,
      podSignature: order.pod_signature,
      eventSequence: order.event_sequence
    }
  end

  @spec position_payload(Types.id(), Telemetry.t()) :: map()
  def position_payload(driver_id, telemetry) do
    %{
      driverId: driver_id,
      latitude: telemetry.latitude,
      longitude: telemetry.longitude,
      bearingDeg: telemetry.bearing_deg,
      speedKmh: telemetry.speed_kmh,
      recordedAt: Envelope.iso8601(telemetry.recorded_at)
    }
  end

  @spec pod_upload_payload(map()) :: map()
  def pod_upload_payload(upload) do
    %{
      uploadUrl: upload.upload_url,
      uploadHeaders: upload.upload_headers,
      photoUrl: upload.photo_url
    }
  end

  @spec offline_outcome_payload(map()) :: map()
  def offline_outcome_payload(outcome) do
    %{
      stored: outcome.stored,
      duplicates: outcome.duplicates,
      refused:
        Enum.map(outcome.refused, fn entry ->
          %{index: entry.index, reason: Atom.to_string(entry.reason)}
        end)
    }
  end

  @spec telemetry_params(term()) :: map() | term()
  def telemetry_params(data) when is_map(data) do
    %{
      "latitude" => Map.get(data, "latitude"),
      "longitude" => Map.get(data, "longitude"),
      "speed_kmh" => Map.get(data, "speedKmh"),
      "bearing_deg" => Map.get(data, "bearingDeg"),
      "recorded_at" => Map.get(data, "recordedAt")
    }
  end

  def telemetry_params(other), do: other

  @spec delivered_params(term()) :: map()
  def delivered_params(data) when is_map(data) do
    %{
      "pod_photo_url" => Map.get(data, "podPhotoUrl"),
      "pod_signature" => Map.get(data, "podSignature")
    }
    |> Enum.reject(fn {_key, val} -> is_nil(val) end)
    |> Map.new()
  end

  def delivered_params(_other), do: %{}
end
