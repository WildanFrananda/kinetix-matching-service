defmodule FleetPulse.Tracking.PingRetention do
  @moduledoc """
  Periodically prunes location pings past the retention window.

  `location_pings` is append-only and unbounded (~GBs/day at scale). This
  worker keeps the audit trail bounded by deleting rows whose server-side
  `inserted_at` is older than the window. It uses `inserted_at` (when we stored
  the row), NOT `recorded_at` (the device clock) — a skewed device clock must
  not make a fresh row look ancient or an old one look current.

  Disabled in `:test`; tests drive `prune_now/0`.
  """

  use GenServer

  import Ecto.Query

  require Logger

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.LocationPing

  @default_interval_ms 86_400_000
  @default_retention_ms 2_592_000_000

  @typedoc "Retention worker state."
  @type t :: %__MODULE__{interval_ms: pos_integer(), retention_ms: pos_integer()}

  @enforce_keys [:interval_ms, :retention_ms]
  defstruct [:interval_ms, :retention_ms]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts), do: GenServer.start_link(__MODULE__, opts, name: __MODULE__)

  @doc "Prunes immediately; returns the number of rows deleted."
  @spec prune_now() :: {:ok, non_neg_integer()}
  def prune_now, do: GenServer.call(__MODULE__, :prune_now, :infinity)

  @impl GenServer
  @spec init(keyword()) :: {:ok, t()}
  def init(_opts) do
    config = Application.get_env(:fleet_pulse, __MODULE__, [])

    state = %__MODULE__{
      interval_ms: interval_ms(Keyword.get(config, :interval_ms)),
      retention_ms: retention_ms(Keyword.get(config, :retention_ms))
    }

    _timer = schedule(state)
    {:ok, state}
  end

  @impl GenServer
  @spec handle_call(:prune_now, GenServer.from(), t()) :: {:reply, {:ok, non_neg_integer()}, t()}
  def handle_call(:prune_now, _from, state) do
    {:reply, {:ok, prune(state)}, state}
  end

  @impl GenServer
  @spec handle_info(term(), t()) :: {:noreply, t()}
  def handle_info(:prune, state) do
    _deleted = prune(state)
    _timer = schedule(state)
    {:noreply, state}
  end

  def handle_info(message, state) do
    Logger.debug("#{inspect(__MODULE__)} ignored message: #{inspect(message)}")
    {:noreply, state}
  end

  @spec prune(t()) :: non_neg_integer()
  defp prune(%__MODULE__{retention_ms: retention_ms}) do
    cutoff = DateTime.add(DateTime.utc_now(), -retention_ms, :millisecond)

    {deleted, _} =
      LocationPing
      |> where([p], p.inserted_at < ^cutoff)
      |> Repo.delete_all()

    :ok = log_pruned(deleted)
    deleted
  end

  @spec log_pruned(non_neg_integer()) :: :ok
  defp log_pruned(0), do: :ok
  defp log_pruned(n), do: Logger.info("#{inspect(__MODULE__)} pruned #{n} old ping(s)")

  @spec schedule(t()) :: reference()
  defp schedule(%__MODULE__{interval_ms: interval_ms}) do
    Process.send_after(self(), :prune, interval_ms)
  end

  @spec interval_ms(term()) :: pos_integer()
  defp interval_ms(value) when is_integer(value) and value > 0, do: value
  defp interval_ms(_value), do: @default_interval_ms

  @spec retention_ms(term()) :: pos_integer()
  defp retention_ms(value) when is_integer(value) and value > 0, do: value
  defp retention_ms(_value), do: @default_retention_ms
end
