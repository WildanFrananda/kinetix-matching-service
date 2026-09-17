defmodule FleetPulse.Geocoding.Provider do
  @moduledoc """
  What a geocoder must be able to do, and nothing more.
  """

  @type point :: %{
          latitude: float(),
          longitude: float(),
          display_name: String.t() | nil
        }

  @type error :: :not_found | :unavailable | :rate_limited

  @callback lookup(String.t()) :: {:ok, point()} | {:error, error()}
end
