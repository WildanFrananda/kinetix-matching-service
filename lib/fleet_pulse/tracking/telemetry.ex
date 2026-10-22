defmodule FleetPulse.Tracking.Telemetry do
  @moduledoc """
  Validation and normalisation of inbound GPS telemetry.
  """

  alias FleetPulse.Types

  @max_lead_seconds 300

  @type t :: %{
          latitude: Types.latitude(),
          longitude: Types.longitude(),
          speed_kmh: float() | nil,
          bearing_deg: float() | nil,
          recorded_at: DateTime.t()
        }

  @spec normalise(term()) :: {:ok, t()} | {:error, :invalid_telemetry}
  def normalise(%{recorded_at: %DateTime{} = recorded_at} = payload) do
    with {:ok, lat} <- latitude(Map.get(payload, :latitude)),
         {:ok, lng} <- longitude(Map.get(payload, :longitude)),
         {:ok, speed} <- speed_kmh(Map.get(payload, :speed_kmh)),
         {:ok, bearing} <- bearing_deg(Map.get(payload, :bearing_deg)) do
      {:ok,
       %{
         latitude: lat,
         longitude: lng,
         speed_kmh: speed,
         bearing_deg: bearing,
         recorded_at: with_usec(recorded_at)
       }}
    end
  end

  def normalise(_payload), do: {:error, :invalid_telemetry}

  @spec from_params(term()) :: {:ok, t()} | {:error, :invalid_telemetry}
  def from_params(params) when is_map(params) do
    with {:ok, recorded_at} <- parse_datetime(Map.get(params, "recorded_at")) do
      normalise(%{
        latitude: Map.get(params, "latitude"),
        longitude: Map.get(params, "longitude"),
        speed_kmh: Map.get(params, "speed_kmh"),
        bearing_deg: Map.get(params, "bearing_deg"),
        recorded_at: recorded_at
      })
    end
  end

  def from_params(_params), do: {:error, :invalid_telemetry}

  @spec not_ahead_of(t(), DateTime.t()) :: :ok | {:error, :invalid_telemetry}
  def not_ahead_of(%{recorded_at: recorded_at}, now) do
    within_lead(DateTime.diff(recorded_at, now, :second))
  end

  @spec within_lead(integer()) :: :ok | {:error, :invalid_telemetry}
  defp within_lead(lead) when lead > @max_lead_seconds, do: {:error, :invalid_telemetry}
  defp within_lead(_lead), do: :ok

  @spec latitude(term()) :: {:ok, Types.latitude()} | {:error, :invalid_telemetry}
  defp latitude(value) when is_number(value) and value >= -90 and value <= 90,
    do: {:ok, value * 1.0}

  defp latitude(_value), do: {:error, :invalid_telemetry}

  @spec longitude(term()) :: {:ok, Types.longitude()} | {:error, :invalid_telemetry}
  defp longitude(value) when is_number(value) and value >= -180 and value <= 180,
    do: {:ok, value * 1.0}

  defp longitude(_value), do: {:error, :invalid_telemetry}

  @spec speed_kmh(term()) :: {:ok, float() | nil} | {:error, :invalid_telemetry}
  defp speed_kmh(nil), do: {:ok, nil}
  defp speed_kmh(value) when is_number(value) and value >= 0, do: {:ok, value * 1.0}
  defp speed_kmh(_value), do: {:error, :invalid_telemetry}

  @spec bearing_deg(term()) :: {:ok, float() | nil} | {:error, :invalid_telemetry}
  defp bearing_deg(nil), do: {:ok, nil}

  defp bearing_deg(value) when is_number(value) and value >= 0 and value < 360,
    do: {:ok, value * 1.0}

  defp bearing_deg(_value), do: {:error, :invalid_telemetry}

  @spec with_usec(DateTime.t()) :: DateTime.t()
  defp with_usec(%DateTime{microsecond: {_value, 6}} = recorded_at), do: recorded_at

  defp with_usec(%DateTime{microsecond: {value, _precision}} = recorded_at),
    do: %{recorded_at | microsecond: {value, 6}}

  @spec parse_datetime(term()) :: {:ok, DateTime.t()} | {:error, :invalid_telemetry}
  defp parse_datetime(value) when is_binary(value) do
    case DateTime.from_iso8601(value) do
      {:ok, datetime, _utc_offset} -> {:ok, datetime}
      {:error, _reason} -> {:error, :invalid_telemetry}
    end
  end

  defp parse_datetime(_value), do: {:error, :invalid_telemetry}
end
