defmodule FleetPulse.Storage.Minio do
  @moduledoc """
  The proof-of-delivery bucket in MinIO. Upload and read URLs are signed for the public storage host
  the phone and the backoffice dial; the checksum check is signed for the internal endpoint.

  An upload URL signs `x-amz-checksum-sha256` and `if-none-match: *`, so MinIO stores only the bytes
  whose SHA-256 the courier sent, refuses a second write to the same key, and refuses a request that
  leaves either header out.
  """

  @behaviour FleetPulse.Storage

  require Logger

  alias FleetPulse.Storage.SigV4

  @upload_expiry_seconds 600
  @read_expiry_seconds 900
  @check_expiry_seconds 60

  @impl FleetPulse.Storage
  def upload(key, sha256) do
    headers = %{"if-none-match" => "*", "x-amz-checksum-sha256" => Base.encode64(sha256)}

    %{
      url: presign("PUT", config(:public_url), key, @upload_expiry_seconds, headers),
      headers: headers
    }
  end

  @impl FleetPulse.Storage
  def read_url(key), do: presign("GET", config(:public_url), key, @read_expiry_seconds, %{})

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
  def checksum(key) do
    headers = %{"x-amz-checksum-mode" => "ENABLED"}
    url = presign("HEAD", config(:endpoint), key, @check_expiry_seconds, headers)

    case Req.head(
           url,
           headers: headers,
           retry: false,
           connect_options: [timeout: 2_000],
           receive_timeout: 3_000
         ) do
      {:ok, %Req.Response{status: 200} = response} ->
        {:ok, stored_checksum(response)}

      {:ok, %Req.Response{status: 404}} ->
        {:ok, :absent}

      {:ok, %Req.Response{status: status}} ->
        Logger.error("[Storage] checking #{key} was answered #{status}")
        {:error, :unavailable}

      {:error, reason} ->
        Logger.error("[Storage] checking #{key} failed: #{inspect(reason)}")
        {:error, :unavailable}
    end
  end

  @spec stored_checksum(Req.Response.t()) :: FleetPulse.Storage.checksum()
  defp stored_checksum(response) do
    with [encoded] <- Req.Response.get_header(response, "x-amz-checksum-sha256"),
         {:ok, <<_::256>> = digest} <- Base.decode64(encoded) do
      {:sha256, digest}
    else
      _absent_or_composite -> :no_checksum
    end
  end

  @spec presign(String.t(), String.t(), String.t(), pos_integer(), %{String.t() => String.t()}) ::
          String.t()
  defp presign(method, base_url, key, expires_in, headers) do
    SigV4.presign(
      %{
        method: method,
        base_url: base_url,
        path: "/#{config(:bucket)}/#{key}",
        expires_in: expires_in,
        at: DateTime.utc_now(),
        headers: headers
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
