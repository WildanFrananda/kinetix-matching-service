defmodule FleetPulse.Geocoding do
  @moduledoc """
  Turns an address into a point, asking a stranger as rarely as possible.
  """

  import Ecto.Query

  require Logger

  alias FleetPulse.Geocoding.GeocodedAddress
  alias FleetPulse.Geocoding.Provider
  alias FleetPulse.Repo

  @type coordinates :: {float(), float()}

  @spec coordinates_for(String.t()) :: {:ok, coordinates()} | {:error, Provider.error()}
  def coordinates_for(address) when is_binary(address) do
    case normalise(address) do
      "" ->
        {:error, :not_found}

      query ->
        case cached(query) do
          %GeocodedAddress{} = hit -> {:ok, {hit.latitude, hit.longitude}}
          nil -> lookup_and_remember(query)
        end
    end
  end

  def coordinates_for(_address), do: {:error, :not_found}

  @spec forget(String.t()) :: :ok
  def forget(address) when is_binary(address) do
    GeocodedAddress
    |> where([a], a.query == ^normalise(address))
    |> Repo.delete_all()

    :ok
  end

  @spec provider() :: module()
  def provider do
    Application.get_env(:fleet_pulse, __MODULE__, [])
    |> Keyword.get(:provider, FleetPulse.Geocoding.Nominatim)
  end

  @spec lookup_and_remember(String.t()) :: {:ok, coordinates()} | {:error, Provider.error()}
  defp lookup_and_remember(query) do
    case provider().lookup(query) do
      {:ok, point} -> remember(query, point)
      {:error, reason} -> {:error, reason}
    end
  end

  @spec remember(String.t(), Provider.point()) :: {:ok, coordinates()} | {:error, :unavailable}
  defp remember(query, point) do
    changeset =
      GeocodedAddress.changeset(%GeocodedAddress{}, %{
        query: query,
        latitude: point.latitude,
        longitude: point.longitude,
        provider: to_string(provider()),
        display_name: Map.get(point, :display_name)
      })

    if changeset.valid? do
      Repo.insert(changeset, on_conflict: :nothing, conflict_target: :query)
      {:ok, {point.latitude, point.longitude}}
    else
      Logger.error(
        "[Geocoding] #{inspect(provider())} answered #{inspect(query)} with a point that is not " <>
          "on Earth: #{inspect(changeset.errors)}"
      )

      {:error, :unavailable}
    end
  end

  @spec cached(String.t()) :: GeocodedAddress.t() | nil
  defp cached(query), do: Repo.get_by(GeocodedAddress, query: query)

  @spec normalise(String.t()) :: String.t()
  defp normalise(address) do
    address
    |> String.trim()
    |> String.downcase()
    |> String.replace(~r/\s+/u, " ")
  end
end
