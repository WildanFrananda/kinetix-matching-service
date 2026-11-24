defmodule KinetixMatching.TrackingFixtures do
  @moduledoc """
  Test data builders for the tracking domain.
  """

  alias KinetixMatching.FakeIdentity

  @type driver_fixture_t :: %{
          id: String.t(),
          courier_principal_id: String.t(),
          principal_id: String.t(),
          vehicle_plate: String.t(),
          capacity_kg: non_neg_integer(),
          active: boolean()
        }

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
        vehicle_plate: "B #{rem(unique, 10_000)} TEST",
        capacity_kg: 100
      },
      overrides
    )
  end

  @spec driver_fixture(map()) :: driver_fixture_t()
  def driver_fixture(overrides \\ %{}) do
    active_driver_fixture("principal-#{System.unique_integer([:positive])}", overrides)
  end

  @spec registered_driver_fixture(String.t(), map()) :: driver_fixture_t()
  def registered_driver_fixture(principal_id, overrides \\ %{}) do
    attrs = driver_attrs(overrides)

    standing =
      FakeIdentity.put_courier(principal_id, %{
        vehicle_plate: attrs.vehicle_plate,
        capacity_kg: attrs.capacity_kg,
        may_drive: false
      })

    to_fixture(standing)
  end

  @spec active_driver_fixture(String.t(), map()) :: driver_fixture_t()
  def active_driver_fixture(principal_id, overrides \\ %{}) do
    attrs = driver_attrs(overrides)

    standing =
      FakeIdentity.put_courier(principal_id, %{
        vehicle_plate: attrs.vehicle_plate,
        capacity_kg: attrs.capacity_kg,
        may_drive: true
      })

    to_fixture(standing)
  end

  @spec telemetry_attrs(map()) :: telemetry_attrs()
  def telemetry_attrs(overrides \\ %{}) do
    Map.merge(
      %{latitude: -6.2, longitude: 106.816666, recorded_at: DateTime.utc_now()},
      overrides
    )
  end

  @spec to_fixture(map()) :: driver_fixture_t()
  defp to_fixture(standing) do
    %{
      id: standing.courier_principal_id,
      courier_principal_id: standing.courier_principal_id,
      principal_id: standing.courier_principal_id,
      vehicle_plate: standing.vehicle_plate,
      capacity_kg: standing.capacity_kg,
      active: standing.may_drive
    }
  end
end
