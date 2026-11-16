defmodule KinetixMatching.FakePositionPublisher do
  @moduledoc """
  In-memory test double capturing live courier position broadcasts for assertions.
  """

  @behaviour KinetixMatching.Tracking.PositionPublisher

  use Agent

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> [] end, name: __MODULE__) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> :ok
    end
  end

  @impl KinetixMatching.Tracking.PositionPublisher
  @spec publish_position(String.t(), map()) :: :ok
  def publish_position(order_number, envelope) do
    :ok = start()
    Agent.update(__MODULE__, fn entries -> [{order_number, envelope} | entries] end)
  end

  @spec published() :: [{String.t(), map()}]
  def published do
    :ok = start()
    Agent.get(__MODULE__, &Enum.reverse(&1))
  end

  @spec reset() :: :ok
  def reset do
    :ok = start()
    Agent.update(__MODULE__, fn _ -> [] end)
  end
end
