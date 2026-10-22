defmodule FleetPulse.Tracking do
  @moduledoc """
  The tracking context — the only public API of the driver-telemetry domain.
  """

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.DriverState
  alias FleetPulse.Tracking.DriverSupervisor
  alias FleetPulse.Tracking.Events
  alias FleetPulse.Tracking.Geo
  alias FleetPulse.Tracking.OfflineHistory
  alias FleetPulse.Tracking.StateCache
  alias FleetPulse.Tracking.Telemetry
  alias FleetPulse.Types

  @type nearby_driver :: {DriverState.t(), float()}

  @type nearby_opts :: [
          status: Driver.status() | :any,
          min_capacity_kg: non_neg_integer(),
          limit: pos_integer(),
          fresh: boolean()
        ]

  @typep filters :: %{
           status: Driver.status() | :any,
           min_capacity_kg: non_neg_integer(),
           fresh: boolean()
         }

  @spec fetch_driver(Types.id()) :: {:ok, Driver.t()} | {:error, :not_found}
  def fetch_driver(driver_id) do
    case Repo.get(Driver, driver_id) do
      nil -> {:error, :not_found}
      %Driver{} = driver -> {:ok, driver}
    end
  end

  @spec fetch_active_driver(Types.id()) ::
          {:ok, Driver.t()} | {:error, :not_found | :pending_approval}
  def fetch_active_driver(driver_id) do
    case fetch_driver(driver_id) do
      {:ok, %Driver{active: true} = driver} -> {:ok, driver}
      {:ok, %Driver{}} -> {:error, :pending_approval}
      {:error, :not_found} = error -> error
    end
  end

  @spec start_tracking(Types.id()) :: {:ok, pid()} | {:error, Types.reason()}
  def start_tracking(driver_id) do
    with {:ok, _driver} <- fetch_driver(driver_id) do
      DriverSupervisor.start_driver(driver_id)
    end
  end

  @spec attach_channel(Types.id(), pid()) :: {:ok, DriverState.t()} | {:error, Types.reason()}
  def attach_channel(driver_id, channel) do
    with {:ok, _pid} <- start_tracking(driver_id) do
      DriverState.attach(driver_id, channel)
    end
  end

  @spec detach_channel(Types.id(), pid()) :: :ok
  def detach_channel(driver_id, channel) do
    _ = DriverState.detach(driver_id, channel)
    :ok
  end

  @spec live_status(Types.id()) :: Driver.status()
  def live_status(driver_id) do
    case DriverState.fetch(driver_id) do
      {:ok, state} -> state.status
      {:error, :not_found} -> :offline
    end
  end

  @spec stop_tracking(Types.id()) :: :ok | {:error, :not_found}
  def stop_tracking(driver_id), do: DriverSupervisor.stop_driver(driver_id)

  @spec track_location(Types.id(), Telemetry.t()) ::
          :ok | {:error, :not_found | :invalid_telemetry}
  def track_location(driver_id, telemetry) do
    DriverState.update_location(driver_id, telemetry)
  end

  @spec record_offline_positions(Types.id(), term()) ::
          {:ok, OfflineHistory.outcome()} | {:error, OfflineHistory.error()}
  def record_offline_positions(driver_id, pings) do
    OfflineHistory.record(driver_id, pings, DateTime.utc_now())
  end

  @spec fetch_state(Types.id()) :: {:ok, DriverState.t()} | {:error, :not_found}
  def fetch_state(driver_id), do: DriverState.fetch(driver_id)

  @spec list_tracked() :: [DriverState.t()]
  def list_tracked, do: StateCache.all()

  @spec nearby(Types.coordinates(), float(), nearby_opts()) :: [nearby_driver()]
  def nearby(coordinates, radius_km, opts \\ []) do
    filters = %{
      status: Keyword.get(opts, :status, :online),
      min_capacity_kg: Keyword.get(opts, :min_capacity_kg, 0),
      fresh: Keyword.get(opts, :fresh, false)
    }

    box = Geo.bounding_box(coordinates, radius_km)

    StateCache.all()
    |> Enum.filter(&candidate?(&1, filters, box))
    |> Enum.map(&{&1, Geo.distance_km(coordinates, &1.coordinates)})
    |> Enum.filter(fn {_state, distance} -> distance <= radius_km end)
    |> Enum.sort_by(fn {_state, distance} -> distance end)
    |> take(Keyword.get(opts, :limit))
  end

  @spec set_status(Types.id(), Driver.status()) ::
          {:ok, DriverState.t()} | {:error, DriverState.duty_error() | Types.reason()}
  def set_status(driver_id, status) do
    with {:ok, _driver} <- fetch_driver(driver_id),
         {:ok, _pid} <- DriverSupervisor.start_driver(driver_id) do
      DriverState.set_duty(driver_id, status)
    end
  end

  @spec driver_for_principal(String.t()) ::
          {:ok, Driver.t()} | {:error, :pending_approval | :unlinked}
  def driver_for_principal(principal_id) when is_binary(principal_id) and principal_id != "" do
    case Repo.get_by(Driver, principal_id: principal_id) do
      %Driver{active: true} = driver -> {:ok, driver}
      %Driver{} -> {:error, :pending_approval}
      nil -> {:error, :unlinked}
    end
  end

  def driver_for_principal(_principal_id), do: {:error, :unlinked}

  @spec register_driver_for_principal(String.t(), map()) ::
          {:ok, Driver.t(), :created | :existing} | {:error, Driver.changeset()}
  def register_driver_for_principal(principal_id, attrs)
      when is_binary(principal_id) and is_map(attrs) do
    case Repo.get_by(Driver, principal_id: principal_id) do
      %Driver{} = existing ->
        {:ok, existing, :existing}

      nil ->
        insert_registration(principal_id, attrs)
    end
  end

  @spec insert_registration(String.t(), map()) ::
          {:ok, Driver.t(), :created | :existing} | {:error, Driver.changeset()}
  defp insert_registration(principal_id, attrs) do
    %Driver{}
    |> Driver.registration_changeset(attrs, principal_id)
    |> Repo.insert()
    |> case do
      {:ok, driver} ->
        {:ok, driver, :created}

      {:error, changeset} ->
        reread_after_conflict(principal_id, changeset)
    end
  end

  @spec reread_after_conflict(String.t(), Driver.changeset()) ::
          {:ok, Driver.t(), :existing} | {:error, Driver.changeset()}
  defp reread_after_conflict(principal_id, changeset) do
    with true <- Keyword.has_key?(changeset.errors, :principal_id),
         %Driver{} = driver <- Repo.get_by(Driver, principal_id: principal_id) do
      {:ok, driver, :existing}
    else
      _not_a_principal_race -> {:error, changeset}
    end
  end

  @spec activate_driver(String.t()) ::
          {:ok, Driver.t(), :activated | :already_active}
          | {:error, :unlinked | Driver.changeset()}
  def activate_driver(principal_id) when is_binary(principal_id) do
    case Repo.get_by(Driver, principal_id: principal_id) do
      nil ->
        {:error, :unlinked}

      %Driver{active: true} = driver ->
        {:ok, driver, :already_active}

      %Driver{} = driver ->
        driver
        |> Driver.changeset(%{active: true})
        |> Repo.update()
        |> case do
          {:ok, updated} -> {:ok, updated, :activated}
          {:error, changeset} -> {:error, changeset}
        end
    end
  end

  @spec subscribe_fleet() :: Events.subscribe_result()
  def subscribe_fleet, do: Events.subscribe_fleet()

  @spec subscribe_driver(Types.id()) :: Events.subscribe_result()
  def subscribe_driver(driver_id), do: Events.subscribe_driver(driver_id)

  @spec unsubscribe_fleet() :: :ok
  def unsubscribe_fleet, do: Events.unsubscribe_fleet()

  @spec unsubscribe_driver(Types.id()) :: :ok
  def unsubscribe_driver(driver_id), do: Events.unsubscribe_driver(driver_id)

  @spec candidate?(DriverState.t(), filters(), Geo.box()) :: boolean()
  defp candidate?(%DriverState{coordinates: nil}, _filters, _box), do: false

  defp candidate?(%DriverState{} = state, filters, box) do
    status_matches?(state.status, filters.status) and
      state.capacity_kg >= filters.min_capacity_kg and
      fresh_enough?(state, filters.fresh) and
      Geo.within_box?(state.coordinates, box)
  end

  @spec fresh_enough?(DriverState.t(), boolean()) :: boolean()
  defp fresh_enough?(_state, false), do: true
  defp fresh_enough?(state, true), do: DriverState.fresh?(state)

  @spec status_matches?(Driver.status(), Driver.status() | :any) :: boolean()
  defp status_matches?(_actual, :any), do: true
  defp status_matches?(status, status), do: true
  defp status_matches?(_actual, _wanted), do: false

  @spec take([nearby_driver()], pos_integer() | nil) :: [nearby_driver()]
  defp take(drivers, nil), do: drivers
  defp take(drivers, count), do: Enum.take(drivers, count)
end
