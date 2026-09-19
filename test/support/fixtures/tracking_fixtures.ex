defmodule FleetPulse.TrackingFixtures do
  @moduledoc """
  Test data builders for the tracking domain.
  """

  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.Driver

  @type driver_attrs :: %{
          required(:vehicle_plate) => term(),
          required(:capacity_kg) => term(),
          optional(atom()) => term()
        }

  @type telemetry_attrs :: %{
          required(:latitude) => term(),
          required(:longitude) => term(),
          required(:recorded_at) => term(),
          optional(atom()) => term()
        }

  @spec driver_attrs(map()) :: driver_attrs()
  def driver_attrs(overrides \\ %{}) do
    unique = System.unique_integer([:positive])

    Map.merge(
      %{
        vehicle_plate: "b #{rem(unique, 10_000)} test",
        capacity_kg: 100
      },
      overrides
    )
  end

  @spec driver_fixture(map()) :: Driver.t()
  def driver_fixture(overrides \\ %{}) do
    {:ok, driver} = Tracking.create_driver(driver_attrs(overrides))
    driver
  end

  @spec registered_driver_fixture(String.t(), map()) :: Driver.t()
  def registered_driver_fixture(principal_id, overrides \\ %{}) do
    {:ok, driver, _outcome} =
      Tracking.register_driver_for_principal(principal_id, driver_attrs(overrides))

    driver
  end

  @spec active_driver_fixture(String.t(), map()) :: Driver.t()
  def active_driver_fixture(principal_id, overrides \\ %{}) do
    _pending = registered_driver_fixture(principal_id, overrides)
    {:ok, driver, _outcome} = Tracking.activate_driver(principal_id)

    driver
  end

  @spec telemetry_attrs(map()) :: driver_attrs()
  def telemetry_attrs(overrides \\ %{}) do
    Map.merge(
      %{latitude: -6.2, longitude: 106.816666, recorded_at: DateTime.utc_now()},
      overrides
    )
  end
end
