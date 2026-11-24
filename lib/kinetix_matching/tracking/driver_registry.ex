defmodule KinetixMatching.Tracking.DriverRegistry do
  @moduledoc """
  Typed wrapper around `Registry` for the courier_principal_id -> pid mapping.
  """

  alias KinetixMatching.Types

  @registry __MODULE__

  @typedoc "The `:via` name a GenServer uses to register itself."
  @type via_name :: {:via, Registry, {module(), Types.principal_id()}}

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(_opts) do
    Supervisor.child_spec({Registry, keys: :unique, name: @registry}, id: __MODULE__)
  end

  @spec via(Types.principal_id()) :: via_name()
  def via(courier_principal_id), do: {:via, Registry, {@registry, courier_principal_id}}

  @spec whereis(Types.principal_id()) :: {:ok, pid()} | {:error, :not_found}
  def whereis(courier_principal_id) do
    case Registry.lookup(@registry, courier_principal_id) do
      [{pid, _value}] -> {:ok, pid}
      [] -> {:error, :not_found}
    end
  end

  @spec count() :: non_neg_integer()
  def count, do: Registry.count(@registry)

  @spec driver_ids() :: [Types.principal_id()]
  def driver_ids do
    Registry.select(@registry, [{{:"$1", :_, :_}, [], [:"$1"]}])
  end
end
