defmodule FleetPulse.FakeStorage do
  @moduledoc """
  The proof-of-delivery bucket, as the suite needs it: an object holds the checksum the store would have
  stored for the bytes put through its upload address, an object can be put there without one, and
  the bucket can be made unreachable.
  """

  @behaviour FleetPulse.Storage

  @agent __MODULE__
  @base "https://storage.kinetix.test/kinetix-pod/"

  @spec start() :: :ok
  def start do
    case Agent.start_link(fn -> empty() end, name: @agent) do
      {:ok, _pid} -> :ok
      {:error, {:already_started, _pid}} -> reset()
    end
  end

  @spec reset() :: :ok
  def reset, do: Agent.update(@agent, fn _ -> empty() end)

  @spec uploaded(String.t(), binary()) :: :ok
  def uploaded(url, bytes), do: store(url, {:sha256, :crypto.hash(:sha256, bytes)})

  @spec uploaded_without_checksum(String.t()) :: :ok
  def uploaded_without_checksum(url), do: store(url, :no_checksum)

  @spec unreachable() :: :ok
  def unreachable, do: Agent.update(@agent, &%{&1 | reachable: false})

  @impl FleetPulse.Storage
  def upload(key, sha256) do
    %{
      url: @base <> key <> "?X-Amz-Signature=upload",
      headers: %{"if-none-match" => "*", "x-amz-checksum-sha256" => Base.encode64(sha256)}
    }
  end

  @impl FleetPulse.Storage
  def read_url(key), do: @base <> key <> "?X-Amz-Signature=read"

  @impl FleetPulse.Storage
  def object_url(key), do: @base <> key

  @impl FleetPulse.Storage
  def key_of(@base <> key), do: {:ok, key}
  def key_of(_url), do: :error

  @impl FleetPulse.Storage
  def checksum(key) do
    Agent.get(@agent, fn
      %{reachable: false} -> {:error, :unavailable}
      %{objects: objects} -> {:ok, Map.get(objects, key, :absent)}
    end)
  end

  @spec store(String.t(), FleetPulse.Storage.checksum()) :: :ok
  defp store(url, checksum) do
    {:ok, key} = key_of(url)
    Agent.update(@agent, &%{&1 | objects: Map.put(&1.objects, key, checksum)})
  end

  @spec empty() :: %{objects: %{}, reachable: true}
  defp empty, do: %{objects: %{}, reachable: true}
end
