defmodule FleetPulseWeb.Api.V1.DriverController do
  @moduledoc """
  Read-only fleet tracking for partner applications. Reads from the in-memory
  cache — no database round trip per request.
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverState

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, _params) do
    json(conn, %{data: Enum.map(Tracking.list_tracked(), &serialize/1)})
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, driver_id} <- parse_id(id), {:ok, state} <- Tracking.fetch_state(driver_id) do
      json(conn, %{data: serialize(state)})
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  @spec nearby(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def nearby(conn, params) do
    case parse_nearby(params) do
      {:ok, coordinates, radius_km} ->
        results = Tracking.nearby(coordinates, radius_km, status: :any)
        json(conn, %{data: Enum.map(results, &serialize_nearby/1)})
    end
  end

  defp serialize(%DriverState{} = state) do
    %{
      id: state.driver_id,
      status: state.status,
      coordinates: coordinates(state.coordinates),
      speed_kmh: state.speed_kmh,
      bearing_deg: state.bearing_deg,
      recorded_at: state.recorded_at,
      updated_at: state.synced_at
    }
  end

  defp serialize_nearby({%DriverState{} = state, distance_km}) do
    Map.put(serialize(state), :distance_km, Float.round(distance_km, 3))
  end

  defp coordinates(nil), do: nil
  defp coordinates({lat, lng}), do: %{latitude: lat, longitude: lng}

  defp parse_id(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _invalid -> :error
    end
  end

  defp parse_nearby(%{"latitude" => lat, "longitude" => lng} = params) do
    radius = Map.get(params, "radius_km", "3.0")

    with {latf, _} <- Float.parse(lat),
         {lngf, _} <- Float.parse(lng),
         {radf, _} when radf > 0 <- Float.parse(radius) do
      {:ok, {latf, lngf}, radf}
    else
      _invalid -> :error
    end
  end

  defp parse_nearby(_params), do: :error

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
