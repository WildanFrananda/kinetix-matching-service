defmodule FleetPulse.FakeStorage do
  @moduledoc """
  The proof-of-delivery bucket, as the suite needs it: an object holds the bytes put through its upload
  address and the checksum the store would have stored for them, an object can be put there without
  one, and the bucket can be made unreachable.
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
  def uploaded(url, bytes), do: store(url, {:sha256, :crypto.hash(:sha256, bytes)}, bytes)

  @spec uploaded_without_checksum(String.t()) :: :ok
  def uploaded_without_checksum(url), do: store(url, :no_checksum, <<0xFF, 0xD8, 0xFF, 0xE0>>)

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
      %{objects: %{^key => object}} -> {:ok, object.checksum}
      %{objects: _others} -> {:ok, :absent}
    end)
  end

  @impl FleetPulse.Storage
  def leading_bytes(key, count) do
    Agent.get(@agent, fn
      %{reachable: false} ->
        {:error, :unavailable}

      %{objects: %{^key => object}} ->
        {:ok, binary_part(object.bytes, 0, min(count, byte_size(object.bytes)))}

      %{objects: _others} ->
        {:ok, :absent}
    end)
  end

  @spec store(String.t(), FleetPulse.Storage.checksum(), binary()) :: :ok
  defp store(url, checksum, bytes) do
    {:ok, key} = key_of(url)
    object = %{checksum: checksum, bytes: bytes}
    Agent.update(@agent, &%{&1 | objects: Map.put(&1.objects, key, object)})
  end

  @spec empty() :: %{objects: %{}, reachable: true}
  defp empty, do: %{objects: %{}, reachable: true}
end
