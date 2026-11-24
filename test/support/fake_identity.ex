defmodule KinetixMatching.FakeIdentity do
  @moduledoc """
  Test double for `KinetixMatching.Clients.Identity` storing registered and approved courier standings in memory.
  """

  @behaviour KinetixMatching.Clients.Identity

  alias KinetixMatching.Clients.Identity

  @agent __MODULE__

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> %{couriers: %{}, unreachable: false} end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset do
    ensure_started()
    Agent.update(@agent, fn _state -> %{couriers: %{}, unreachable: false} end)
  end

  @spec unreachable(boolean()) :: :ok
  def unreachable(flag \\ true) when is_boolean(flag) do
    ensure_started()
    Agent.update(@agent, &%{&1 | unreachable: flag})
  end

  @spec put_courier(String.t(), map()) :: Identity.standing()
  def put_courier(courier_principal_id, attrs \\ %{})
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    ensure_started()

    standing = %{
      courier_principal_id: courier_principal_id,
      vehicle_plate: Map.get(attrs, :vehicle_plate, "B 1000 KNX"),
      capacity_kg: Map.get(attrs, :capacity_kg, 100),
      may_drive: Map.get(attrs, :may_drive, true)
    }

    Agent.update(@agent, fn state ->
      put_in(state, [:couriers, courier_principal_id], standing)
    end)

    standing
  end

  @impl KinetixMatching.Clients.Identity
  @spec courier_standing(String.t()) :: {:ok, Identity.standing()} | {:error, Identity.error()}
  def courier_standing(courier_principal_id)
      when is_binary(courier_principal_id) and courier_principal_id != "" do
    ensure_started()

    Agent.get(@agent, fn
      %{unreachable: true} ->
        {:error, :unavailable}

      %{couriers: couriers} ->
        case Map.fetch(couriers, courier_principal_id) do
          {:ok, standing} -> {:ok, standing}
          :error -> {:error, :not_found}
        end
    end)
  end

  def courier_standing(_courier_principal_id), do: {:error, :not_found}

  @spec ensure_started() :: :ok
  defp ensure_started do
    case Process.whereis(@agent) do
      nil -> start()
      _pid -> :ok
    end
  end
end
