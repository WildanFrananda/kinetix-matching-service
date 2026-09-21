defmodule FleetPulse.Dispatch do
  @moduledoc """
  The dispatch context — order intake and driver assignment (PRD 5.5).
  """

  import Ecto.Query

  require Logger

  alias FleetPulse.Clients.Order, as: OrderClient
  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Repo
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverState
  alias FleetPulse.Types

  @type transition_error :: :not_found | :forbidden | :invalid_transition | :invalid_proof

  @legal_transitions %{
    pending: [:cancelled],
    assigned: [:picked_up, :cancelled],
    picked_up: [:delivered, :cancelled]
  }

  @type assign_error :: :no_driver_available | :not_found | :already_assigned

  @type point :: {float(), float()}

  @type dispatch_error ::
          assign_error()
          | :blank_order_number
          | {:no_point, :pickup | :delivery}
          | :order_already_finished
          | Order.changeset()

  @spec dispatch_for_order(String.t(), String.t(), point() | nil, point() | nil) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  def dispatch_for_order(order_number, merchant_principal_id, pickup_point, delivery_point) do
    with {:ok, number} <- require_order_number(order_number),
         {:ok, pickup} <- require_point(pickup_point, :pickup),
         {:ok, delivery} <- require_point(delivery_point, :delivery),
         {:ok, order} <- find_or_book(number, merchant_principal_id, pickup, delivery) do
      assign_if_unassigned(order)
    end
  end

  @spec require_point(point() | nil, :pickup | :delivery) ::
          {:ok, point()} | {:error, {:no_point, :pickup | :delivery}}
  defp require_point({latitude, longitude}, _end_of_journey)
       when is_float(latitude) and is_float(longitude) and
              latitude >= -90.0 and latitude <= 90.0 and
              longitude >= -180.0 and longitude <= 180.0,
       do: {:ok, {latitude, longitude}}

  defp require_point(_absent, end_of_journey), do: {:error, {:no_point, end_of_journey}}

  @spec require_order_number(term()) :: {:ok, String.t()} | {:error, :blank_order_number}
  defp require_order_number(order_number) when is_binary(order_number) do
    case String.trim(order_number) do
      "" -> {:error, :blank_order_number}
      trimmed -> {:ok, trimmed}
    end
  end

  defp require_order_number(_order_number), do: {:error, :blank_order_number}

  @spec find_or_book(String.t(), String.t(), point(), point()) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  defp find_or_book(order_number, merchant_principal_id, pickup, delivery) do
    case Repo.get_by(Order, order_number: order_number) do
      %Order{} = existing -> {:ok, existing}
      nil -> book(order_number, merchant_principal_id, pickup, delivery)
    end
  end

  @spec book(String.t(), String.t(), point(), point()) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  defp book(order_number, merchant_principal_id, {pickup_lat, pickup_lng}, {drop_lat, drop_lng}) do
    create_order(%{
      order_number: order_number,
      merchant_principal_id: merchant_principal_id,
      pickup_latitude: pickup_lat,
      pickup_longitude: pickup_lng,
      dropoff_latitude: drop_lat,
      dropoff_longitude: drop_lng
    })
  end

  @spec assign_if_unassigned(Order.t()) :: {:ok, Order.t()} | {:error, dispatch_error()}
  defp assign_if_unassigned(%Order{status: :pending} = order), do: assign_order(order.id)
  defp assign_if_unassigned(%Order{status: :assigned} = order), do: {:ok, order}
  defp assign_if_unassigned(%Order{status: :picked_up} = order), do: {:ok, order}
  defp assign_if_unassigned(%Order{}), do: {:error, :order_already_finished}

  @spec create_order(map()) :: {:ok, Order.t()} | {:error, Order.changeset()}
  def create_order(attrs) do
    %Order{}
    |> Order.changeset(attrs)
    |> Repo.insert()
    |> announce_order()
  end

  @spec fetch_order(Types.id()) :: {:ok, Order.t()} | {:error, :not_found}
  def fetch_order(order_id) do
    case Repo.get(Order, order_id) do
      nil -> {:error, :not_found}
      %Order{} = order -> {:ok, order}
    end
  end

  @spec list_pending_orders() :: [Order.t()]
  def list_pending_orders do
    Order
    |> where([o], o.status == :pending)
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  @spec list_active_orders() :: [Order.t()]
  def list_active_orders do
    Order
    |> where([o], o.status in [:pending, :assigned, :picked_up])
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  @type order_filter :: [status: Order.status() | :all, limit: pos_integer()]

  @spec list_orders(order_filter()) :: [Order.t()]
  def list_orders(opts \\ []) do
    status = Keyword.get(opts, :status, :all)
    max = Keyword.get(opts, :limit, 50)

    Order
    |> filter_status(status)
    |> order_by([o], desc: o.inserted_at)
    |> limit(^max)
    |> Repo.all()
  end

  @spec count_delivered_today() :: non_neg_integer()
  def count_delivered_today do
    start_of_today = DateTime.new!(Date.utc_today(), ~T[00:00:00.000000])

    Order
    |> where([o], o.status == :delivered and o.updated_at >= ^start_of_today)
    |> Repo.aggregate(:count)
  end

  @spec subscribe_orders() :: Events.subscribe_result()
  def subscribe_orders, do: Events.subscribe_orders()

  @spec active_order_for_driver(Types.id()) :: Order.t() | nil
  def active_order_for_driver(driver_id) do
    Order
    |> where([o], o.driver_id == ^driver_id and o.status in [:assigned, :picked_up])
    |> order_by([o], desc: o.assigned_at)
    |> limit(1)
    |> Repo.one()
  end

  @spec active_orders_for_driver(Types.id()) :: [Order.t()]
  def active_orders_for_driver(driver_id) do
    Order
    |> where([o], o.driver_id == ^driver_id and o.status in [:assigned, :picked_up])
    |> order_by([o], desc: o.assigned_at)
    |> Repo.all()
  end

  @spec assign_order(Types.id(), float()) ::
          {:ok, Order.t()} | {:error, assign_error() | Order.changeset()}
  def assign_order(order_id, radius_km \\ 3.0) do
    result =
      with {:ok, order} <- fetch_order(order_id),
           :ok <- ensure_pending(order),
           {:ok, driver_state} <- claim_nearest(order, radius_km) do
        persist_assignment(order, driver_state)
      end

    :ok = emit_assign_telemetry(result)
    result
  end

  @spec assign_order_to_driver(Types.id(), Types.id()) ::
          {:ok, Order.t()} | {:error, assign_error() | :unavailable | Order.changeset()}
  def assign_order_to_driver(order_id, driver_id) do
    result =
      with {:ok, order} <- fetch_order(order_id),
           :ok <- ensure_pending(order),
           {:ok, driver_state} <- DriverState.claim(driver_id) do
        persist_assignment(order, driver_state)
      end

    :ok = emit_assign_telemetry(result)
    result
  end

  @spec mark_picked_up(Types.id(), Types.id()) :: {:ok, Order.t()} | {:error, transition_error()}
  def mark_picked_up(order_id, driver_id) do
    transition_by_driver(order_id, driver_id, :picked_up)
  end

  @spec mark_delivered(Types.id(), Types.id(), map()) ::
          {:ok, Order.t()} | {:error, transition_error()}
  def mark_delivered(order_id, driver_id, pod_attrs \\ %{}) do
    case transition_by_driver(order_id, driver_id, :delivered, pod_attrs) do
      {:ok, order} ->
        _ = report_delivered(order, driver_id)
        {:ok, order}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @spec report_delivered(Order.t(), Types.id()) :: :ok
  defp report_delivered(%Order{order_number: nil} = order, _driver_id) do
    Logger.warning(
      "[Order] fleet job #{order.id} has no order number, so no delivery can be reported"
    )

    :ok
  end

  defp report_delivered(%Order{} = order, driver_id) do
    with {:ok, driver} <- Tracking.fetch_driver(driver_id),
         {:ok, principal} <- payable_principal(driver) do
      case OrderClient.delivered(order.order_number, principal, DateTime.utc_now()) do
        :ok ->
          :ok

        {:error, reason} ->
          Logger.error(
            "[Order] #{order.order_number} was delivered by #{principal} but order did not " <>
              "record it (#{reason}). The delivery stands; the courier's fee is unrecorded until " <>
              "this is reported again."
          )

          :ok
      end
    else
      _unpayable ->
        Logger.error(
          "[Order] #{order.order_number} was delivered by driver #{driver_id}, who has no " <>
            "identity principal. Nobody can be paid for this delivery until that is linked."
        )

        :ok
    end
  end

  @spec payable_principal(FleetPulse.Tracking.Driver.t()) ::
          {:ok, String.t()} | {:error, :unlinked}
  defp payable_principal(%{principal_id: principal})
       when is_binary(principal) and principal != "",
       do: {:ok, principal}

  defp payable_principal(_driver), do: {:error, :unlinked}

  @spec cancel_order(Types.id()) :: {:ok, Order.t()} | {:error, :not_found | :invalid_transition}
  def cancel_order(order_id) do
    with {:ok, order} <- fetch_order(order_id) do
      transition(order, :cancelled)
    end
  end

  @spec ensure_pending(Order.t()) :: :ok | {:error, :already_assigned}
  defp ensure_pending(%Order{status: :pending}), do: :ok
  defp ensure_pending(%Order{}), do: {:error, :already_assigned}

  @spec claim_nearest(Order.t(), float()) ::
          {:ok, DriverState.t()} | {:error, :no_driver_available}
  defp claim_nearest(order, radius_km) do
    order
    |> eligible_drivers(radius_km)
    |> first_successful_claim()
  end

  @spec eligible_drivers(Order.t(), float()) :: [DriverState.t()]
  defp eligible_drivers(order, radius_km) do
    Tracking.nearby(
      {order.pickup_latitude, order.pickup_longitude},
      radius_km,
      status: :online,
      min_capacity_kg: order.weight_kg
    )
    |> Enum.map(fn {state, _distance} -> state end)
  end

  @spec first_successful_claim([DriverState.t()]) ::
          {:ok, DriverState.t()} | {:error, :no_driver_available}
  defp first_successful_claim([]), do: {:error, :no_driver_available}

  defp first_successful_claim([candidate | rest]) do
    case DriverState.claim(candidate.driver_id) do
      {:ok, claimed} -> {:ok, claimed}
      {:error, _reason} -> first_successful_claim(rest)
    end
  end

  @spec persist_assignment(Order.t(), DriverState.t()) ::
          {:ok, Order.t()} | {:error, Order.changeset()}
  defp persist_assignment(order, driver_state) do
    order
    |> Ecto.Changeset.change(
      status: :assigned,
      driver_id: driver_state.driver_id,
      assigned_at: DateTime.utc_now()
    )
    |> Repo.update()
    |> release_on_failure(driver_state.driver_id)
    |> broadcast_on_success(driver_state.driver_id)
  end

  @spec broadcast_on_success(
          {:ok, Order.t()} | {:error, Order.changeset()},
          Types.id()
        ) :: {:ok, Order.t()} | {:error, Order.changeset()}
  defp broadcast_on_success({:ok, order} = ok, driver_id) do
    :ok = Events.broadcast(driver_id, {:order_assigned, order})
    :ok = Events.broadcast_order(order)
    ok
  end

  defp broadcast_on_success({:error, _changeset} = error, _driver_id), do: error

  @spec release_on_failure(
          {:ok, Order.t()} | {:error, Order.changeset()},
          Types.id()
        ) :: {:ok, Order.t()} | {:error, Order.changeset()}
  defp release_on_failure({:ok, _order} = ok, _driver_id), do: ok

  defp release_on_failure({:error, _changeset} = error, driver_id) do
    _ = DriverState.release(driver_id)
    error
  end

  @spec transition_by_driver(Types.id(), Types.id(), Order.status(), map()) ::
          {:ok, Order.t()} | {:error, transition_error()}
  defp transition_by_driver(order_id, driver_id, target, pod_attrs \\ %{}) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- ensure_owner(order, driver_id) do
      transition(order, target, pod_attrs)
    end
  end

  @spec ensure_owner(Order.t(), Types.id()) :: :ok | {:error, :forbidden}
  defp ensure_owner(%Order{driver_id: driver_id}, driver_id), do: :ok
  defp ensure_owner(%Order{}, _driver_id), do: {:error, :forbidden}

  @spec transition(Order.t(), Order.status(), map()) ::
          {:ok, Order.t()} | {:error, :invalid_transition}
  defp transition(%Order{status: current} = order, target, pod_attrs \\ %{}) do
    apply_transition(legal?(current, target), order, target, pod_attrs)
  end

  @spec legal?(Order.status(), Order.status()) :: boolean()
  defp legal?(current, target) do
    target in Map.get(@legal_transitions, current, [])
  end

  @spec apply_transition(boolean(), Order.t(), Order.status(), map()) ::
          {:ok, Order.t()} | {:error, :invalid_transition}
  defp apply_transition(false, _order, _target, _pod_attrs), do: {:error, :invalid_transition}

  defp apply_transition(true, order, target, pod_attrs) do
    order
    |> Order.pod_changeset(pod_attrs)
    |> Ecto.Changeset.put_change(:status, target)
    |> Repo.update()
    |> after_transition()
  end

  @spec after_transition({:ok, Order.t()} | {:error, Order.changeset()}) ::
          {:ok, Order.t()} | {:error, :invalid_transition | :invalid_proof}
  defp after_transition({:ok, order}) do
    :ok = release_if_terminal(order)
    :ok = broadcast_transition(order)
    :ok = Events.broadcast_order(order)
    :ok = emit_transition_telemetry(order)
    {:ok, order}
  end

  defp after_transition({:error, %Ecto.Changeset{errors: errors}}) do
    proof_fields = [:pod_photo_url, :pod_signature]

    if Enum.any?(errors, fn {field, _error} -> field in proof_fields end) do
      {:error, :invalid_proof}
    else
      {:error, :invalid_transition}
    end
  end

  @spec release_if_terminal(Order.t()) :: :ok
  defp release_if_terminal(%Order{status: status, driver_id: driver_id})
       when status in [:delivered, :cancelled] and is_integer(driver_id) do
    _ = DriverState.release(driver_id)
    :ok
  end

  defp release_if_terminal(%Order{}), do: :ok

  @spec broadcast_transition(Order.t()) :: :ok
  defp broadcast_transition(%Order{driver_id: driver_id} = order) when is_integer(driver_id) do
    Events.broadcast(driver_id, {:order_updated, order})
  end

  defp broadcast_transition(%Order{}), do: :ok

  @spec announce_order({:ok, Order.t()} | {:error, Order.changeset()}) ::
          {:ok, Order.t()} | {:error, Order.changeset()}
  defp announce_order({:ok, order} = ok) do
    :ok = Events.broadcast_order(order)

    :telemetry.execute(
      [:fleet_pulse, :dispatch, :order_created],
      %{count: 1, weight_kg: order.weight_kg},
      %{order_id: order.id}
    )

    ok
  end

  defp announce_order({:error, _changeset} = error), do: error

  @spec emit_assign_telemetry(
          {:ok, Order.t()}
          | {:error, assign_error() | :unavailable | Order.changeset()}
        ) ::
          :ok
  defp emit_assign_telemetry({:ok, order}) do
    ms = DateTime.diff(order.assigned_at, order.inserted_at, :millisecond)

    :telemetry.execute(
      [:fleet_pulse, :dispatch, :order_assigned],
      %{count: 1, time_to_assign_ms: ms},
      %{order_id: order.id, driver_id: order.driver_id}
    )
  end

  defp emit_assign_telemetry({:error, :no_driver_available}) do
    :telemetry.execute([:fleet_pulse, :dispatch, :dispatch_failed], %{count: 1}, %{})
  end

  defp emit_assign_telemetry(_other), do: :ok

  @spec emit_transition_telemetry(Order.t()) :: :ok
  defp emit_transition_telemetry(%Order{status: :delivered} = order) do
    :telemetry.execute([:fleet_pulse, :dispatch, :order_delivered], %{count: 1}, %{
      order_id: order.id
    })
  end

  defp emit_transition_telemetry(%Order{status: :cancelled} = order) do
    :telemetry.execute([:fleet_pulse, :dispatch, :order_cancelled], %{count: 1}, %{
      order_id: order.id
    })
  end

  defp emit_transition_telemetry(%Order{}), do: :ok

  @spec filter_status(Ecto.Queryable.t(), Order.status() | :all) :: Ecto.Queryable.t()
  defp filter_status(query, :all), do: query
  defp filter_status(query, status), do: where(query, [o], o.status == ^status)
end
