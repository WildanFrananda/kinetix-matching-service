defmodule FleetPulse.Dispatch.TelemetryTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.StateCache

  @pickup {-6.1754, 106.8272}

  setup do
    Enum.each(StateCache.all(), &StateCache.delete(&1.driver_id))

    test_pid = self()

    events = [
      [:fleet_pulse, :dispatch, :order_created],
      [:fleet_pulse, :dispatch, :order_assigned],
      [:fleet_pulse, :dispatch, :dispatch_failed],
      [:fleet_pulse, :dispatch, :order_delivered]
    ]

    handler = "test-#{System.unique_integer([:positive])}"

    :telemetry.attach_many(
      handler,
      events,
      fn name, measurements, metadata, _config ->
        send(test_pid, {:telemetry, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler) end)
    :ok
  end

  defp order_attrs do
    %{
      pickup_latitude: elem(@pickup, 0),
      pickup_longitude: elem(@pickup, 1),
      dropoff_latitude: -6.9,
      dropoff_longitude: 107.6,
      weight_kg: 50
    }
  end

  defp online_driver do
    driver = driver_fixture()
    {:ok, _} = Tracking.start_tracking(driver.id)
    {:ok, _} = Tracking.set_status(driver.id, :online)

    :ok =
      Tracking.track_location(driver.id, %{
        latitude: elem(@pickup, 0),
        longitude: elem(@pickup, 1),
        recorded_at: DateTime.utc_now()
      })

    {:ok, _} = Tracking.fetch_state(driver.id)

    on_exit(fn ->
      _ = Tracking.stop_tracking(driver.id)
      StateCache.delete(driver.id)
    end)

    driver
  end

  test "emits order_created on creation" do
    {:ok, _} = Dispatch.create_order(order_attrs())
    assert_receive {:telemetry, [:fleet_pulse, :dispatch, :order_created], %{count: 1}, _meta}
  end

  test "emits order_assigned with a time-to-assign measurement" do
    online_driver()
    {:ok, order} = Dispatch.create_order(order_attrs())
    {:ok, _} = Dispatch.assign_order(order.id)

    assert_receive {:telemetry, [:fleet_pulse, :dispatch, :order_assigned],
                    %{count: 1, time_to_assign_ms: ms}, _meta}

    assert is_integer(ms) and ms >= 0
  end

  test "emits dispatch_failed when no driver is available" do
    {:ok, order} = Dispatch.create_order(order_attrs())
    {:error, :no_driver_available} = Dispatch.assign_order(order.id)

    assert_receive {:telemetry, [:fleet_pulse, :dispatch, :dispatch_failed], %{count: 1}, _meta}
  end

  test "emits order_delivered on delivery" do
    driver = online_driver()
    {:ok, order} = Dispatch.create_order(order_attrs())
    {:ok, _} = Dispatch.assign_order(order.id)
    {:ok, _} = Dispatch.mark_picked_up(order.id, driver.id)
    {:ok, _} = Dispatch.mark_delivered(order.id, driver.id)

    assert_receive {:telemetry, [:fleet_pulse, :dispatch, :order_delivered], %{count: 1}, _meta}
  end
end
