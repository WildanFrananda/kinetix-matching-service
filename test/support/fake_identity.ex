defmodule FleetPulse.FakeIdentity do
  @moduledoc """
  Identity, as the suite needs it: answering on command and counting what it was asked.
  """

  @behaviour FleetPulse.Clients.Identity

  @agent __MODULE__

  @default {:error, :unavailable}

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> %{result: @default, calls: []} end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset, do: Agent.update(@agent, fn _ -> %{result: @default, calls: []} end)

  @spec always({:ok, FleetPulse.Clients.Identity.profile()} | {:error, atom()}) :: :ok
  def always(result), do: Agent.update(@agent, &%{&1 | result: result})

  @spec profile(String.t(), String.t()) :: :ok
  def profile(full_name, phone_number),
    do: always({:ok, %{full_name: full_name, phone_number: phone_number}})

  @spec calls() :: [String.t()]
  def calls, do: Agent.get(@agent, & &1.calls) |> Enum.reverse()

  @impl FleetPulse.Clients.Identity
  def profile_of(principal_id) do
    Agent.get_and_update(@agent, fn state ->
      {state.result, %{state | calls: [principal_id | state.calls]}}
    end)
  end
end
