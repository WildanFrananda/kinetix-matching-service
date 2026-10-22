defmodule FleetPulse.Tracking.DriverState do
  @moduledoc """
  GenServer process holding ONE driver's live state in memory (PRD 5.2).

  This is why FleetPulse does not hit the database every three seconds: a
  location update only rewrites a map inside this process. Persistence happens
  separately and in batches.

  `restart: :transient` — a process that stops normally (driver logged out) is
  NOT restarted. Only crashes trigger a restart.

  Every change of status is written to `drivers.status` by this process
  (`StatusRecord`), so the row agrees with it.
  """

  use GenServer, restart: :transient

  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Tracking.DriverRegistry
  alias FleetPulse.Tracking.Events
  alias FleetPulse.Tracking.Snapshot
  alias FleetPulse.Tracking.StateCache
  alias FleetPulse.Tracking.StatusRecord
  alias FleetPulse.Tracking.Telemetry
  alias FleetPulse.Types

  @default_max_orders 1

  @typedoc """
  A driver's live state.
  """
  @type t :: %__MODULE__{
          driver_id: Types.id(),
          capacity_kg: non_neg_integer(),
          active_orders_count: non_neg_integer(),
          max_orders: pos_integer(),
          status: Driver.status(),
          coordinates: Types.coordinates() | nil,
          speed_kmh: float() | nil,
          bearing_deg: float() | nil,
          recorded_at: DateTime.t() | nil,
          synced_at: DateTime.t() | nil,
          located_at: DateTime.t() | nil,
          on_duty_since: DateTime.t() | nil,
          channel: pid() | nil,
          channel_monitor: reference() | nil
        }

  @type duty_error :: :not_found | :invalid_status | :no_active_job

  @enforce_keys [:driver_id]
  defstruct [
    :driver_id,
    :coordinates,
    :speed_kmh,
    :bearing_deg,
    :recorded_at,
    :synced_at,
    :located_at,
    :on_duty_since,
    :channel,
    :channel_monitor,
    capacity_kg: 0,
    active_orders_count: 0,
    max_orders: @default_max_orders,
    status: :offline
  ]

  @spec start_link(Types.id()) :: GenServer.on_start()
  def start_link(driver_id) when is_integer(driver_id) and driver_id > 0 do
    GenServer.start_link(__MODULE__, driver_id, name: DriverRegistry.via(driver_id))
  end

  @doc """
  Reads a snapshot of a driver's live state.
  """
  @spec fetch(Types.id()) :: {:ok, t()} | {:error, :not_found}
  def fetch(driver_id) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> safe_call(pid, :fetch)
      {:error, :not_found} = error -> error
    end
  end

  @spec update_location(Types.id(), Telemetry.t()) ::
          :ok | {:error, :not_found | :invalid_telemetry}
  def update_location(driver_id, telemetry) do
    with {:ok, telemetry} <- Telemetry.normalise(telemetry),
         :ok <- Telemetry.not_ahead_of(telemetry, DateTime.utc_now()),
         {:ok, pid} <- DriverRegistry.whereis(driver_id) do
      GenServer.cast(pid, {:update_location, telemetry})
    end
  end

  @spec set_duty(Types.id(), Driver.status()) :: {:ok, t()} | {:error, duty_error()}
  def set_duty(driver_id, status) do
    with true <- status in Driver.statuses(), {:ok, pid} <- DriverRegistry.whereis(driver_id) do
      safe_call(pid, {:set_duty, status})
    else
      false -> {:error, :invalid_status}
      {:error, :not_found} = error -> error
    end
  end

  @spec attach(Types.id(), pid()) :: {:ok, t()} | {:error, :not_found}
  def attach(driver_id, channel) when is_pid(channel) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> safe_call(pid, {:attach, channel})
      {:error, :not_found} = error -> error
    end
  end

  @spec detach(Types.id(), pid()) :: {:ok, t()} | {:error, :not_found | :not_attached}
  def detach(driver_id, channel) when is_pid(channel) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> safe_call(pid, {:detach, channel})
      {:error, :not_found} = error -> error
    end
  end

  @spec claim(Types.id()) :: {:ok, t()} | {:error, :not_found | :unavailable}
  def claim(driver_id) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> safe_call(pid, :claim)
      {:error, :not_found} = error -> error
    end
  end

  @spec release(Types.id()) :: :ok | {:error, :not_found}
  def release(driver_id) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> GenServer.cast(pid, :release)
      {:error, :not_found} = error -> error
    end
  end

  @spec fresh?(t()) :: boolean()
  def fresh?(%__MODULE__{
        located_at: %DateTime{} = located_at,
        on_duty_since: %DateTime{} = since
      }) do
    not DateTime.before?(located_at, since)
  end

  def fresh?(%__MODULE__{}), do: false

  @spec idle?(t(), DateTime.t()) :: boolean()
  def idle?(
        %__MODULE__{status: :offline, channel: nil, synced_at: %DateTime{} = synced_at},
        cutoff
      ) do
    DateTime.before?(synced_at, cutoff)
  end

  def idle?(_state, _cutoff), do: false

  @spec stop_if_idle(Types.id(), DateTime.t()) :: :stopped | :active | {:error, :not_found}
  def stop_if_idle(driver_id, cutoff) do
    case DriverRegistry.whereis(driver_id) do
      {:ok, pid} -> safe_stop_if_idle(pid, cutoff)
      {:error, :not_found} = error -> error
    end
  end

  @impl GenServer
  @spec init(Types.id()) :: {:ok, t(), {:continue, :rehydrate}}
  def init(driver_id) do
    Process.flag(:trap_exit, true)

    {:ok, %__MODULE__{driver_id: driver_id}, {:continue, :rehydrate}}
  end

  @impl GenServer
  @spec handle_continue(:rehydrate, t()) ::
          {:noreply, t()} | {:stop, {:shutdown, :unknown_driver}, t()}
  def handle_continue(:rehydrate, %__MODULE__{driver_id: driver_id} = state) do
    case StateCache.fetch(driver_id) do
      {:ok, cached} ->
        {:noreply, commit(watch_channel(cached))}

      {:error, :not_found} ->
        case Snapshot.fetch(driver_id) do
          {:ok, snapshot} -> {:noreply, commit(snapshot, apply_snapshot(state, snapshot))}
          {:error, :not_found} -> {:stop, {:shutdown, :unknown_driver}, state}
        end
    end
  end

  @impl GenServer
  @spec handle_call(
          :fetch
          | :claim
          | {:set_duty, Driver.status()}
          | {:attach, pid()}
          | {:detach, pid()}
          | {:stop_if_idle, DateTime.t()},
          GenServer.from(),
          t()
        ) ::
          {:reply, {:ok, t()} | {:error, :unavailable | :no_active_job | :not_attached} | :active,
           t()}
          | {:stop, {:shutdown, :idle}, :stopped, t()}
  def handle_call(:fetch, _from, state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call(:claim, _from, %__MODULE__{status: :online} = state)
      when state.active_orders_count < state.max_orders do
    count = state.active_orders_count + 1

    claimed =
      commit(state, %{state | active_orders_count: count, status: loaded(count, state.max_orders)})

    {:reply, {:ok, claimed}, claimed}
  end

  def handle_call(:claim, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:set_duty, :offline}, _from, state) do
    reply(commit(state, %{state | status: :offline, on_duty_since: nil}))
  end

  def handle_call({:set_duty, :online}, _from, state) do
    reply(
      commit(state, %{
        state
        | status: loaded(state.active_orders_count, state.max_orders),
          on_duty_since: state.on_duty_since || DateTime.utc_now()
      })
    )
  end

  def handle_call({:set_duty, :busy}, _from, %__MODULE__{active_orders_count: 0} = state) do
    {:reply, {:error, :no_active_job}, state}
  end

  def handle_call({:set_duty, :busy}, _from, state) do
    reply(
      commit(state, %{
        state
        | status: :busy,
          on_duty_since: state.on_duty_since || DateTime.utc_now()
      })
    )
  end

  def handle_call({:attach, channel}, _from, %__MODULE__{channel: channel} = state) do
    {:reply, {:ok, state}, state}
  end

  def handle_call({:attach, channel}, _from, state) do
    :ok = forget_channel(state.channel_monitor)
    reply(commit(%{state | channel: channel, channel_monitor: Process.monitor(channel)}))
  end

  def handle_call({:detach, channel}, _from, %__MODULE__{channel: channel} = state) do
    :ok = forget_channel(state.channel_monitor)
    reply(commit(state, off_duty(state)))
  end

  def handle_call({:detach, _other}, _from, state) do
    {:reply, {:error, :not_attached}, state}
  end

  def handle_call({:stop_if_idle, cutoff}, _from, state) do
    idle_reply(idle?(state, cutoff), state)
  end

  @impl GenServer
  @spec handle_cast({:update_location, Telemetry.t()} | :release, t()) :: {:noreply, t()}
  def handle_cast({:update_location, telemetry}, state) do
    {:noreply, apply_position(newer?(telemetry.recorded_at, state.recorded_at), telemetry, state)}
  end

  def handle_cast(:release, state) do
    count = max(0, state.active_orders_count - 1)

    {:noreply,
     commit(state, %{
       state
       | active_orders_count: count,
         status: released(state.status, count, state.max_orders)
     })}
  end

  @impl GenServer
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({:DOWN, monitor, :process, _channel, _reason}, %__MODULE__{} = state)
      when monitor == state.channel_monitor do
    {:noreply, commit(state, off_duty(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  @spec terminate(term(), t()) :: :ok
  def terminate(:normal, %__MODULE__{driver_id: driver_id}), do: evict(driver_id)
  def terminate(:shutdown, %__MODULE__{driver_id: driver_id}), do: evict(driver_id)

  def terminate({:shutdown, _reason}, %__MODULE__{driver_id: driver_id}), do: evict(driver_id)

  def terminate(_crash_reason, _state), do: :ok

  @spec evict(Types.id()) :: :ok
  defp evict(driver_id) do
    :ok = StateCache.delete(driver_id)
    Events.broadcast(driver_id, {:driver_stopped, driver_id})
  end

  @spec commit(t()) :: t()
  defp commit(%__MODULE__{} = state) do
    stamped = %{state | synced_at: DateTime.utc_now()}
    :ok = StateCache.put(state.driver_id, stamped)
    :ok = Events.broadcast(stamped.driver_id, {:driver_updated, stamped})
    stamped
  end

  @spec commit(t() | Snapshot.t(), t()) :: t()
  defp commit(%{status: status}, %__MODULE__{status: status} = next), do: commit(next)

  defp commit(_previous, %__MODULE__{} = next) do
    _ = StatusRecord.write(next.driver_id, next.status)
    commit(next)
  end

  @spec reply(t()) :: {:reply, {:ok, t()}, t()}
  defp reply(state), do: {:reply, {:ok, state}, state}

  @spec loaded(non_neg_integer(), pos_integer()) :: :online | :busy
  defp loaded(count, max_orders) when count >= max_orders, do: :busy
  defp loaded(_count, _max_orders), do: :online

  @spec released(Driver.status(), non_neg_integer(), pos_integer()) :: Driver.status()
  defp released(:busy, count, max_orders) when count < max_orders, do: :online
  defp released(status, _count, _max_orders), do: status

  @spec off_duty(t()) :: t()
  defp off_duty(state) do
    %{state | status: :offline, on_duty_since: nil, channel: nil, channel_monitor: nil}
  end

  @spec forget_channel(reference() | nil) :: :ok
  defp forget_channel(nil), do: :ok

  defp forget_channel(monitor) do
    true = Process.demonitor(monitor, [:flush])
    :ok
  end

  @spec watch_channel(t()) :: t()
  defp watch_channel(%__MODULE__{channel: nil} = state), do: state

  defp watch_channel(%__MODULE__{channel: channel} = state) do
    %{state | channel_monitor: Process.monitor(channel)}
  end

  @spec newer?(DateTime.t(), DateTime.t() | nil) :: boolean()
  defp newer?(_incoming, nil), do: true
  defp newer?(incoming, current), do: not DateTime.before?(incoming, current)

  @spec apply_position(boolean(), Telemetry.t(), t()) :: t()
  defp apply_position(false, _telemetry, state), do: state

  defp apply_position(true, telemetry, state) do
    commit(%{
      state
      | coordinates: {telemetry.latitude, telemetry.longitude},
        speed_kmh: Map.get(telemetry, :speed_kmh),
        bearing_deg: Map.get(telemetry, :bearing_deg),
        recorded_at: telemetry.recorded_at,
        located_at: DateTime.utc_now()
    })
  end

  @spec apply_snapshot(t(), Snapshot.t()) :: t()
  defp apply_snapshot(%__MODULE__{} = state, snapshot) do
    %{
      state
      | status: :offline,
        capacity_kg: snapshot.capacity_kg,
        active_orders_count: snapshot.active_jobs,
        coordinates: snapshot.coordinates,
        speed_kmh: snapshot.speed_kmh,
        bearing_deg: snapshot.bearing_deg,
        recorded_at: snapshot.recorded_at
    }
  end

  @spec idle_reply(boolean(), t()) ::
          {:reply, :active, t()} | {:stop, {:shutdown, :idle}, :stopped, t()}
  defp idle_reply(false, state), do: {:reply, :active, state}
  defp idle_reply(true, state), do: {:stop, {:shutdown, :idle}, :stopped, state}

  @spec safe_call(pid(), term()) :: {:ok, t()} | {:error, atom()}
  defp safe_call(pid, message) do
    GenServer.call(pid, message)
  catch
    :exit, _reason -> {:error, :not_found}
  end

  @spec safe_stop_if_idle(pid(), DateTime.t()) :: :stopped | :active | {:error, :not_found}
  defp safe_stop_if_idle(pid, cutoff) do
    GenServer.call(pid, {:stop_if_idle, cutoff})
  catch
    :exit, _reason -> {:error, :not_found}
  end
end
