defmodule FleetPulse.Dispatch.DeliveryReporter do
  @moduledoc """
  Reports the deliveries order has not recorded yet: at once when `kick/0` says a delivery was just
  made, and every minute after, backing off to an hour. The courier's `delivered` reply never waits for
  order.

  Disabled in `:test`; tests drive `report_now/0`.
  """

  use GenServer

  require Logger

  alias FleetPulse.Dispatch.DeliveryReport

  @default_interval_ms 60_000
  @default_batch_size 20

  @type t :: %__MODULE__{interval_ms: pos_integer(), batch_size: pos_integer()}

  @enforce_keys [:interval_ms, :batch_size]
  defstruct [:interval_ms, :batch_size]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @spec report_now() :: {:ok, non_neg_integer()}
  def report_now, do: GenServer.call(__MODULE__, :report_now, :infinity)

  @spec kick() :: :ok
  def kick, do: GenServer.cast(__MODULE__, :report)

  @impl GenServer
  @spec init(keyword()) :: {:ok, t()}
  def init(_opts) do
    config = Application.get_env(:fleet_pulse, __MODULE__, [])

    state = %__MODULE__{
      interval_ms: positive(Keyword.get(config, :interval_ms), @default_interval_ms),
      batch_size: positive(Keyword.get(config, :batch_size), @default_batch_size)
    }

    _timer = schedule(state)
    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(:report_now, GenServer.from(), t()) ::
          {:reply, {:ok, non_neg_integer()}, t()}
  def handle_call(:report_now, _from, state) do
    {:reply, {:ok, report(state)}, state}
  end

  @impl GenServer
  @spec handle_cast(:report, t()) :: {:noreply, t()}
  def handle_cast(:report, state) do
    _reported = report(state)
    {:noreply, state}
  end

  @impl GenServer
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:report, state) do
    _reported = report(state)
    _timer = schedule(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} ignored message: #{inspect(message)}")
    {:noreply, state}
  end

  @spec report(t()) :: non_neg_integer()
  defp report(%__MODULE__{batch_size: batch_size}) do
    batch_size
    |> DeliveryReport.due()
    |> Enum.map(&DeliveryReport.attempt/1)
    |> Enum.count(&match?({:reported, _order}, &1))
  end

  @spec schedule(t()) :: reference()
  defp schedule(%__MODULE__{interval_ms: interval_ms}) do
    Process.send_after(self(), :report, interval_ms)
  end

  @spec positive(term(), pos_integer()) :: pos_integer()
  defp positive(value, _default) when is_integer(value) and value > 0, do: value
  defp positive(_value, default), do: default
end
