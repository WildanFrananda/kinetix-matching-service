defmodule KinetixMatching.Tracking.StateCache do
  @moduledoc """
  ETS-backed cache of each courier's last known live state.
  """

  use GenServer

  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Types

  @table __MODULE__

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @spec put(Types.principal_id(), DriverState.t()) :: :ok
  def put(courier_principal_id, state) do
    _ = :ets.insert(@table, {courier_principal_id, state})
    :ok
  end

  @spec fetch(Types.principal_id()) :: {:ok, DriverState.t()} | {:error, :not_found}
  def fetch(courier_principal_id) do
    case :ets.lookup(@table, courier_principal_id) do
      [{^courier_principal_id, state}] -> {:ok, state}
      [] -> {:error, :not_found}
    end
  end

  @spec all() :: [DriverState.t()]
  def all do
    @table
    |> :ets.tab2list()
    |> Enum.map(fn {_courier_principal_id, %DriverState{} = state} -> state end)
  end

  @spec with_coordinates() :: [DriverState.t()]
  def with_coordinates do
    Enum.reject(all(), &is_nil(&1.coordinates))
  end

  @spec delete(Types.principal_id()) :: :ok
  def delete(courier_principal_id) do
    _ = :ets.delete(@table, courier_principal_id)
    :ok
  end

  @spec size() :: non_neg_integer()
  def size do
    case :ets.info(@table, :size) do
      :undefined -> 0
      size -> size
    end
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, :ready}
  def init(_opts) do
    _table =
      :ets.new(@table, [
        :named_table,
        :public,
        :set,
        read_concurrency: true,
        write_concurrency: true
      ])

    {:ok, :ready}
  end
end
