defmodule FleetPulseWeb.Api.V1.DispatchController do
  @moduledoc """
  The dispatch board, for the backoffice.
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    case parse_status(Map.get(params, "status", "all")) do
      {:ok, status} ->
        json(conn, %{data: Enum.map(Dispatch.list_orders(status: status), &serialize/1)})

      :error ->
        error(conn, :bad_request, "invalid_status")
    end
  end

  @spec summary(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def summary(conn, _params) do
    json(conn, %{
      data: %{
        pending: length(Dispatch.list_pending_orders()),
        active: length(Dispatch.list_active_orders()),
        delivered_today: Dispatch.count_delivered_today()
      }
    })
  end

  @spec show(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def show(conn, %{"id" => id}) do
    with {:ok, dispatch_id} <- parse_id(id),
         {:ok, order} <- Dispatch.fetch_order(dispatch_id) do
      json(conn, %{data: serialize_with_proof(order)})
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  @spec for_driver(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def for_driver(conn, %{"driver_id" => id}) do
    case parse_id(id) do
      {:ok, driver_id} ->
        json(conn, %{data: Enum.map(Dispatch.active_orders_for_driver(driver_id), &serialize/1)})

      :error ->
        error(conn, :bad_request, "invalid_id")
    end
  end

  @spec assign(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def assign(conn, %{"id" => id, "driver_id" => driver}) do
    with {:ok, dispatch_id} <- parse_id(id),
         {:ok, driver_id} <- parse_id(driver),
         {:ok, order} <- Dispatch.assign_order_to_driver(dispatch_id, driver_id) do
      json(conn, %{data: serialize(order)})
    else
      {:error, :not_found} ->
        error(conn, :not_found, "not_found")

      {:error, :already_assigned} ->
        error(conn, :conflict, "already_assigned")

      {:error, reason} when is_atom(reason) ->
        error(conn, :unprocessable_entity, to_string(reason))

      :error ->
        error(conn, :bad_request, "invalid_id")
    end
  end

  def assign(conn, _params), do: error(conn, :bad_request, "driver_id_required")

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"id" => id}) do
    with {:ok, dispatch_id} <- parse_id(id),
         {:ok, order} <- Dispatch.cancel_order(dispatch_id) do
      json(conn, %{data: serialize(order)})
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :invalid_transition} -> error(conn, :conflict, "invalid_transition")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  @spec serialize(Order.t()) :: map()
  defp serialize(%Order{} = order) do
    %{
      id: order.id,
      order_number: order.order_number,
      status: order.status,
      merchant_principal_id: order.merchant_principal_id,
      weight_kg: order.weight_kg,
      driver_id: order.driver_id,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at,
      inserted_at: order.inserted_at
    }
  end

  @spec serialize_with_proof(Order.t()) :: map()
  defp serialize_with_proof(%Order{} = order) do
    Map.put(serialize(order), :proof_of_delivery, %{
      photo_url: order.pod_photo_url,
      signature: order.pod_signature
    })
  end

  @spec parse_status(String.t()) :: {:ok, Order.status() | :all} | :error
  defp parse_status("all"), do: {:ok, :all}

  defp parse_status(status) when is_binary(status) do
    match = Enum.find(Order.statuses(), fn known -> Atom.to_string(known) == status end)
    if match, do: {:ok, match}, else: :error
  end

  defp parse_status(_status), do: :error

  @spec parse_id(term()) :: {:ok, pos_integer()} | :error
  defp parse_id(id) when is_integer(id) and id > 0, do: {:ok, id}

  defp parse_id(id) when is_binary(id) do
    case Integer.parse(id) do
      {n, ""} when n > 0 -> {:ok, n}
      _invalid -> :error
    end
  end

  defp parse_id(_id), do: :error

  @spec error(Plug.Conn.t(), atom(), String.t()) :: Plug.Conn.t()
  defp error(conn, status, message) do
    conn
    |> put_status(status)
    |> json(%{error: message})
  end
end
