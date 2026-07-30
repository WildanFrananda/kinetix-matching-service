defmodule FleetPulse.Tracking.PingRetentionTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.LocationPing
  alias FleetPulse.Tracking.PingRetention

  setup do
    Application.put_env(:fleet_pulse, PingRetention,
      enabled: true,
      interval_ms: 3_600_000,
      retention_ms: 60_000
    )

    on_exit(fn -> Application.put_env(:fleet_pulse, PingRetention, enabled: false) end)
    start_supervised!(PingRetention)
    :ok
  end

  defp insert_ping(driver_id, inserted_at) do
    {1, [%{id: id}]} =
      Repo.insert_all(
        LocationPing,
        [
          %{
            driver_id: driver_id,
            latitude: -6.2,
            longitude: 106.8,
            recorded_at: DateTime.utc_now(),
            inserted_at: inserted_at
          }
        ],
        returning: [:id]
      )

    id
  end

  test "prunes pings older than the window and keeps recent ones" do
    driver = driver_fixture()
    old_id = insert_ping(driver.id, ~U[2020-01-01 00:00:00.000000Z])
    recent_id = insert_ping(driver.id, DateTime.utc_now())

    assert {:ok, deleted} = PingRetention.prune_now()
    assert deleted >= 1

    refute Repo.get(LocationPing, old_id)
    assert Repo.get(LocationPing, recent_id)
  end
end
