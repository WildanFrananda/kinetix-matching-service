defmodule FleetPulse.Storage.SigV4 do
  @moduledoc """
  AWS Signature Version 4 presigned URLs for S3-compatible storage, signed over the host header only.
  """

  @type credentials :: %{access_key: String.t(), secret_key: String.t(), region: String.t()}

  @type request :: %{
          method: String.t(),
          base_url: String.t(),
          path: String.t(),
          expires_in: pos_integer(),
          at: DateTime.t()
        }

  @algorithm "AWS4-HMAC-SHA256"
  @service "s3"

  @spec presign(request(), credentials()) :: String.t()
  def presign(request, credentials) do
    uri = URI.parse(request.base_url)
    host = host_header(uri)
    amz_date = Calendar.strftime(request.at, "%Y%m%dT%H%M%SZ")
    date = Calendar.strftime(request.at, "%Y%m%d")
    scope = "#{date}/#{credentials.region}/#{@service}/aws4_request"
    canonical_path = canonical_path(request.path)

    query =
      [
        {"X-Amz-Algorithm", @algorithm},
        {"X-Amz-Credential", "#{credentials.access_key}/#{scope}"},
        {"X-Amz-Date", amz_date},
        {"X-Amz-Expires", Integer.to_string(request.expires_in)},
        {"X-Amz-SignedHeaders", "host"}
      ]
      |> Enum.sort()
      |> Enum.map_join("&", fn {key, value} -> "#{encode(key)}=#{encode(value)}" end)

    canonical_request =
      Enum.join(
        [
          request.method,
          canonical_path,
          query,
          "host:#{host}\n",
          "host",
          "UNSIGNED-PAYLOAD"
        ],
        "\n"
      )

    string_to_sign =
      Enum.join(
        [
          @algorithm,
          amz_date,
          scope,
          hex(:crypto.hash(:sha256, canonical_request))
        ],
        "\n"
      )

    signature =
      credentials
      |> signing_key(date)
      |> hmac(string_to_sign)
      |> hex()

    "#{uri.scheme}://#{host}#{canonical_path}?#{query}&X-Amz-Signature=#{signature}"
  end

  @spec signing_key(credentials(), String.t()) :: binary()
  defp signing_key(credentials, date) do
    ("AWS4" <> credentials.secret_key)
    |> hmac(date)
    |> hmac(credentials.region)
    |> hmac(@service)
    |> hmac("aws4_request")
  end

  @spec host_header(URI.t()) :: String.t()
  defp host_header(%URI{scheme: "https", host: host, port: 443}), do: host
  defp host_header(%URI{scheme: "http", host: host, port: 80}), do: host
  defp host_header(%URI{host: host, port: port}), do: "#{host}:#{port}"

  @spec canonical_path(String.t()) :: String.t()
  defp canonical_path(path) do
    path
    |> String.split("/")
    |> Enum.map_join("/", &encode/1)
  end

  @spec encode(String.t()) :: String.t()
  defp encode(value), do: URI.encode(value, &URI.char_unreserved?/1)

  @spec hmac(binary(), binary()) :: binary()
  defp hmac(key, data), do: :crypto.mac(:hmac, :sha256, key, data)

  @spec hex(binary()) :: String.t()
  defp hex(bytes), do: Base.encode16(bytes, case: :lower)
end
