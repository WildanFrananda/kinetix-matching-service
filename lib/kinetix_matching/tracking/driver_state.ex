defmodule KinetixMatching.Tracking.DriverState do
  @moduledoc """
  GenServer process holding ONE courier's live state in memory (PRD 5.2).

  Keyed by `courier_principal_id` (`String.t()`). Holds the courier's vehicle plate and
  capacity retrieved from `kinetix-identity-service` (`GetCourierStanding`) in memory
  for the duration of the session.
  """

  use GenServer, restart: :transient

  alias KinetixMatching.Tracking.DriverRegistry
  alias KinetixMatching.Tracking.Events
  alias KinetixMatching.Tracking.Snapshot
  alias KinetixMatching.Tracking.StateCache
  alias KinetixMatching.Tracking.Telemetry
  alias KinetixMatching.Types

  @default_max_orders 1
  @statuses [:online, :busy, :offline]

  @typedoc """
  A courier's live state.
  """
  @type t :: %__MODULE__{
          courier_principal_id: Types.principal_id(),
          vehicle_plate: String.t(),
          capacity_kg: non_neg_integer(),
          active_orders_count: non_neg_integer(),
          max_orders: pos_integer(),
          status: Types.driver_status(),
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

  @type duty_error ::
          :not_found
          | :invalid_status
          | :no_active_job
          | :pending_approval
          | :identity_unavailable

  @enforce_keys [:courier_principal_id]
  defstruct [
    :courier_principal_id,
    :coordinates,
    :speed_kmh,
    :bearing_deg,
    :recorded_at,
    :synced_at,
    :located_at,
    :on_duty_since,
    :channel,
    :channel_monitor,
    vehicle_plate: "",
    capacity_kg: 0,
    active_orders_count: 0,
    max_orders: @default_max_orders,
    status: :offline
  ]

  @spec statuses() :: [Types.driver_status(), ...]
  def statuses, do: @statuses

  @spec start_link(Types.principal_id()) :: GenServer.on_start()
  def start_link(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    GenServer.start_link(
      __MODULE__,
      courier_principal_id,
      name: DriverRegistry.via(courier_principal_id)
    )
  end

  @spec fetch(Types.principal_id()) :: {:ok, t()} | {:error, :not_found}
  def fetch(courier_principal_id) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_call(pid, :fetch)
      {:error, :not_found} = error -> error
    end
  end

  @spec update_location(Types.principal_id(), Telemetry.t()) ::
          :ok | {:error, :not_found | :invalid_telemetry}
  def update_location(courier_principal_id, telemetry) do
    with {:ok, telemetry} <- Telemetry.normalise(telemetry),
         :ok <- Telemetry.not_ahead_of(telemetry, DateTime.utc_now()),
         {:ok, pid} <- DriverRegistry.whereis(courier_principal_id) do
      GenServer.cast(pid, {:update_location, telemetry})
    end
  end

  @spec set_duty(Types.principal_id(), Types.driver_status()) ::
          {:ok, t()} | {:error, duty_error()}
  def set_duty(courier_principal_id, status) do
    with true <- status in @statuses,
         {:ok, pid} <- DriverRegistry.whereis(courier_principal_id) do
      safe_call(pid, {:set_duty, status})
    else
      false -> {:error, :invalid_status}
      {:error, :not_found} = error -> error
    end
  end

  @spec refresh_standing(Types.principal_id(), String.t(), non_neg_integer()) ::
          {:ok, t()} | {:error, :not_found}
  def refresh_standing(courier_principal_id, vehicle_plate, capacity_kg) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_call(pid, {:refresh_standing, vehicle_plate, capacity_kg})
      {:error, :not_found} = error -> error
    end
  end

  @spec attach(Types.principal_id(), pid()) :: {:ok, t()} | {:error, :not_found}
  def attach(courier_principal_id, channel) when is_pid(channel) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_call(pid, {:attach, channel})
      {:error, :not_found} = error -> error
    end
  end

  @spec detach(Types.principal_id(), pid()) :: {:ok, t()} | {:error, :not_found | :not_attached}
  def detach(courier_principal_id, channel) when is_pid(channel) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_call(pid, {:detach, channel})
      {:error, :not_found} = error -> error
    end
  end

  @spec claim(Types.principal_id()) :: {:ok, t()} | {:error, :not_found | :unavailable}
  def claim(courier_principal_id) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_call(pid, :claim)
      {:error, :not_found} = error -> error
    end
  end

  @spec release(Types.principal_id()) :: :ok | {:error, :not_found}
  def release(courier_principal_id) do
    case DriverRegistry.whereis(courier_principal_id) do
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

  @spec stop_if_idle(Types.principal_id(), DateTime.t()) ::
          :stopped | :active | {:error, :not_found}
  def stop_if_idle(courier_principal_id, cutoff) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> safe_stop_if_idle(pid, cutoff)
      {:error, :not_found} = error -> error
    end
  end

  @impl GenServer
  @spec init(Types.principal_id()) :: {:ok, t(), {:continue, :rehydrate}}
  def init(courier_principal_id) do
    Process.flag(:trap_exit, true)

    {:ok, %__MODULE__{courier_principal_id: courier_principal_id}, {:continue, :rehydrate}}
  end

  @impl GenServer
  @spec handle_continue(:rehydrate, t()) ::
          {:noreply, t()} | {:stop, {:shutdown, :unknown_driver}, t()}
  def handle_continue(
        :rehydrate,
        %__MODULE__{courier_principal_id: courier_principal_id} = state
      ) do
    case StateCache.fetch(courier_principal_id) do
      {:ok, cached} ->
        {:noreply, commit(watch_channel(cached))}

      {:error, :not_found} ->
        case Snapshot.fetch(courier_principal_id) do
          {:ok, snapshot} ->
            {:noreply, commit(apply_snapshot(state, snapshot))}

          {:error, _reason} ->
            {:stop, {:shutdown, :unknown_driver}, state}
        end
    end
  end

  @impl GenServer
  @spec handle_call(
          :fetch
          | :claim
          | {:set_duty, Types.driver_status()}
          | {:refresh_standing, String.t(), non_neg_integer()}
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
      commit(%{state | active_orders_count: count, status: loaded(count, state.max_orders)})

    {:reply, {:ok, claimed}, claimed}
  end

  def handle_call(:claim, _from, state) do
    {:reply, {:error, :unavailable}, state}
  end

  def handle_call({:set_duty, :offline}, _from, state) do
    reply(commit(%{state | status: :offline, on_duty_since: nil}))
  end

  def handle_call({:set_duty, :online}, _from, state) do
    reply(
      commit(%{
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
      commit(%{
        state
        | status: :busy,
          on_duty_since: state.on_duty_since || DateTime.utc_now()
      })
    )
  end

  def handle_call({:refresh_standing, vehicle_plate, capacity_kg}, _from, state) do
    reply(commit(%{state | vehicle_plate: vehicle_plate, capacity_kg: capacity_kg}))
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
    reply(commit(off_duty(state)))
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
     commit(%{
       state
       | active_orders_count: count,
         status: released(state.status, count, state.max_orders)
     })}
  end

  @impl GenServer
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info({:DOWN, monitor, :process, _channel, _reason}, %__MODULE__{} = state)
      when monitor == state.channel_monitor do
    {:noreply, commit(off_duty(state))}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @impl GenServer
  @spec terminate(term(), t()) :: :ok
  def terminate(:normal, %__MODULE__{courier_principal_id: courier_principal_id}),
    do: evict(courier_principal_id)

  def terminate(:shutdown, %__MODULE__{courier_principal_id: courier_principal_id}),
    do: evict(courier_principal_id)

  def terminate({:shutdown, _reason}, %__MODULE__{courier_principal_id: courier_principal_id}),
    do: evict(courier_principal_id)

  def terminate(_crash_reason, _state), do: :ok

  @spec evict(Types.principal_id()) :: :ok
  defp evict(courier_principal_id) do
    :ok = StateCache.delete(courier_principal_id)
    Events.broadcast(courier_principal_id, {:driver_stopped, courier_principal_id})
  end

  @spec commit(t()) :: t()
  defp commit(%__MODULE__{} = state) do
    stamped = %{state | synced_at: DateTime.utc_now()}
    :ok = StateCache.put(state.courier_principal_id, stamped)
    :ok = Events.broadcast(stamped.courier_principal_id, {:driver_updated, stamped})
    stamped
  end

  @spec reply(t()) :: {:reply, {:ok, t()}, t()}
  defp reply(state), do: {:reply, {:ok, state}, state}

  @spec loaded(non_neg_integer(), pos_integer()) :: :online | :busy
  defp loaded(count, max_orders) when count >= max_orders, do: :busy
  defp loaded(_count, _max_orders), do: :online

  @spec released(Types.driver_status(), non_neg_integer(), pos_integer()) :: Types.driver_status()
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
        vehicle_plate: snapshot.vehicle_plate,
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
