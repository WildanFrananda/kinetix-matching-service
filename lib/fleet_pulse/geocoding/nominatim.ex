defmodule FleetPulse.Geocoding.Nominatim do
  @moduledoc """
  OpenStreetMap's geocoder, used under its public usage policy.
  """

  @behaviour FleetPulse.Geocoding.Provider

  require Logger

  @default_base "https://nominatim.openstreetmap.org"

  @impl FleetPulse.Geocoding.Provider
  @spec lookup(String.t()) ::
          {:ok, FleetPulse.Geocoding.Provider.point()}
          | {:error, FleetPulse.Geocoding.Provider.error()}
  def lookup(query) when is_binary(query) do
    case request(query) do
      {:ok, %Req.Response{status: 200, body: body}} -> first_point(body, query)
      {:ok, %Req.Response{status: 429}} -> rate_limited(query)
      {:ok, %Req.Response{status: status}} -> unavailable(query, "HTTP #{status}")
      {:error, reason} -> unavailable(query, inspect(reason))
    end
  end

  @spec request(String.t()) :: {:ok, Req.Response.t()} | {:error, term()}
  defp request(query) do
    Req.get(base_url() <> "/search",
      params: [q: query, format: "jsonv2", limit: 1, addressdetails: 0],
      headers: [{"user-agent", user_agent()}, {"accept-language", "id,en"}],
      retry: false,
      connect_options: [timeout: 3_000],
      receive_timeout: 8_000
    )
  end

  @spec first_point(term(), String.t()) ::
          {:ok, FleetPulse.Geocoding.Provider.point()} | {:error, :not_found | :unavailable}
  defp first_point([%{"lat" => lat, "lon" => lon} = result | _rest], query) do
    with {latitude, ""} <- Float.parse(to_string(lat)),
         {longitude, ""} <- Float.parse(to_string(lon)) do
      {:ok,
       %{
         latitude: latitude,
         longitude: longitude,
         display_name: Map.get(result, "display_name")
       }}
    else
      _unparseable ->
        unavailable(query, "coordinates were not numbers: #{inspect(lat)},#{inspect(lon)}")
    end
  end

  defp first_point([], _query), do: {:error, :not_found}

  defp first_point(body, query), do: unavailable(query, "unexpected body: #{inspect(body)}")

  @spec rate_limited(String.t()) :: {:error, :rate_limited}
  defp rate_limited(query) do
    Logger.warning("[Geocoding] the geocoder rate-limited the lookup of #{inspect(query)}")
    {:error, :rate_limited}
  end

  @spec unavailable(String.t(), String.t()) :: {:error, :unavailable}
  defp unavailable(query, detail) do
    Logger.error("[Geocoding] could not geocode #{inspect(query)}: #{detail}")
    {:error, :unavailable}
  end

  @spec base_url() :: String.t()
  defp base_url, do: System.get_env("GEOCODER_BASE_URL") || @default_base

  @spec user_agent() :: String.t()
  defp user_agent do
    System.get_env("GEOCODER_USER_AGENT") ||
      raise "GEOCODER_USER_AGENT is required: the geocoder's usage policy refuses anonymous requests."
  end
end
