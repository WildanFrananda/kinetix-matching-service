defmodule FleetPulse.ShippingTest do
  use ExUnit.Case, async: true

  alias FleetPulse.Shipping

  describe "calculate_options/4" do
    test "calculates distance and returns courier options correctly for short distance" do
      origin = %{latitude: -6.2088, longitude: 106.8456}
      destination = %{latitude: -6.2500, longitude: 106.8800}
      weight_kg = 2.5

      res = Shipping.calculate_options(origin, destination, weight_kg)

      assert res.distance_km > 0
      assert length(res.options) == 4

      instant = Enum.find(res.options, &(&1.service_tier == "KINETIX_INSTANT"))
      assert instant.is_available == true
      assert instant.base_shipping_fee > 15_000.0
    end

    test "marks instant option unavailable when distance exceeds 15km" do
      origin = %{latitude: -6.2088, longitude: 106.8456}
      destination = %{latitude: -6.5000, longitude: 106.8800} # > 30km
      weight_kg = 2.5

      res = Shipping.calculate_options(origin, destination, weight_kg)

      instant = Enum.find(res.options, &(&1.service_tier == "KINETIX_INSTANT"))
      assert instant.is_available == false
      assert instant.unavailable_reason == "Distance exceeds 15km limit"
    end
  end
end
