defmodule FleetPulse.Tracking.OfflineHistoryTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias Ecto.Adapters.SQL.Sandbox
  alias FleetPulse.Tracking.LocationPing
  alias FleetPulse.Tracking.OfflineHistory
  alias FleetPulse.Tracking.PingRetention

  @now ~U[2026-10-21 03:00:00.000000Z]

  defp at(seconds_before_now), do: DateTime.add(@now, -seconds_before_now, :second)

  defp fix(recorded_at, overrides \\ %{}) do
    Map.merge(
      %{
        "latitude" => -6.2,
        "longitude" => 106.8,
        "speed_kmh" => 30,
        "bearing_deg" => 90,
        "recorded_at" => DateTime.to_iso8601(recorded_at)
      },
      overrides
    )
  end

  defp history(driver_id) do
    LocationPing
    |> where([p], p.driver_id == ^driver_id)
    |> order_by([p], asc: p.recorded_at)
    |> Repo.all()
  end

  setup do
    %{driver: driver_fixture()}
  end

  test "stores every position of a batch, in whatever order they come, as history", %{
    driver: driver
  } do
    batch = [
      fix(at(60)),
      fix(at(600), %{"latitude" => -6.3}),
      fix(at(300), %{"latitude" => -6.25})
    ]

    assert {:ok, %{stored: [0, 1, 2], duplicates: [], refused: []}} =
             OfflineHistory.record(driver.id, batch, @now)

    assert [first, second, third] = history(driver.id)
    assert {first.latitude, second.latitude, third.latitude} == {-6.3, -6.25, -6.2}
    assert first.speed_kmh === 30.0
    assert Enum.all?([first, second, third], &(&1.inserted_at == @now))
  end

  test "a position already stored, or sent twice in one batch, is a duplicate", %{driver: driver} do
    {:ok, _} = OfflineHistory.record(driver.id, [fix(at(120))], @now)

    assert {:ok, %{stored: [1], duplicates: [0, 2], refused: []}} =
             OfflineHistory.record(driver.id, [fix(at(120)), fix(at(90)), fix(at(90))], @now)

    assert length(history(driver.id)) == 2
  end

  test "another courier's position at the same moment is not a duplicate", %{driver: driver} do
    other = driver_fixture()
    {:ok, _} = OfflineHistory.record(other.id, [fix(at(120))], @now)

    assert {:ok, %{stored: [0]}} = OfflineHistory.record(driver.id, [fix(at(120))], @now)
  end

  test "refuses, one by one, a fix from the future, one too old and one that is not a fix", %{
    driver: driver
  } do
    batch = [
      fix(DateTime.add(@now, 301, :second)),
      fix(DateTime.add(@now, 240, :second)),
      fix(at(86_401)),
      fix(at(86_399)),
      fix(at(30), %{"latitude" => 999}),
      "not a fix"
    ]

    assert {:ok, outcome} = OfflineHistory.record(driver.id, batch, @now)

    assert outcome.stored == [1, 3]
    assert outcome.duplicates == []

    assert outcome.refused == [
             %{index: 0, reason: :ahead_of_server_clock},
             %{index: 2, reason: :too_old},
             %{index: 4, reason: :invalid_telemetry},
             %{index: 5, reason: :invalid_telemetry}
           ]

    assert length(history(driver.id)) == 2
  end

  test "refuses a batch larger than #{OfflineHistory.max_batch()}, and one that is not a list", %{
    driver: driver
  } do
    too_many = for second <- 0..OfflineHistory.max_batch(), do: fix(at(second + 1))

    assert {:error, :batch_too_large} = OfflineHistory.record(driver.id, too_many, @now)
    assert {:error, :invalid_batch} = OfflineHistory.record(driver.id, %{"0" => fix(at(1))}, @now)
    assert history(driver.id) == []
  end

  test "an empty batch stores nothing and says so", %{driver: driver} do
    assert {:ok, %{stored: [], duplicates: [], refused: []}} =
             OfflineHistory.record(driver.id, [], @now)
  end

  test "a database that cannot be asked is unavailable, so the phone keeps the batch", %{
    driver: driver
  } do
    Sandbox.mode(Repo, :manual)

    assert {:error, :unavailable} = OfflineHistory.record(driver.id, [fix(at(60))], @now)
  end

  test "kept as long as the live position's sample: retention counts from when it was stored" do
    driver = driver_fixture()
    now = DateTime.utc_now()

    {:ok, %{stored: [0]}} =
      OfflineHistory.record(driver.id, [fix(DateTime.add(now, -80_000))], now)

    Application.put_env(:fleet_pulse, PingRetention, enabled: true, retention_ms: 60_000)
    on_exit(fn -> Application.put_env(:fleet_pulse, PingRetention, enabled: false) end)
    start_supervised!(PingRetention)

    assert {:ok, 0} = PingRetention.prune_now()
    assert [_kept] = history(driver.id)
  end
end
