defmodule FleetPulse.Storage do
  @moduledoc """
  Where proof-of-delivery photos are kept: a private bucket the phone uploads to through a
  presigned URL, and that matching checks before it accepts a delivery.
  """

  @callback upload_url(key :: String.t()) :: String.t()
  @callback read_url(key :: String.t()) :: String.t()
  @callback object_url(key :: String.t()) :: String.t()
  @callback key_of(url :: String.t()) :: {:ok, String.t()} | :error
  @callback exists?(key :: String.t()) :: {:ok, boolean()} | {:error, :unavailable}

  @spec impl() :: module()
  def impl do
    :fleet_pulse
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, FleetPulse.Storage.Minio)
  end

  @spec upload_url(String.t()) :: String.t()
  def upload_url(key), do: impl().upload_url(key)

  @spec read_url(String.t()) :: String.t()
  def read_url(key), do: impl().read_url(key)

  @spec object_url(String.t()) :: String.t()
  def object_url(key), do: impl().object_url(key)

  @spec key_of(String.t()) :: {:ok, String.t()} | :error
  def key_of(url), do: impl().key_of(url)

  @spec exists?(String.t()) :: {:ok, boolean()} | {:error, :unavailable}
  def exists?(key), do: impl().exists?(key)
end
