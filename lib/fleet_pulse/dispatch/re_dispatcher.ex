defmodule FleetPulse.Dispatch.ReDispatcher do
  @moduledoc """
  Re-attempts pending orders when drivers become available (PRD 9.1).

  An order created with no eligible driver in range would otherwise sit
  `pending` forever. This process reacts — no polling — to the same PubSub
  broadcasts the dashboard already consumes: a driver going `online`, or a new
  pending order. On either signal it schedules a single debounced sweep that
  runs `Dispatch.assign_order/2` over the current pending orders.
  """

  use GenServer

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverState

  @default_debounce_ms 1_000

  @typedoc "Re-dispatcher state."
  @type t :: %__MODULE__{debounce_ms: pos_integer(), scheduled: boolean()}

  @enforce_keys [:debounce_ms]
  defstruct [:debounce_ms, scheduled: false]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc """
  Runs a sweep immediately, returning how many pending orders were assigned.
  Used in tests and for a manual kick.
  """
  @spec sweep_now() :: {:ok, non_neg_integer()}
  def sweep_now, do: GenServer.call(__MODULE__, :sweep_now, :infinity)

  @impl GenServer
  @spec init(keyword()) :: {:ok, t()}
  def init(_opts) do
    :ok = Tracking.subscribe_fleet()
    :ok = Dispatch.subscribe_orders()

    config = Application.get_env(:fleet_pulse, __MODULE__, [])
    {:ok, %__MODULE__{debounce_ms: debounce_ms(Keyword.get(config, :debounce_ms))}}
  end

  @impl GenServer
  @spec handle_call(:sweep_now, GenServer.from(), t()) :: {:reply, {:ok, non_neg_integer()}, t()}
  def handle_call(:sweep_now, _from, state) do
    {:reply, {:ok, sweep()}, state}
  end

  @impl GenServer
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(
        {:driver_updated, %DriverState{status: :online, coordinates: {_lat, _lng}}},
        state
      ) do
    {:noreply, schedule(state)}
  end

  def handle_info({:order_changed, %Order{status: :pending}}, state) do
    {:noreply, schedule_sweep(state)}
  end

  def handle_info(:sweep, state) do
    _count = sweep()
    {:noreply, %{state | scheduled: false}}
  end

  def handle_info(_message, state), do: {:noreply, state}

  @spec schedule_sweep(t()) :: t()
  defp schedule_sweep(%__MODULE__{scheduled: true} = state), do: state

  defp schedule_sweep(%__MODULE__{scheduled: false} = state) do
    _timer = Process.send_after(self(), :sweep, state.debounce_ms)
    %{state | scheduled: true}
  end

  @spec schedule(t()) :: t()
  defp schedule(%__MODULE__{scheduled: true} = state), do: state

  defp schedule(%__MODULE__{scheduled: false} = state) do
    _timer = Process.send_after(self(), :sweep, state.debounce_ms)
    %{state | scheduled: true}
  end

  @spec sweep() :: non_neg_integer()
  defp sweep do
    Dispatch.list_pending_orders()
    |> Enum.map(&Dispatch.assign_order(&1.id))
    |> Enum.count(&match?({:ok, _order}, &1))
  end

  @spec debounce_ms(term()) :: pos_integer()
  defp debounce_ms(value) when is_integer(value) and value > 0, do: value
  defp debounce_ms(_value), do: @default_debounce_ms
end
