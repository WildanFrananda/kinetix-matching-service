defmodule FleetPulse.Tracking do
  @moduledoc """
  The tracking context — the only public API of the driver-telemetry domain.
  """

  import Ecto.Query

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.DriverState
  alias FleetPulse.Tracking.DriverSupervisor
  alias FleetPulse.Tracking.Events
  alias FleetPulse.Tracking.Geo
  alias FleetPulse.Tracking.StateCache
  alias FleetPulse.Tracking.Telemetry
  alias FleetPulse.Types

  @type nearby_driver :: {DriverState.t(), float()}

  @type nearby_opts :: [
          status: Driver.status() | :any,
          min_capacity_kg: non_neg_integer(),
          limit: pos_integer()
        ]

  @typep filters :: %{status: Driver.status() | :any, min_capacity_kg: non_neg_integer()}

  @spec create_driver(map()) :: {:ok, Driver.t()} | {:error, Driver.changeset()}
  def create_driver(attrs) do
    %Driver{}
    |> Driver.changeset(attrs)
    |> Repo.insert()
  end

  @spec fetch_driver(Types.id()) :: {:ok, Driver.t()} | {:error, :not_found}
  def fetch_driver(driver_id) do
    case Repo.get(Driver, driver_id) do
      nil -> {:error, :not_found}
      %Driver{} = driver -> {:ok, driver}
    end
  end

  @spec list_drivers() :: [Driver.t()]
  def list_drivers do
    Driver
    |> order_by([d], asc: d.name)
    |> Repo.all()
  end

  @spec start_tracking(Types.id()) :: {:ok, pid()} | {:error, Types.reason()}
  def start_tracking(driver_id) do
    with {:ok, _driver} <- fetch_driver(driver_id) do
      DriverSupervisor.start_driver(driver_id)
    end
  end

  @spec stop_tracking(Types.id()) :: :ok | {:error, :not_found}
  def stop_tracking(driver_id), do: DriverSupervisor.stop_driver(driver_id)

  @spec track_location(Types.id(), Telemetry.t()) ::
          :ok | {:error, :not_found | :invalid_telemetry}
  def track_location(driver_id, telemetry) do
    DriverState.update_location(driver_id, telemetry)
  end

  @spec fetch_state(Types.id()) :: {:ok, DriverState.t()} | {:error, :not_found}
  def fetch_state(driver_id), do: DriverState.fetch(driver_id)

  @spec list_tracked() :: [DriverState.t()]
  def list_tracked, do: StateCache.all()

  @spec nearby(Types.coordinates(), float(), nearby_opts()) :: [nearby_driver()]
  def nearby(coordinates, radius_km, opts \\ []) do
    filters = %{
      status: Keyword.get(opts, :status, :online),
      min_capacity_kg: Keyword.get(opts, :min_capacity_kg, 0)
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
          {:ok, Driver.t()} | {:error, :not_found | Driver.changeset()}
  def set_status(driver_id, status) do
    with {:ok, driver} <- fetch_driver(driver_id),
         {:ok, updated} <- persist_status(driver, status) do
      _ = DriverState.update_status(driver_id, status)
      {:ok, updated}
    end
  end

  @spec driver_for_principal(String.t()) :: {:ok, Driver.t()} | {:error, :unlinked}
  def driver_for_principal(principal_id) when is_binary(principal_id) and principal_id != "" do
    case Repo.get_by(Driver, principal_id: principal_id) do
      %Driver{active: true} = driver -> {:ok, driver}
      _inactive_or_missing -> {:error, :unlinked}
    end
  end

  def driver_for_principal(_principal_id), do: {:error, :unlinked}

  @spec link_driver_to_principal(Driver.t(), String.t()) ::
          {:ok, Driver.t()} | {:error, Driver.changeset()}
  def link_driver_to_principal(%Driver{} = driver, principal_id) do
    driver
    |> Driver.principal_changeset(%{principal_id: principal_id})
    |> Repo.update()
  end

  @spec register_driver(map(), String.t()) :: {:ok, Driver.t()} | {:error, Driver.changeset()}
  def register_driver(attrs, principal_id) when is_map(attrs) and is_binary(principal_id) do
    %Driver{}
    |> Driver.registration_changeset(attrs, principal_id)
    |> Repo.insert()
  end

  @spec list_pending_drivers() :: [Driver.t()]
  def list_pending_drivers do
    Driver
    |> where([d], d.active == false)
    |> order_by([d], asc: d.inserted_at)
    |> Repo.all()
  end

  @spec approve_driver(Types.id()) ::
          {:ok, Driver.t()} | {:error, :not_found | Driver.changeset()}
  def approve_driver(driver_id) do
    with {:ok, driver} <- fetch_driver(driver_id) do
      driver
      |> Driver.changeset(%{active: true})
      |> Repo.update()
    end
  end

  @spec reject_driver(Types.id()) :: {:ok, Driver.t()} | {:error, :not_found | Ecto.Changeset.t()}
  def reject_driver(driver_id) do
    with {:ok, driver} <- fetch_driver(driver_id) do
      Repo.delete(driver)
    end
  end

  @spec persist_status(Driver.t(), Driver.status()) ::
          {:ok, Driver.t()} | {:error, Driver.changeset()}
  defp persist_status(driver, status) do
    driver
    |> Driver.status_changeset(%{status: status})
    |> Repo.update()
  end

  @spec subscribe_fleet() :: Events.subscribe_result()
  def subscribe_fleet, do: Events.subscribe_fleet()

  @spec subscribe_driver(Types.id()) :: Events.subscribe_result()
  def subscribe_driver(driver_id), do: Events.subscribe_driver(driver_id)

  @spec unsubscribe_fleet() :: :ok
  def unsubscribe_fleet, do: Events.unsubscribe_fleet()

  @spec unsubscribe_driver(Types.id()) :: :ok
  def unsubscribe_driver(driver_id), do: Events.unsubscribe_driver(driver_id)

  @spec candidate?(DriverState.t(), Driver.status() | :any, Geo.box()) :: boolean()
  @spec candidate?(DriverState.t(), filters(), Geo.box()) :: boolean()
  defp candidate?(%DriverState{coordinates: nil}, _filters, _box), do: false

  defp candidate?(%DriverState{} = state, filters, box) do
    status_matches?(state.status, filters.status) and
      state.capacity_kg >= filters.min_capacity_kg and
      Geo.within_box?(state.coordinates, box)
  end

  @spec status_matches?(Driver.status(), Driver.status() | :any) :: boolean()
  defp status_matches?(_actual, :any), do: true
  defp status_matches?(status, status), do: true
  defp status_matches?(_actual, _wanted), do: false

  @spec take([nearby_driver()], pos_integer() | nil) :: [nearby_driver()]
  defp take(drivers, nil), do: drivers
  defp take(drivers, count), do: Enum.take(drivers, count)
end
