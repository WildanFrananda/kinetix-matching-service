defmodule FleetPulse.Tracking.Snapshot do
  @moduledoc """
  Rebuilds a driver's last known state from PostgreSQL.
  """

  import Ecto.Query

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.LocationPing
  alias FleetPulse.Types

  @active_job_statuses ["assigned", "picked_up"]

  @typedoc """
  The persisted fields worth restoring into a live driver process.
  """
  @type t :: %{
          status: Driver.status(),
          capacity_kg: non_neg_integer(),
          active_jobs: non_neg_integer(),
          coordinates: Types.coordinates() | nil,
          speed_kmh: float() | nil,
          bearing_deg: float() | nil,
          recorded_at: DateTime.t() | nil
        }

  @spec fetch(Types.id()) :: {:ok, t()} | {:error, :not_found}
  def fetch(driver_id) do
    case Repo.get(Driver, driver_id) do
      nil -> {:error, :not_found}
      %Driver{} = driver -> {:ok, build(driver, last_ping(driver_id), active_jobs(driver_id))}
    end
  end

  @spec last_ping(Types.id()) :: LocationPing.t() | nil
  defp last_ping(driver_id) do
    LocationPing
    |> where([p], p.driver_id == ^driver_id)
    |> order_by([p], desc: p.recorded_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec active_jobs(Types.id()) :: non_neg_integer()
  defp active_jobs(driver_id) do
    "orders"
    |> where([o], o.driver_id == ^driver_id and o.status in @active_job_statuses)
    |> select([o], count(o.id))
    |> Repo.one()
  end

  @spec build(Driver.t(), LocationPing.t() | nil, non_neg_integer()) :: t()
  defp build(%Driver{} = driver, nil, active_jobs) do
    %{
      status: driver.status,
      capacity_kg: driver.capacity_kg,
      active_jobs: active_jobs,
      coordinates: nil,
      speed_kmh: nil,
      bearing_deg: nil,
      recorded_at: nil
    }
  end

  defp build(%Driver{} = driver, %LocationPing{} = ping, active_jobs) do
    %{
      status: driver.status,
      capacity_kg: driver.capacity_kg,
      active_jobs: active_jobs,
      coordinates: {ping.latitude, ping.longitude},
      speed_kmh: ping.speed_kmh,
      bearing_deg: ping.bearing_deg,
      recorded_at: ping.recorded_at
    }
  end
end
