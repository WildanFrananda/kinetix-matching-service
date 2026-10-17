defmodule FleetPulse.Storage do
  @moduledoc """
  Where proof-of-delivery photos are kept: a private bucket the phone uploads to through a
  presigned URL that admits only the bytes the courier hashed, and once, and that matching checks
  before it accepts a delivery.
  """

  @type upload :: %{url: String.t(), headers: %{String.t() => String.t()}}

  @type checksum :: {:sha256, <<_::256>>} | :no_checksum | :absent

  @callback upload(key :: String.t(), sha256 :: <<_::256>>) :: upload()
  @callback read_url(key :: String.t()) :: String.t()
  @callback object_url(key :: String.t()) :: String.t()
  @callback key_of(url :: String.t()) :: {:ok, String.t()} | :error
  @callback checksum(key :: String.t()) :: {:ok, checksum()} | {:error, :unavailable}

  @spec impl() :: module()
  def impl do
    :fleet_pulse
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:impl, FleetPulse.Storage.Minio)
  end

  @spec upload(String.t(), <<_::256>>) :: upload()
  def upload(key, sha256), do: impl().upload(key, sha256)

  @spec read_url(String.t()) :: String.t()
  def read_url(key), do: impl().read_url(key)

  @spec object_url(String.t()) :: String.t()
  def object_url(key), do: impl().object_url(key)

  @spec key_of(String.t()) :: {:ok, String.t()} | :error
  def key_of(url), do: impl().key_of(url)

  @spec checksum(String.t()) :: {:ok, checksum()} | {:error, :unavailable}
  def checksum(key), do: impl().checksum(key)
end
