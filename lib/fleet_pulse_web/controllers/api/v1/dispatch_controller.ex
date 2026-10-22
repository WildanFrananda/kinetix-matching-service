defmodule FleetPulseWeb.Api.V1.DispatchController do
  @moduledoc """
  The dispatch board, for the backoffice.
  """

  use FleetPulseWeb, :controller

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Security.AccessClaims

  @max_page_size 200

  @spec index(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def index(conn, params) do
    with {:ok, status} <- parse_status(Map.get(params, "status", "all")),
         {:ok, size} <- parse_page_size(Map.get(params, "limit")),
         {:ok, before} <- parse_cursor(Map.get(params, "before")) do
      page = Dispatch.list_orders(status: status, limit: size, before: before)
      json(conn, %{data: Enum.map(page.orders, &serialize/1), next_cursor: page.next_cursor})
    else
      {:error, reason} -> error(conn, :bad_request, reason)
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
      {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "assignment_refused")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :driver_not_found} -> error(conn, :not_found, "driver_not_found")
      {:error, :already_assigned} -> error(conn, :conflict, "already_assigned")
      {:error, :driver_not_tracked} -> error(conn, :conflict, "driver_not_tracked")
      {:error, :driver_unavailable} -> error(conn, :conflict, "driver_unavailable")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  def assign(conn, _params), do: error(conn, :bad_request, "driver_id_required")

  @spec unassign(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def unassign(conn, %{"id" => id}) do
    %AccessClaims{principal_id: admin} = conn.assigns.current_caller

    with {:ok, dispatch_id} <- parse_id(id),
         {:ok, order} <- Dispatch.unassign_order(dispatch_id, admin) do
      json(conn, %{data: serialize(order)})
    else
      {:error, %Ecto.Changeset{}} -> error(conn, :unprocessable_entity, "unassignment_refused")
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :not_assigned} -> error(conn, :conflict, "not_assigned")
      {:error, :invalid_transition} -> error(conn, :conflict, "invalid_transition")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  @spec cancel(Plug.Conn.t(), map()) :: Plug.Conn.t()
  def cancel(conn, %{"id" => id}) do
    with {:ok, dispatch_id} <- parse_id(id),
         {:ok, order} <- Dispatch.cancel_order(dispatch_id) do
      json(conn, %{data: serialize(order)})
    else
      {:error, :not_found} -> error(conn, :not_found, "not_found")
      {:error, :invalid_transition} -> error(conn, :conflict, "invalid_transition")
      {:error, :bound_to_order} -> error(conn, :conflict, "bound_to_order")
      :error -> error(conn, :bad_request, "invalid_id")
    end
  end

  @spec serialize(Order.t()) :: map()
  defp serialize(%Order{} = order) do
    %{
      id: order.id,
      order_number: order.order_number,
      awb_number: order.awb_number,
      status: order.status,
      merchant_principal_id: order.merchant_principal_id,
      weight_kg: order.weight_kg,
      driver_id: order.driver_id,
      pickup: %{latitude: order.pickup_latitude, longitude: order.pickup_longitude},
      dropoff: %{latitude: order.dropoff_latitude, longitude: order.dropoff_longitude},
      assigned_at: order.assigned_at,
      delivered_at: order.delivered_at,
      inserted_at: order.inserted_at
    }
  end

  @spec serialize_with_proof(Order.t()) :: map()
  defp serialize_with_proof(%Order{} = order) do
    Map.put(
      serialize(order),
      :proof_of_delivery,
      %{
        photo_url: Dispatch.photo_for_review(order),
        signature: order.pod_signature
      }
    )
  end

  @spec parse_status(term()) :: {:ok, Order.status() | :all} | {:error, String.t()}
  defp parse_status("all"), do: {:ok, :all}

  defp parse_status(status) when is_binary(status) do
    case Enum.find(Order.statuses(), fn known -> Atom.to_string(known) == status end) do
      nil -> {:error, "invalid_status"}
      match -> {:ok, match}
    end
  end

  defp parse_status(_status), do: {:error, "invalid_status"}

  @spec parse_page_size(term()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  defp parse_page_size(nil), do: {:ok, nil}

  defp parse_page_size(size) do
    case parse_id(size) do
      {:ok, n} when n <= @max_page_size -> {:ok, n}
      _invalid -> {:error, "invalid_limit"}
    end
  end

  @spec parse_cursor(term()) :: {:ok, pos_integer() | nil} | {:error, String.t()}
  defp parse_cursor(nil), do: {:ok, nil}

  defp parse_cursor(cursor) do
    case parse_id(cursor) do
      {:ok, id} -> {:ok, id}
      :error -> {:error, "invalid_cursor"}
    end
  end

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
