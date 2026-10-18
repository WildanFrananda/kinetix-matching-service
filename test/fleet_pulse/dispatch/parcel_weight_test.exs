defmodule FleetPulse.Dispatch.ParcelWeightTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}
  @delivery {-6.2088, 106.8456}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))
    :ok
  end

  defp online_driver(capacity_kg) do
    driver = driver_fixture(%{capacity_kg: capacity_kg})

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      _ = StateCache.delete(driver.id)
    end)

    {:ok, _pid} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(
        driver.id,
        telemetry_attrs(%{latitude: elem(@pickup, 0), longitude: elem(@pickup, 1)})
      )

    {:ok, _state} = Tracking.fetch_state(driver.id)
    driver
  end

  defp order_number, do: "ORD-WEIGHT-#{System.unique_integer([:positive])}"

  test "a job carries the parcel's weight, rounded up to the next whole kilogram" do
    _driver = online_driver(100)

    assert {:ok, order} =
             Dispatch.dispatch_for_order(order_number(), "merchant-1", @pickup, @delivery, 1_200)

    assert order.weight_kg == 2
  end

  test "a courier who cannot carry the parcel is not given it" do
    _small = online_driver(1)

    assert {:error, :no_driver_available} =
             Dispatch.dispatch_for_order(order_number(), "merchant-1", @pickup, @delivery, 1_200)
  end

  test "the courier who can carry it is chosen when another cannot" do
    _small = online_driver(1)
    big = online_driver(30)

    assert {:ok, order} =
             Dispatch.dispatch_for_order(order_number(), "merchant-1", @pickup, @delivery, 25_000)

    assert order.weight_kg == 25
    assert order.driver_id == big.id
  end

  test "a caller that states no weight books a job of none, as before weights were sent" do
    _driver = online_driver(100)

    assert {:ok, order} =
             Dispatch.dispatch_for_order(order_number(), "merchant-1", @pickup, @delivery, 0)

    assert order.weight_kg == 0
  end

  test "a negative weight is refused rather than booked" do
    assert {:error, :negative_parcel_weight} =
             Dispatch.dispatch_for_order(order_number(), "merchant-1", @pickup, @delivery, -1)
  end
end
