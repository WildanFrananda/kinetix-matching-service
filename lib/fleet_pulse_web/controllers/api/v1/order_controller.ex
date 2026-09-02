defmodule FleetPulseWeb.Api.V1.OrderController do
  @moduledoc """
  Read-only order status for partner applications.
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, order_id} <- parse_id(id), {:ok, order} <- Dispatch.fetch_order(order_id) do
      json(conn, %{data: serialize(order)})
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      :error -> error(conn, :nad_request, "invalid_id")
    end
  end

  defp serialize(%Order{} = order) do
    %{
      id: order.id,
      status: order.status,
      weight_kg: order.weight_kg,
      driver_id: order.driver_id,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at
    }
  end

  defp parse_id(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _invalid -> :error
    end
  end

  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
