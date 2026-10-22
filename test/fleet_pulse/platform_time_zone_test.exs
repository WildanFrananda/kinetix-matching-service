defmodule FleetPulse.PlatformTimeZoneTest do
  use ExUnit.Case, async: false

  alias FleetPulse.PlatformTimeZone

  setup do
    previous = Application.fetch_env!(:fleet_pulse, :time_zone)
    on_exit(fn -> Application.put_env(:fleet_pulse, :time_zone, previous) end)
    :ok
  end

  test "a day starts at local midnight, given back in UTC" do
    assert PlatformTimeZone.start_of_day(~U[2026-10-21 03:00:00Z]) ==
             ~U[2026-10-20 17:00:00.000000Z]

    assert PlatformTimeZone.start_of_day(~U[2026-10-20 16:59:59Z]) ==
             ~U[2026-10-19 17:00:00.000000Z]
  end

  test "a midnight a clock change skips starts the day at the first moment that exists" do
    Application.put_env(:fleet_pulse, :time_zone, "America/Santiago")

    assert PlatformTimeZone.start_of_day(~U[2026-09-06 12:00:00Z]) ==
             ~U[2026-09-06 04:00:00.000000Z]
  end

  test "a name that is not a zone refuses to start" do
    Application.put_env(:fleet_pulse, :time_zone, "Mars/Olympus_Mons")

    assert_raise ArgumentError,
                 ~r/KINETIX_TIME_ZONE "Mars\/Olympus_Mons" is not a time zone/,
                 fn ->
                   PlatformTimeZone.fetch!()
                 end
  end
end
