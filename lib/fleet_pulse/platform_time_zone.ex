defmodule FleetPulse.PlatformTimeZone do
  @moduledoc """
  The platform's clock: the IANA zone in `KINETIX_TIME_ZONE`, which warehouse reads too. Days, such as
  the one "delivered today" counts, begin at midnight on it. Checked when the application starts.
  """

  @spec fetch!() :: String.t()
  def fetch! do
    zone = Application.fetch_env!(:fleet_pulse, :time_zone)

    case DateTime.now(zone) do
      {:ok, _now} ->
        zone

      {:error, reason} ->
        raise ArgumentError, "KINETIX_TIME_ZONE #{inspect(zone)} is not a time zone (#{reason})"
    end
  end

  @spec start_of_day(DateTime.t()) :: DateTime.t()
  def start_of_day(%DateTime{} = now) do
    zone = fetch!()

    now
    |> DateTime.shift_zone!(zone)
    |> DateTime.to_date()
    |> midnight(zone)
    |> DateTime.shift_zone!("Etc/UTC")
    |> with_usec()
  end

  @spec with_usec(DateTime.t()) :: DateTime.t()
  defp with_usec(%DateTime{microsecond: {value, _precision}} = moment) do
    %{moment | microsecond: {value, 6}}
  end

  @spec midnight(Date.t(), String.t()) :: DateTime.t()
  defp midnight(date, zone) do
    case DateTime.new(date, ~T[00:00:00.000000], zone) do
      {:ok, midnight} -> midnight
      {:ambiguous, first, _second} -> first
      {:gap, _before, just_after} -> just_after
    end
  end
end
