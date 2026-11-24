defmodule KinetixMatching.Tracking.DriverSupervisor do
  @moduledoc """
  DynamicSupervisor that starts one `DriverState` process per courier principal, on demand.
  """

  use DynamicSupervisor

  alias KinetixMatching.Tracking.DriverRegistry
  alias KinetixMatching.Tracking.DriverState
  alias KinetixMatching.Types

  @spec start_link(keyword()) :: Supervisor.on_start()
  def start_link(opts) do
    DynamicSupervisor.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl DynamicSupervisor
  @spec init(keyword()) :: {:ok, DynamicSupervisor.sup_flags()}
  def init(_opts) do
    DynamicSupervisor.init(strategy: :one_for_one)
  end

  @spec start_driver(Types.principal_id()) :: {:ok, pid()} | {:error, Types.reason()}
  def start_driver(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    case DynamicSupervisor.start_child(__MODULE__, {DriverState, courier_principal_id}) do
      {:ok, pid} -> {:ok, pid}
      {:error, {:already_started, pid}} -> {:ok, pid}
      {:error, reason} -> {:error, {:start_failed, reason}}
    end
  end

  @spec stop_driver(Types.principal_id()) :: :ok | {:error, :not_found}
  def stop_driver(courier_principal_id) do
    case DriverRegistry.whereis(courier_principal_id) do
      {:ok, pid} -> DynamicSupervisor.terminate_child(__MODULE__, pid)
      {:error, :not_found} = error -> error
    end
  end
end
