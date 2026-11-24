defmodule KinetixMatching.Tracking.Snapshot do
  @moduledoc """
  Rebuilds a driver's last known state from PostgreSQL and Identity standing.
  """

  import Ecto.Query

  alias KinetixMatching.Clients.Identity
  alias KinetixMatching.Repo
  alias KinetixMatching.Tracking.LocationPing
  alias KinetixMatching.Types

  @active_job_statuses ["assigned", "picked_up"]

  @typedoc """
  The persisted fields worth restoring into a live driver process.
  """
  @type t :: %{
          status: Types.driver_status(),
          vehicle_plate: String.t(),
          capacity_kg: non_neg_integer(),
          active_jobs: non_neg_integer(),
          coordinates: Types.coordinates() | nil,
          speed_kmh: float() | nil,
          bearing_deg: float() | nil,
          recorded_at: DateTime.t() | nil
        }

  @spec fetch(Types.principal_id()) ::
          {:ok, t()} | {:error, :not_found | :pending_approval | :identity_unavailable}
  def fetch(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    case Identity.courier_standing(courier_principal_id) do
      {:ok, %{may_drive: true} = standing} ->
        {:ok,
         build(
           standing,
           last_ping(courier_principal_id),
           active_jobs(courier_principal_id)
         )}

      {:ok, %{may_drive: false}} ->
        {:error, :pending_approval}

      {:error, :not_found} ->
        {:error, :not_found}

      {:error, :unavailable} ->
        {:error, :identity_unavailable}
    end
  end

  def fetch(_courier_principal_id), do: {:error, :not_found}

  @spec last_ping(Types.principal_id()) :: LocationPing.t() | nil
  defp last_ping(courier_principal_id) do
    LocationPing
    |> where([p], p.courier_principal_id == ^courier_principal_id)
    |> order_by([p], desc: p.recorded_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec active_jobs(Types.principal_id()) :: non_neg_integer()
  defp active_jobs(courier_principal_id) do
    "deliveries"
    |> where(
      [o],
      o.courier_principal_id == ^courier_principal_id and o.status in @active_job_statuses
    )
    |> select([o], count(o.id))
    |> Repo.one()
  end

  @spec build(Identity.standing(), LocationPing.t() | nil, non_neg_integer()) :: t()
  defp build(standing, nil, active_jobs) do
    %{
      status: :offline,
      vehicle_plate: standing.vehicle_plate,
      capacity_kg: standing.capacity_kg,
      active_jobs: active_jobs,
      coordinates: nil,
      speed_kmh: nil,
      bearing_deg: nil,
      recorded_at: nil
    }
  end

  defp build(standing, %LocationPing{} = ping, active_jobs) do
    %{
      status: :offline,
      vehicle_plate: standing.vehicle_plate,
      capacity_kg: standing.capacity_kg,
      active_jobs: active_jobs,
      coordinates: {ping.latitude, ping.longitude},
      speed_kmh: ping.speed_kmh,
      bearing_deg: ping.bearing_deg,
      recorded_at: ping.recorded_at
    }
  end
end
