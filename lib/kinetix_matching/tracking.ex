defmodule KinetixMatching.Tracking do
  @moduledoc """
  The tracking context — the only public API of the courier-telemetry domain.

  Courier identity, vehicle plate, capacity, and approval standing are owned by
  `kinetix-identity-service` and fetched via `KinetixMatching.Clients.Identity`.
  """

  alias KinetixMatching.Clients.Identity
  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Tracking.DriverSupervisor
  alias KinetixMatching.Tracking.Events
  alias KinetixMatching.Tracking.Geo
  alias KinetixMatching.Tracking.OfflineHistory
  alias KinetixMatching.Tracking.StateCache
  alias KinetixMatching.Tracking.Telemetry
  alias KinetixMatching.Types

  @type nearby_driver :: {DriverState.t(), float()}

  @type nearby_opts :: [
          status: Types.driver_status() | :any,
          min_capacity_kg: non_neg_integer(),
          limit: pos_integer(),
          fresh: boolean()
        ]

  @typep filters :: %{
           status: Types.driver_status() | :any,
           min_capacity_kg: non_neg_integer(),
           fresh: boolean()
         }

  @spec courier_standing(Types.principal_id()) ::
          {:ok, Identity.standing()}
          | {:error, :not_found | :pending_approval | :identity_unavailable}
  def courier_standing(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    case Identity.courier_standing(courier_principal_id) do
      {:ok, %{may_drive: true} = standing} -> {:ok, standing}
      {:ok, %{may_drive: false}} -> {:error, :pending_approval}
      {:error, :not_found} -> {:error, :not_found}
      {:error, :unavailable} -> {:error, :identity_unavailable}
    end
  end

  def courier_standing(_courier_principal_id), do: {:error, :not_found}

  @spec driver_for_principal(Types.principal_id()) ::
          {:ok, Identity.standing()}
          | {:error, :unlinked | :pending_approval | :identity_unavailable}
  def driver_for_principal(principal_id) when is_binary(principal_id) and principal_id != "" do
    case courier_standing(principal_id) do
      {:ok, standing} -> {:ok, standing}
      {:error, :not_found} -> {:error, :unlinked}
      {:error, reason} -> {:error, reason}
    end
  end

  def driver_for_principal(_principal_id), do: {:error, :unlinked}

  @spec start_tracking(Types.principal_id()) :: {:ok, pid()} | {:error, Types.reason()}
  def start_tracking(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    with {:ok, standing} <- courier_standing(courier_principal_id),
         {:ok, pid} <- DriverSupervisor.start_driver(courier_principal_id),
         {:ok, _state} <-
           DriverState.refresh_standing(
             courier_principal_id,
             standing.vehicle_plate,
             standing.capacity_kg
           ) do
      {:ok, pid}
    end
  end

  def start_tracking(_courier_principal_id), do: {:error, :not_found}

  @spec attach_channel(Types.principal_id(), pid()) ::
          {:ok, DriverState.t()} | {:error, Types.reason()}
  def attach_channel(courier_principal_id, channel) do
    with {:ok, _pid} <- start_tracking(courier_principal_id) do
      DriverState.attach(courier_principal_id, channel)
    end
  end

  @spec detach_channel(Types.principal_id(), pid()) :: :ok
  def detach_channel(courier_principal_id, channel) do
    _ = DriverState.detach(courier_principal_id, channel)
    :ok
  end

  @spec live_status(Types.principal_id()) :: Types.driver_status()
  def live_status(courier_principal_id) do
    case DriverState.fetch(courier_principal_id) do
      {:ok, state} -> state.status
      {:error, :not_found} -> :offline
    end
  end

  @spec stop_tracking(Types.principal_id()) :: :ok | {:error, :not_found}
  def stop_tracking(courier_principal_id), do: DriverSupervisor.stop_driver(courier_principal_id)

  @spec track_location(Types.principal_id(), Telemetry.t()) ::
          :ok | {:error, :not_found | :invalid_telemetry}
  def track_location(courier_principal_id, telemetry) do
    DriverState.update_location(courier_principal_id, telemetry)
  end

  @spec record_offline_positions(Types.principal_id(), term()) ::
          {:ok, OfflineHistory.outcome()} | {:error, OfflineHistory.error()}
  def record_offline_positions(courier_principal_id, pings) do
    OfflineHistory.record(courier_principal_id, pings, DateTime.utc_now())
  end

  @spec fetch_state(Types.principal_id()) :: {:ok, DriverState.t()} | {:error, :not_found}
  def fetch_state(courier_principal_id) when is_binary(courier_principal_id),
    do: DriverState.fetch(courier_principal_id)

  def fetch_state(_courier_principal_id), do: {:error, :not_found}

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

  @spec set_status(Types.principal_id(), Types.driver_status()) ::
          {:ok, DriverState.t()} | {:error, DriverState.duty_error() | Types.reason()}
  def set_status(courier_principal_id, :offline)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    case DriverState.set_duty(courier_principal_id, :offline) do
      {:error, :not_found} ->
        with {:ok, _pid} <- start_tracking(courier_principal_id) do
          DriverState.set_duty(courier_principal_id, :offline)
        end

      result ->
        result
    end
  end

  def set_status(courier_principal_id, status)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    with {:ok, _pid} <- start_tracking(courier_principal_id) do
      DriverState.set_duty(courier_principal_id, status)
    end
  end

  def set_status(_courier_principal_id, _status), do: {:error, :not_found}

  @spec subscribe_fleet() :: Events.subscribe_result()
  def subscribe_fleet, do: Events.subscribe_fleet()

  @spec subscribe_driver(Types.principal_id()) :: Events.subscribe_result()
  def subscribe_driver(courier_principal_id), do: Events.subscribe_driver(courier_principal_id)

  @spec unsubscribe_fleet() :: :ok
  def unsubscribe_fleet, do: Events.unsubscribe_fleet()

  @spec unsubscribe_driver(Types.principal_id()) :: :ok
  def unsubscribe_driver(courier_principal_id),
    do: Events.unsubscribe_driver(courier_principal_id)

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

  @spec status_matches?(Types.driver_status(), Types.driver_status() | :any) :: boolean()
  defp status_matches?(_actual, :any), do: true
  defp status_matches?(status, status), do: true
  defp status_matches?(_actual, _wanted), do: false

  @spec take([nearby_driver()], pos_integer() | nil) :: [nearby_driver()]
  defp take(drivers, nil), do: drivers
  defp take(drivers, count), do: Enum.take(drivers, count)
end
