defmodule FleetPulse.FakeStorage do
  @moduledoc """
  The proof-of-delivery bucket, as the suite needs it: objects are present when the test says they
  were uploaded, and the bucket can be made unreachable.
  """

  @behaviour FleetPulse.Storage

  @agent __MODULE__
  @base "https://storage.kinetix.test/kinetix-pod/"

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> %{objects: MapSet.new(), reachable: true} end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset, do: Agent.update(@agent, fn _ -> %{objects: MapSet.new(), reachable: true} end)

  @spec uploaded(String.t()) :: :ok
  def uploaded(url) do
    {:ok, key} = key_of(url)
    Agent.update(@agent, &%{&1 | objects: MapSet.put(&1.objects, key)})
  end

  @spec unreachable() :: :ok
  def unreachable, do: Agent.update(@agent, &%{&1 | reachable: false})

  @impl FleetPulse.Storage
  def upload_url(key), do: @base <> key <> "?X-Amz-Signature=upload"

  @impl FleetPulse.Storage
  def read_url(key), do: @base <> key <> "?X-Amz-Signature=read"

  @impl FleetPulse.Storage
  def object_url(key), do: @base <> key

  @impl FleetPulse.Storage
  def key_of(@base <> key), do: {:ok, key}
  def key_of(_url), do: :error

  @impl FleetPulse.Storage
  def exists?(key) do
    Agent.get(@agent, fn
      %{reachable: false} -> {:error, :unavailable}
      %{objects: objects} -> {:ok, MapSet.member?(objects, key)}
    end)
  end
end
