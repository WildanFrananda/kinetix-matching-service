defmodule FleetPulse.Servers.ShippingServer do
  @moduledoc """
  gRPC Server Handler for Shipping Fee Estimation (PRD shipping_courier_selection_prd).
  """

  alias FleetPulse.Shipping

  def estimate_shipping_options(request, _stream) do
    origin = %{
      latitude: request.origin.latitude,
      longitude: request.origin.longitude
    }

    destination = %{
      latitude: request.destination.latitude,
      longitude: request.destination.longitude
    }

    res = Shipping.calculate_options(origin, destination, request.total_weight_kg, request.merchant_id)

    options =
      Enum.map(res.options, fn opt ->
        %{
          service_tier: opt.service_tier,
          service_name: opt.service_name,
          distance_km: opt.distance_km,
          base_shipping_fee: opt.base_shipping_fee,
          estimated_delivery_time: opt.estimated_delivery_time,
          is_available: opt.is_available,
          unavailable_reason: opt.unavailable_reason || ""
        }
      end)

    %{
      distance_km: res.distance_km,
      options: options
    }
  end
end
