defmodule FleetPulse.FakeOrder do
  @moduledoc """
  The order service, as the suite needs it: answering on command and counting what it was asked.
  """

  @behaviour FleetPulse.Clients.Order

  @agent __MODULE__

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> %{result: :ok, calls: [], times: []} end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset, do: Agent.update(@agent, fn _ -> %{result: :ok, calls: [], times: []} end)

  @spec always(:ok | {:error, atom()}) :: :ok
  def always(result), do: Agent.update(@agent, &%{&1 | result: result})

  @spec calls() :: [{String.t(), String.t()}]
  def calls, do: Agent.get(@agent, & &1.calls) |> Enum.reverse()

  @spec delivered_times() :: [DateTime.t()]
  def delivered_times, do: Agent.get(@agent, & &1.times) |> Enum.reverse()

  @impl FleetPulse.Clients.Order
  def delivered(order_number, driver_principal_id, delivered_at) do
    Agent.get_and_update(@agent, fn state ->
      {
        state.result,
        %{
          state
          | calls: [{order_number, driver_principal_id} | state.calls],
            times: [delivered_at | state.times]
        }
      }
    end)
  end
end
