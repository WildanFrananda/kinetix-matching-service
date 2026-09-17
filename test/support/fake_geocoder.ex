defmodule FleetPulse.FakeGeocoder do
  @moduledoc """
  A geocoder the tests control, standing in for the public one.
  """

  @behaviour FleetPulse.Geocoding.Provider

  @agent __MODULE__

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> %{answers: %{}, default: {:error, :not_found}, calls: []} end,
           name: @agent
         ) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset do
    Agent.update(@agent, fn _state ->
      %{answers: %{}, default: {:error, :not_found}, calls: []}
    end)
  end

  @spec answer(String.t(), {:ok, map()} | {:error, atom()}) :: :ok
  def answer(query, result) do
    Agent.update(@agent, fn state ->
      %{state | answers: Map.put(state.answers, query, result)}
    end)
  end

  @spec always({:ok, map()} | {:error, atom()}) :: :ok
  def always(result), do: Agent.update(@agent, &%{&1 | default: result})

  @spec calls() :: [String.t()]
  def calls, do: Agent.get(@agent, & &1.calls) |> Enum.reverse()

  @spec call_count() :: non_neg_integer()
  def call_count, do: length(calls())

  @impl FleetPulse.Geocoding.Provider
  def lookup(query) do
    Agent.get_and_update(@agent, fn state ->
      result = Map.get(state.answers, query, state.default)
      {result, %{state | calls: [query | state.calls]}}
    end)
  end
end
