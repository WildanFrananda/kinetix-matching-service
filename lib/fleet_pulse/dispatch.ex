defmodule FleetPulse.Dispatch do
  @moduledoc """
  The dispatch context — order intake and driver assignment (PRD 5.5).
  """

  import Ecto.Query

  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.DeliveryReporter
  alias FleetPulse.Dispatch.Events
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Dispatch.Proof
  alias FleetPulse.Dispatch.Unassignment
  alias FleetPulse.PlatformTimeZone
  alias FleetPulse.Repo
  alias FleetPulse.Storage
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverState
  alias FleetPulse.Types

  @type transition_error ::
          :not_found
          | :forbidden
          | :invalid_transition
          | :invalid_proof
          | :proof_unverifiable
          | :signature_required
          | :unlinked

  @type pod_upload :: %{
          upload_url: String.t(),
          upload_headers: %{String.t() => String.t()},
          photo_url: String.t()
        }

  @legal_transitions %{
    pending: [:cancelled],
    assigned: [:picked_up, :cancelled],
    picked_up: [:delivered]
  }

  @type assign_error :: :no_driver_available | :not_found | :already_assigned

  @type manual_assign_error ::
          assign_error() | :driver_not_found | :driver_not_tracked | :driver_unavailable

  @type cancel_error :: :not_found | :invalid_transition | :bound_to_order

  @type unassign_error :: :not_found | :not_assigned | :invalid_transition | Ecto.Changeset.t()

  @type point :: {float(), float()}

  @type dispatch_error ::
          assign_error()
          | :blank_order_number
          | {:no_point, :pickup | :delivery}
          | :negative_parcel_weight
          | :order_already_finished
          | Order.changeset()

  @default_page_size 50

  @type order_filter :: [
          status: Order.status() | :all,
          limit: pos_integer() | nil,
          before: Types.id() | nil
        ]

  @type order_page :: %{orders: [Order.t()], next_cursor: Types.id() | nil}

  @typep outcome :: :changed | :repeated

  @typep proof :: %{principal: String.t(), photo: Proof.digest(), signature: Proof.digest()}

  @spec dispatch_for_order(String.t(), String.t(), point() | nil, point() | nil, integer()) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  def dispatch_for_order(
        order_number,
        merchant_principal_id,
        pickup_point,
        delivery_point,
        parcel_weight_grams
      ) do
    with {:ok, number} <- require_order_number(order_number),
         {:ok, pickup} <- require_point(pickup_point, :pickup),
         {:ok, delivery} <- require_point(delivery_point, :delivery),
         {:ok, weight_kg} <- parcel_kilograms(parcel_weight_grams),
         {:ok, order} <- find_or_book(number, merchant_principal_id, pickup, delivery, weight_kg) do
      assign_if_unassigned(order)
    end
  end

  @spec parcel_kilograms(integer()) ::
          {:ok, non_neg_integer()} | {:error, :negative_parcel_weight}
  defp parcel_kilograms(grams) when is_integer(grams) and grams >= 0,
    do: {:ok, div(grams + 999, 1000)}

  defp parcel_kilograms(_grams), do: {:error, :negative_parcel_weight}

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

  @spec find_or_book(String.t(), String.t(), point(), point(), non_neg_integer()) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  defp find_or_book(order_number, merchant_principal_id, pickup, delivery, weight_kg) do
    case Repo.get_by(Order, order_number: order_number) do
      %Order{} = existing -> {:ok, existing}
      nil -> book(order_number, merchant_principal_id, pickup, delivery, weight_kg)
    end
  end

  @spec book(String.t(), String.t(), point(), point(), non_neg_integer()) ::
          {:ok, Order.t()} | {:error, dispatch_error()}
  defp book(
         order_number,
         merchant_principal_id,
         {pickup_lat, pickup_lng},
         {drop_lat, drop_lng},
         weight_kg
       ) do
    create_order(%{
      order_number: order_number,
      merchant_principal_id: merchant_principal_id,
      pickup_latitude: pickup_lat,
      pickup_longitude: pickup_lng,
      dropoff_latitude: drop_lat,
      dropoff_longitude: drop_lng,
      weight_kg: weight_kg,
      awb_number: Order.issue_awb()
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

  @spec list_active_orders_for_merchant(String.t()) :: [Order.t()]
  def list_active_orders_for_merchant(merchant_principal_id) do
    Order
    |> where([o], o.merchant_principal_id == ^merchant_principal_id)
    |> where([o], o.status in [:pending, :assigned, :picked_up])
    |> order_by([o], asc: o.inserted_at)
    |> Repo.all()
  end

  @spec list_orders(order_filter()) :: order_page()
  def list_orders(opts \\ []) do
    size = Keyword.get(opts, :limit) || @default_page_size

    {page, rest} =
      Order
      |> filter_status(Keyword.get(opts, :status, :all))
      |> filter_before(Keyword.get(opts, :before))
      |> order_by([o], desc: o.id)
      |> limit(^(size + 1))
      |> Repo.all()
      |> Enum.split(size)

    %{orders: page, next_cursor: next_cursor(page, rest)}
  end

  @spec count_delivered_today(DateTime.t()) :: non_neg_integer()
  def count_delivered_today(now \\ DateTime.utc_now()) do
    start_of_today = PlatformTimeZone.start_of_day(now)

    Order
    |> where([o], o.status == :delivered and o.delivered_at >= ^start_of_today)
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
          {:ok, Order.t()} | {:error, manual_assign_error() | Order.changeset()}
  def assign_order_to_driver(order_id, driver_id) do
    result =
      with {:ok, order} <- fetch_order(order_id),
           :ok <- ensure_pending(order),
           :ok <- ensure_known_driver(driver_id),
           {:ok, driver_state} <- claim_chosen(driver_id) do
        persist_assignment(order, driver_state)
      end

    :ok = emit_assign_telemetry(result)
    result
  end

  @spec unassign_order(Types.id(), String.t()) :: {:ok, Order.t()} | {:error, unassign_error()}
  def unassign_order(order_id, unassigned_by) do
    fn ->
      with {:ok, order} <- lock_order(order_id),
           {:ok, driver_id} <- ensure_assigned(order),
           {:ok, _record} <- Repo.insert(Unassignment.changeset(order, driver_id, unassigned_by)),
           {:ok, pending} <- return_to_pending(order) do
        {:ok, {pending, driver_id}}
      end
    end
    |> Repo.transact()
    |> announce_unassignment()
  end

  @spec pod_upload(Types.id(), Types.id(), term()) ::
          {:ok, pod_upload()}
          | {:error, :not_found | :forbidden | :invalid_transition | :invalid_photo_hash}
  def pod_upload(order_id, driver_id, photo_sha256) do
    with {:ok, digest} <- Proof.parse_sha256(photo_sha256),
         {:ok, order} <- fetch_order(order_id),
         :ok <- ensure_owner(order, driver_id),
         :ok <- ensure_picked_up(order) do
      key = Proof.photo_key(order.id, digest)
      upload = Storage.upload(key, digest)

      address = %{
        upload_url: upload.url,
        upload_headers: upload.headers,
        photo_url: Storage.object_url(key)
      }

      {:ok, address}
    end
  end

  @spec photo_for_review(Order.t()) :: String.t() | nil
  def photo_for_review(%Order{pod_photo_url: nil}), do: nil

  def photo_for_review(%Order{pod_photo_url: url}) do
    case Storage.key_of(url) do
      {:ok, key} -> Storage.read_url(key)
      :error -> url
    end
  end

  @spec mark_picked_up(Types.id(), Types.id()) :: {:ok, Order.t()} | {:error, transition_error()}
  def mark_picked_up(order_id, driver_id) do
    fn ->
      with {:ok, order} <- lock_order(order_id),
           :ok <- ensure_owner(order, driver_id) do
        advance(order, :picked_up)
      end
    end
    |> Repo.transact()
    |> announce_transition()
  end

  @spec mark_delivered(Types.id(), Types.id(), map()) ::
          {:ok, Order.t()} | {:error, transition_error()}
  def mark_delivered(order_id, driver_id, pod_attrs \\ %{}) do
    with {:ok, order} <- fetch_order(order_id),
         :ok <- ensure_owner(order, driver_id) do
      deliver(order, pod_attrs)
    end
  end

  @spec cancel_order(Types.id()) :: {:ok, Order.t()} | {:error, cancel_error()}
  def cancel_order(order_id) do
    fn ->
      with {:ok, order} <- lock_order(order_id),
           :ok <- ensure_unbound(order) do
        advance(order, :cancelled)
      end
    end
    |> Repo.transact()
    |> announce_transition()
  end

  @spec ensure_picked_up(Order.t()) :: :ok | {:error, :invalid_transition}
  defp ensure_picked_up(%Order{status: :picked_up}), do: :ok
  defp ensure_picked_up(%Order{}), do: {:error, :invalid_transition}

  @spec ensure_unbound(Order.t()) :: :ok | {:error, :bound_to_order}
  defp ensure_unbound(%Order{order_number: nil}), do: :ok
  defp ensure_unbound(%Order{}), do: {:error, :bound_to_order}

  @spec ensure_assigned(Order.t()) ::
          {:ok, Types.id()} | {:error, :not_assigned | :invalid_transition}
  defp ensure_assigned(%Order{status: :assigned, driver_id: driver_id})
       when is_integer(driver_id),
       do: {:ok, driver_id}

  defp ensure_assigned(%Order{status: :pending}), do: {:error, :not_assigned}
  defp ensure_assigned(%Order{}), do: {:error, :invalid_transition}

  @spec return_to_pending(Order.t()) :: {:ok, Order.t()} | {:error, Order.changeset()}
  defp return_to_pending(order) do
    order
    |> Ecto.Changeset.change(status: :pending, driver_id: nil, assigned_at: nil)
    |> Repo.update()
  end

  @spec announce_unassignment({:ok, {Order.t(), Types.id()}} | {:error, unassign_error()}) ::
          {:ok, Order.t()} | {:error, unassign_error()}
  defp announce_unassignment({:ok, {order, driver_id}}) do
    _ = DriverState.release(driver_id)
    :ok = Events.broadcast(driver_id, {:order_unassigned, order})
    :ok = Events.broadcast_order(order)

    :telemetry.execute([:fleet_pulse, :dispatch, :order_unassigned], %{count: 1}, %{
      order_id: order.id,
      driver_id: driver_id
    })

    {:ok, order}
  end

  defp announce_unassignment({:error, reason}), do: {:error, reason}

  @spec deliver(Order.t(), map()) :: {:ok, Order.t()} | {:error, transition_error()}
  defp deliver(%Order{status: :delivered} = order, _pod_attrs), do: {:ok, order}

  defp deliver(%Order{status: :picked_up} = order, pod_attrs) do
    with {:ok, signature} <- Proof.signature_sha256(pod_attrs),
         {:ok, photo} <- verify_photo(order, pod_attrs),
         {:ok, principal} <- delivering_principal(order) do
      proof = %{principal: principal, photo: photo, signature: signature}

      fn -> record_delivery(order, pod_attrs, proof) end
      |> Repo.transact()
      |> announce_transition()
    end
  end

  defp deliver(%Order{}, _pod_attrs), do: {:error, :invalid_transition}

  @spec record_delivery(Order.t(), map(), proof()) ::
          {:ok, {Order.t(), outcome()}} | {:error, transition_error() | Ecto.Changeset.t()}
  defp record_delivery(order, pod_attrs, proof) do
    with {:ok, locked} <- lock_order(order.id),
         :ok <- ensure_owner(locked, order.driver_id) do
      write_delivery(locked, pod_attrs, proof)
    end
  end

  @spec write_delivery(Order.t(), map(), proof()) ::
          {:ok, {Order.t(), outcome()}} | {:error, :invalid_transition | Ecto.Changeset.t()}
  defp write_delivery(%Order{status: :delivered} = order, _pod_attrs, _proof),
    do: {:ok, {order, :repeated}}

  defp write_delivery(%Order{status: :picked_up} = order, pod_attrs, proof) do
    delivered_at = DateTime.utc_now()

    evidence =
      DeliveryEvidence.changeset(
        order,
        proof.principal,
        proof.photo,
        proof.signature,
        delivered_at
      )

    with {:ok, _evidence} <- Repo.insert(evidence),
         {:ok, delivered} <- delivered(order, pod_attrs, delivered_at) do
      {:ok, {delivered, :changed}}
    end
  end

  defp write_delivery(%Order{}, _pod_attrs, _proof), do: {:error, :invalid_transition}

  @spec delivered(Order.t(), map(), DateTime.t()) ::
          {:ok, Order.t()} | {:error, Order.changeset()}
  defp delivered(order, pod_attrs, delivered_at) do
    order
    |> Order.delivery_changeset(pod_attrs, delivered_at)
    |> Ecto.Changeset.put_change(:status, :delivered)
    |> Repo.update()
  end

  @spec verify_photo(Order.t(), map()) ::
          {:ok, Proof.digest()} | {:error, :invalid_proof | :proof_unverifiable}
  defp verify_photo(order, %{"pod_photo_url" => url}) when is_binary(url) do
    with {:ok, key} <- Storage.key_of(url),
         {:ok, named} <- Proof.photo_named(key, order.id) do
      stored_photo(key, named)
    else
      :error -> {:error, :invalid_proof}
    end
  end

  defp verify_photo(_order, _attrs), do: {:error, :invalid_proof}

  @spec stored_photo(String.t(), Proof.digest()) ::
          {:ok, Proof.digest()} | {:error, :invalid_proof | :proof_unverifiable}
  defp stored_photo(key, named) do
    with {:ok, digest} <- stored_as_named(Storage.checksum(key), named) do
      stored_as_jpeg(Storage.leading_bytes(key, Proof.jpeg_magic_size()), digest)
    end
  end

  @spec stored_as_named(
          {:ok, Storage.checksum()} | {:error, :unavailable},
          Proof.digest()
        ) :: {:ok, Proof.digest()} | {:error, :invalid_proof | :proof_unverifiable}
  defp stored_as_named({:ok, {:sha256, named}}, named), do: {:ok, named}
  defp stored_as_named({:ok, _absent_or_other_bytes}, _named), do: {:error, :invalid_proof}
  defp stored_as_named({:error, :unavailable}, _named), do: {:error, :proof_unverifiable}

  @spec stored_as_jpeg({:ok, binary() | :absent} | {:error, :unavailable}, Proof.digest()) ::
          {:ok, Proof.digest()} | {:error, :invalid_proof | :proof_unverifiable}
  defp stored_as_jpeg({:ok, leading}, digest) when is_binary(leading) do
    if Proof.jpeg?(leading), do: {:ok, digest}, else: {:error, :invalid_proof}
  end

  defp stored_as_jpeg({:ok, :absent}, _digest), do: {:error, :invalid_proof}
  defp stored_as_jpeg({:error, :unavailable}, _digest), do: {:error, :proof_unverifiable}

  @spec delivering_principal(Order.t()) :: {:ok, String.t()} | {:error, :unlinked}
  defp delivering_principal(%Order{driver_id: driver_id}) do
    case Tracking.fetch_driver(driver_id) do
      {:ok, %{principal_id: principal}} when is_binary(principal) and principal != "" ->
        {:ok, principal}

      _unnamed ->
        {:error, :unlinked}
    end
  end

  @spec ensure_pending(Order.t()) :: :ok | {:error, :already_assigned}
  defp ensure_pending(%Order{status: :pending}), do: :ok
  defp ensure_pending(%Order{}), do: {:error, :already_assigned}

  @spec ensure_known_driver(Types.id()) :: :ok | {:error, :driver_not_found}
  defp ensure_known_driver(driver_id) do
    case Tracking.fetch_driver(driver_id) do
      {:ok, _driver} -> :ok
      {:error, :not_found} -> {:error, :driver_not_found}
    end
  end

  @spec claim_chosen(Types.id()) ::
          {:ok, DriverState.t()} | {:error, :driver_not_tracked | :driver_unavailable}
  defp claim_chosen(driver_id) do
    case DriverState.claim(driver_id) do
      {:ok, claimed} -> {:ok, claimed}
      {:error, :not_found} -> {:error, :driver_not_tracked}
      {:error, :unavailable} -> {:error, :driver_unavailable}
    end
  end

  @spec claim_nearest(Order.t(), float()) ::
          {:ok, DriverState.t()} | {:error, :no_driver_available}
  defp claim_nearest(order, radius_km) do
    order
    |> eligible_drivers(radius_km)
    |> first_successful_claim()
  end

  @spec eligible_drivers(Order.t(), float()) :: [DriverState.t()]
  defp eligible_drivers(order, radius_km) do
    taken_off = drivers_taken_off(order.id)

    {order.pickup_latitude, order.pickup_longitude}
    |> Tracking.nearby(radius_km, status: :online, min_capacity_kg: order.weight_kg, fresh: true)
    |> Enum.map(fn {state, _distance} -> state end)
    |> Enum.reject(&MapSet.member?(taken_off, &1.driver_id))
  end

  @spec drivers_taken_off(Types.id()) :: MapSet.t(Types.id())
  defp drivers_taken_off(order_id) do
    Unassignment
    |> where([u], u.order_id == ^order_id)
    |> select([u], u.driver_id)
    |> Repo.all()
    |> MapSet.new()
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
          {:ok, Order.t()} | {:error, :not_found | :already_assigned | Order.changeset()}
  defp persist_assignment(order, driver_state) do
    order
    |> write_assignment(driver_state.driver_id)
    |> release_on_failure(driver_state.driver_id)
    |> broadcast_on_success(driver_state.driver_id)
  end

  @spec write_assignment(Order.t(), Types.id()) ::
          {:ok, Order.t()} | {:error, :not_found | :already_assigned | Order.changeset()}
  defp write_assignment(order, driver_id) do
    fn ->
      with {:ok, locked} <- lock_order(order.id),
           :ok <- ensure_pending(locked) do
        locked
        |> Ecto.Changeset.change(
          status: :assigned,
          driver_id: driver_id,
          assigned_at: DateTime.utc_now()
        )
        |> Repo.update()
      end
    end
    |> Repo.transact()
  rescue
    exception ->
      _ = DriverState.release(driver_id)
      reraise exception, __STACKTRACE__
  catch
    :exit, reason ->
      _ = DriverState.release(driver_id)
      exit(reason)
  end

  @spec broadcast_on_success({:ok, Order.t()} | {:error, term()}, Types.id()) ::
          {:ok, Order.t()} | {:error, term()}
  defp broadcast_on_success({:ok, order} = ok, driver_id) do
    :ok = Events.broadcast(driver_id, {:order_assigned, order})
    :ok = Events.broadcast_order(order)
    ok
  end

  defp broadcast_on_success({:error, _reason} = error, _driver_id), do: error

  @spec release_on_failure({:ok, Order.t()} | {:error, term()}, Types.id()) ::
          {:ok, Order.t()} | {:error, term()}
  defp release_on_failure({:ok, _order} = ok, _driver_id), do: ok

  defp release_on_failure({:error, _reason} = error, driver_id) do
    _ = DriverState.release(driver_id)
    error
  end

  @spec lock_order(Types.id()) :: {:ok, Order.t()} | {:error, :not_found}
  defp lock_order(order_id) do
    Order
    |> where([o], o.id == ^order_id)
    |> lock("FOR UPDATE")
    |> Repo.one()
    |> case do
      nil -> {:error, :not_found}
      %Order{} = order -> {:ok, order}
    end
  end

  @spec ensure_owner(Order.t(), Types.id()) :: :ok | {:error, :forbidden}
  defp ensure_owner(%Order{driver_id: driver_id}, driver_id), do: :ok
  defp ensure_owner(%Order{}, _driver_id), do: {:error, :forbidden}

  @spec advance(Order.t(), Order.status()) ::
          {:ok, {Order.t(), outcome()}} | {:error, :invalid_transition | Order.changeset()}
  defp advance(%Order{status: target} = order, target), do: {:ok, {order, :repeated}}

  defp advance(%Order{status: current} = order, target) do
    apply_transition(legal?(current, target), order, target)
  end

  @spec legal?(Order.status(), Order.status()) :: boolean()
  defp legal?(current, target) do
    target in Map.get(@legal_transitions, current, [])
  end

  @spec apply_transition(boolean(), Order.t(), Order.status()) ::
          {:ok, {Order.t(), outcome()}} | {:error, :invalid_transition | Order.changeset()}
  defp apply_transition(false, _order, _target), do: {:error, :invalid_transition}

  defp apply_transition(true, order, target) do
    with {:ok, updated} <- order |> Ecto.Changeset.change(status: target) |> Repo.update() do
      {:ok, {updated, :changed}}
    end
  end

  @spec announce_transition({:ok, {Order.t(), outcome()}} | {:error, atom() | Ecto.Changeset.t()}) ::
          {:ok, Order.t()} | {:error, atom()}
  defp announce_transition({:ok, {order, :repeated}}), do: {:ok, order}

  defp announce_transition({:ok, {order, :changed}}) do
    :ok = release_if_terminal(order)
    :ok = broadcast_transition(order)
    :ok = Events.broadcast_order(order)
    :ok = emit_transition_telemetry(order)
    :ok = report_if_delivered(order)
    {:ok, order}
  end

  defp announce_transition({:error, %Ecto.Changeset{errors: errors}}) do
    proof_fields = [:pod_photo_url, :pod_signature]

    if Enum.any?(errors, fn {field, _error} -> field in proof_fields end) do
      {:error, :invalid_proof}
    else
      {:error, :invalid_transition}
    end
  end

  defp announce_transition({:error, reason}) when is_atom(reason), do: {:error, reason}

  @spec release_if_terminal(Order.t()) :: :ok
  defp release_if_terminal(%Order{status: status, driver_id: driver_id})
       when status in [:delivered, :cancelled] and is_integer(driver_id) do
    _ = DriverState.release(driver_id)
    :ok
  end

  defp release_if_terminal(%Order{}), do: :ok

  @spec report_if_delivered(Order.t()) :: :ok
  defp report_if_delivered(%Order{status: :delivered, order_number: number})
       when is_binary(number),
       do: DeliveryReporter.kick()

  defp report_if_delivered(%Order{}), do: :ok

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

  @spec emit_assign_telemetry({:ok, Order.t()} | {:error, term()}) :: :ok
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

  @spec filter_before(Ecto.Queryable.t(), Types.id() | nil) :: Ecto.Queryable.t()
  defp filter_before(query, nil), do: query
  defp filter_before(query, before), do: where(query, [o], o.id < ^before)

  @spec next_cursor([Order.t()], [Order.t()]) :: Types.id() | nil
  defp next_cursor(_page, []), do: nil
  defp next_cursor(page, _more), do: List.last(page).id
end
