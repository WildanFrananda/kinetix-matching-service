defmodule FleetPulse.Storage.Minio do
  @moduledoc """
  The proof-of-delivery bucket in MinIO. Upload and read URLs are signed for the public storage host
  the phone and the backoffice dial; the existence check is signed for the internal endpoint.
  """

  @behaviour FleetPulse.Storage

  require Logger

  alias FleetPulse.Storage.SigV4

  @upload_expiry_seconds 600
  @read_expiry_seconds 900
  @check_expiry_seconds 60

  @impl FleetPulse.Storage
  def upload_url(key), do: presign("PUT", config(:public_url), key, @upload_expiry_seconds)

  @impl FleetPulse.Storage
  def read_url(key), do: presign("GET", config(:public_url), key, @read_expiry_seconds)

  @impl FleetPulse.Storage
  def object_url(key), do: "#{config(:public_url)}/#{config(:bucket)}/#{key}"

  @impl FleetPulse.Storage
  def key_of(url) do
    prefix = "#{config(:public_url)}/#{config(:bucket)}/"

    if String.starts_with?(url, prefix) do
      {:ok, String.replace_prefix(url, prefix, "")}
    else
      :error
    end
  end

  @impl FleetPulse.Storage
  def exists?(key) do
    url = presign("HEAD", config(:endpoint), key, @check_expiry_seconds)

    case Req.head(url, retry: false, connect_options: [timeout: 2_000], receive_timeout: 3_000) do
      {:ok, %Req.Response{status: 200}} ->
        {:ok, true}

      {:ok, %Req.Response{status: 404}} ->
        {:ok, false}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("[Storage] checking #{key} was answered #{status}")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.error("[Storage] checking #{key} failed: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  @spec presign(String.t(), String.t(), String.t(), pos_integer()) :: String.t()
  defp presign(method, base_url, key, expires_in) do
    SigV4.presign(
      %{
        method: method,
        base_url: base_url,
        path: "/#{config(:bucket)}/#{key}",
        expires_in: expires_in,
        at: DateTime.utc_now()
      },
      %{
        access_key: config(:access_key),
        secret_key: config(:secret_key),
        region: config(:region)
      }
    )
  end

  @spec config(atom()) :: String.t()
  defp config(name) do
    :fleet_pulse
    |> Application.fetch_env!(__MODULE__)
    |> Keyword.fetch!(name)
  end
end
