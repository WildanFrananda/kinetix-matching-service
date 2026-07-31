defmodule FleetPulseWeb.DispatchLive do
  @moduledoc """
  The dispatcher's live fleet view (PRD 5.4).

  Reads the current fleet from ETS once at mount, then keeps itself current
  from PubSub. Nothing polls, and no database query runs after mount.

  ## Why updates are buffered

  At the PRD's fleet size the `"tracking:fleet"` topic carries roughly 2000
  messages per second. Assigning on every one of them would mean 2000 renders
  and 2000 DOM patches per second — work no human eye can consume.

  So updates accumulate in `:pending`, a map keyed by driver_id, and are
  merged into `:drivers` on a timer. The map is doing two jobs: it caps the
  render rate, and it DEDUPLICATES. A driver that pings ten times between two
  flushes collapses into a single entry holding its latest position. A list
  would only delay the same 2000 updates, not reduce them.
  """

  use FleetPulseWeb, :live_view

  alias FleetPulse.Dispatch
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Tracking
  alias FleetPulse.Tracking.DriverState
  alias FleetPulse.Types
  alias Phoenix.LiveView.Rendered
  alias Phoenix.LiveView.Socket

  @default_flush_interval_ms 500

  @typedoc "Drivers indexed by id, the shape both `:drivers` and `:pending` hold."
  @type index :: %{Types.id() => DriverState.t()}

  @impl Phoenix.LiveView
  @spec mount(map(), map(), Socket.t()) :: {:ok, Socket.t()}
  def mount(_params, _session, socket) do
    {:ok, start(connected?(socket), socket)}
  end

  @impl Phoenix.LiveView
  @spec handle_info(
          {:driver_updated, DriverState.t()}
          | {:driver_stopped, Types.id()}
          | {:order_changed, Order.t()}
          | :flush,
          Socket.t()
        ) :: {:noreply, Socket.t()}
  def handle_info({:driver_updated, state}, socket) do
    {:noreply, update(socket, :pending, &Map.put(&1, state.driver_id, state))}
  end

  def handle_info({:driver_stopped, driver_id}, socket) do
    {:noreply,
     socket
     |> update(:drivers, &Map.delete(&1, driver_id))
     |> update(:pending, &Map.delete(&1, driver_id))}
  end

  def handle_info({:order_changed, _order}, socket) do
    {:noreply, socket |> assign_orders() |> assign_stats() |> assign_history()}
  end

  def handle_info(:flush, socket) do
    _timer = schedule_flush()
    socket = flush(socket)

    driver_payloads =
      socket.assigns.drivers
      |> Map.values()
      |> Enum.reject(&is_nil(&1.coordinates))
      |> Enum.map(fn d ->
        {lat, lng} = d.coordinates

        %{
          id: d.driver_id,
          status: d.status,
          lat: lat,
          lng: lng,
          speed: d.speed_kmh
        }
      end)

    {:noreply, push_event(socket, "fleet_updated", %{drivers: driver_payloads})}
  end

  @impl Phoenix.LiveView
  @spec handle_event(String.t(), map(), Socket.t()) :: {:noreply, Socket.t()}
  def handle_event("approve_driver", %{"id" => id}, socket) when is_binary(id) do
    driver_id = String.to_integer(id)

    case Tracking.approve_driver(driver_id) do
      {:ok, _driver} ->
        {:noreply,
         socket
         |> put_flash(:info, "Driver ##{driver_id} successfully approved!")
         |> assign(:pending_approval, Tracking.list_pending_drivers())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to approved driver.")}
    end
  end

  def handle_event("reject_driver", %{"id" => id}, socket) when is_binary(id) do
    driver_id = String.to_integer(id)

    case Tracking.reject_driver(driver_id) do
      {:ok, _driver} ->
        {:noreply,
         socket
         |> put_flash(:info, "Driver ##{driver_id} registration rejected.")
         |> assign(:pending_approval, Tracking.list_pending_drivers())}

      {:error, _reason} ->
        {:noreply, put_flash(socket, :error, "Failed to reject driver.")}
    end
  end

  def handle_event("create_order", %{"order" => params}, socket) do
    case Dispatch.create_order(params) do
      {:ok, _order} ->
        {:noreply,
         socket
         |> put_flash(:info, "Order created.")
         |> assign_orders()
         |> assign_order_form()}

      {:error, changeset} ->
        {:noreply, assign(socket, :order_form, to_form(changeset, as: :order))}
    end
  end

  def handle_event("assign_order", %{"id" => id}, socket) when is_binary(id) do
    order_id = String.to_integer(id)

    flashed =
      case Dispatch.assign_order(order_id) do
        {:ok, order} ->
          put_flash(socket, :info, "Order ##{order.id} → driver ##{order.driver_id}.")

        {:error, :no_driver_available} ->
          put_flash(socket, :error, "No eligible driver in range.")

        {:error, _reason} ->
          put_flash(socket, :error, "Could not assign the order.")
      end

    {:noreply, assign_orders(flashed)}
  end

  def handle_event("cancel_order", %{"id" => id}, socket) when is_binary(id) do
    order_id = String.to_integer(id)

    flashed =
      case Dispatch.cancel_order(order_id) do
        {:ok, _order} -> put_flash(socket, :info, "Order ##{order_id} cancelled.")
        {:error, _reason} -> put_flash(socket, :error, "Could not cancel the order.")
      end

    {:noreply, assign_orders(flashed)}
  end

  def handle_event("filter_history", %{"status" => status}, socket) do
    {:noreply,
     socket
     |> assign(:history_status, to_status_filter(status))
     |> assign_history()}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <Layouts.app flash={@flash}>
      <.header>
        Dispatch Center
        <:subtitle>{map_size(@drivers)} driver(s) tracked</:subtitle>
      </.header>

      <div class="mt-6 grid grid-cols-2 gap-4 sm:grid-cols-4">
        <.stat_tile
          label="Drivers online"
          value={online_count(@drivers)}
          hint={"#{map_size(@drivers)} tracked"}
        />
        <.stat_tile label="Active orders" value={length(@orders)} />
        <.stat_tile label="Waiting" value={pending_count(@orders)} hint="unassigned" />
        <.stat_tile label="Delivered today" value={@delivered_today} />
      </div>

      <div class="my-6">
        <div
          id="fleet-map-container"
          phx-hook=".FleetMap"
          phx-update="ignore"
          class="h-[520px] w-full rounded-2xl border border-slate-700 shadow-2xl overflow-hidden"
        >
        </div>
      </div>

      <script :type={Phoenix.LiveView.ColocatedHook} name=".FleetMap">
        import L from "leaflet"

        export default {
          mounted() {
            this.map = L.map(this.el).setView([-6.2088, 106.8456], 12)
            this.markers = {}

            L.tileLayer('https://{s}.basemaps.cartocdn.com/dark_all/{z}/{x}/{y}{r}.png', {
              attribution: '&copy; <a href="https://www.openstreetmap.org/copyright">OpenStreetMap</a> &copy; <a href="https://carto.com/attributions">CARTO</a>',
              subdomains: 'abcd',
              maxZoom: 19
            }).addTo(this.map)

            this.handleEvent("fleet_updated", ({ drivers }) => {
              const bounds = []

              drivers.forEach(driver => {
                const latLng = [driver.lat, driver.lng]
                bounds.push(latLng)

                if (this.markers[driver.id]) {
                  this.markers[driver.id].setLatLng(latLng)
                  this.markers[driver.id].getPopup().setContent(this.popupContent(driver))
                } else {
                  const marker = L.circleMarker(latLng)
                    .addTo(this.map)
                    .bindPopup(this.popupContent(driver))
                  this.markers[driver.id] = marker
                }
              })

              if (bounds.length > 0 && !this.userHasZoomed) {
                this.map.fitBounds(bounds, { padding: [50, 50], maxZoom: 15 })
                this.userHasZoomed = true
              }
            })
          },

          popupContent(driver) {
            const speed = driver.speed ? Math.round(driver.speed * 10) / 10 : 0;
            return `
              <div class="p-1 text-slate-900 font-sans">
                <div class="font-bold text-sm">🚚 Driver #${driver.id}</div>
                <div class="text-xs text-slate-600 mt-1">Status: <span class="font-semibold uppercase text-blue-600">${driver.status}</span></div>
                <div class="text-xs text-slate-600">Speed: <span class="font-semibold">${speed} km/h</span></div>
              </div>
            `
          }
        }
      </script>

      <div class="mt-8 rounded-2xl border border-slate-700 p-6">
        <h3 class="text-lg font-bold mb-4">Orders</h3>

        <.form
          for={@order_form}
          id="order-form"
          phx-submit="create_order"
          class="grid grid-cols-2 gap-3 sm:grid-cols-6 items-end mb-6"
        >
          <.input field={@order_form[:pickup_latitude]} type="number" step="any" label="Pickup lat" />
          <.input field={@order_form[:pickup_longitude]} type="number" step="any" label="Pickup lng" />
          <.input field={@order_form[:dropoff_latitude]} type="number" step="any" label="Dropoff lat" />
          <.input
            field={@order_form[:dropoff_longitude]}
            type="number"
            step="any"
            label="Dropoff lng"
          />
          <.input field={@order_form[:weight_kg]} type="number" label="Weight (kg)" />
          <.button class="btn btn-primary">Create</.button>
        </.form>

        <.table id="orders" rows={@orders}>
          <:col :let={order} label="ID">{order.id}</:col>
          <:col :let={order} label="Status"><.status_badge status={order.status} /></:col>
          <:col :let={order} label="Pickup">
            {order_point(order.pickup_latitude, order.pickup_longitude)}
          </:col>
          <:col :let={order} label="Weight">{order.weight_kg} kg</:col>
          <:col :let={order} label="Driver">{order.driver_id || "—"}</:col>
          <:col :let={order} label="Actions">
            <div class="flex gap-2">
              <.button
                :if={order.status == :pending}
                phx-click="assign_order"
                phx-value-id={order.id}
                class="bg-blue-600 hover:bg-blue-500 text-white text-xs px-3 py-1 rounded"
              >
                Assign
              </.button>
              <.button
                phx-click="cancel_order"
                phx-value-id={order.id}
                class="bg-rose-600 hover:bg-rose-500 text-white text-xs px-3 py-1 rounded"
              >
                Cancel
              </.button>
            </div>
          </:col>
        </.table>
      </div>

      <.table id="drivers" rows={rows(@drivers)}>
        <:col :let={driver} label="Driver">{driver.driver_id}</:col>
        <:col :let={driver} label="Status"><.status_badge status={driver.status} /></:col>
        <:col :let={driver} label="Position">{position(driver.coordinates)}</:col>
        <:col :let={driver} label="Speed">{speed(driver.speed_kmh)}</:col>
        <:col :let={driver} label="Last seen">{seen(driver.synced_at)}</:col>
      </.table>

      <div class="mt-8 rounded-2xl border border-base-300 p-6">
        <div class="flex items-center justify-between mb-4">
          <h3 class="text-lg font-bold">Order history</h3>

          <form id="history-form" phx-change="filter_history">
            <select name="status" class="select select-sm select-bordered">
              <option value="all" selected={@history_status == :all}>All</option>
              <option value="pending" selected={@history_status == :pending}>Pending</option>
              <option value="assigned" selected={@history_status == :assigned}>Assigned</option>
              <option value="picked_up" selected={@history_status == :picked_up}>Picked up</option>
              <option value="delivered" selected={@history_status == :delivered}>Delivered</option>
              <option value="cancelled" selected={@history_status == :cancelled}>Cancelled</option>
            </select>
          </form>
        </div>

        <.table id="history" rows={@history}>
          <:col :let={order} label="ID">{order.id}</:col>
          <:col :let={order} label="Status"><.status_badge status={order.status} /></:col>
          <:col :let={order} label="Driver">{order.driver_id || "—"}</:col>
          <:col :let={order} label="Weight">{order.weight_kg} kg</:col>
          <:col :let={order} label="Created">{when_at(order.inserted_at)}</:col>
        </.table>
      </div>

      <%!-- Pending Driver Approvals Section --%>
      <%= if length(@pending_approval) > 0 do %>
        <div class="mt-10 rounded-2xl border border-amber-500/30 bg-amber-500/5 p-6">
          <h3 class="text-lg font-bold text-amber-400 mb-4 flex items-center gap-2">
            <span>⚠️ Pending Admin Approval ({length(@pending_approval)})</span>
          </h3>

          <.table id="pending-drivers" rows={@pending_approval}>
            <:col :let={driver} label="Name">{driver.name}</:col>
            <:col :let={driver} label="Phone">{driver.phone}</:col>
            <:col :let={driver} label="Vehicle Plate">{driver.vehicle_plate}</:col>
            <:col :let={driver} label="Capacity">{driver.capacity_kg} kg</:col>
            <:col :let={driver} label="Actions">
              <div class="flex gap-2">
                <.button
                  phx-click="approve_driver"
                  phx-value-id={driver.id}
                  class="bg-emerald-600 hover:bg-emerald-500 text-white text-xs px-3 py-1 rounded"
                >
                  Approve
                </.button>
                <.button
                  phx-click="reject_driver"
                  phx-value-id={driver.id}
                  class="bg-rose-600 hover:bg-rose-500 text-white text-xs px-3 py-1 rounded"
                >
                  Reject
                </.button>
              </div>
            </:col>
          </.table>
        </div>
      <% end %>
    </Layouts.app>
    """
  end

  @spec start(boolean(), Socket.t()) :: Socket.t()
  defp start(true, socket) do
    :ok = Tracking.subscribe_fleet()
    :ok = Dispatch.subscribe_orders()
    _timer = schedule_flush()
    assign_fleet(socket)
  end

  defp start(false, socket), do: assign_fleet(socket)

  @spec assign_fleet(Socket.t()) :: Socket.t()
  defp assign_fleet(socket) do
    drivers = Map.new(Tracking.list_tracked(), &{&1.driver_id, &1})

    socket
    |> assign(:drivers, drivers)
    |> assign(:pending_approval, Tracking.list_pending_drivers())
    |> assign(:pending, %{})
    |> assign_orders()
    |> assign_order_form()
    |> assign_stats()
    |> assign(:history_status, :all)
    |> assign_history()
  end

  @spec assign_orders(Socket.t()) :: Socket.t()
  defp assign_orders(socket), do: assign(socket, :orders, Dispatch.list_active_orders())

  @spec assign_order_form(Socket.t()) :: Socket.t()
  defp assign_order_form(socket) do
    assign(socket, :order_form, to_form(Order.changeset(%Order{}, %{}), as: :order))
  end

  @spec flush(Socket.t()) :: Socket.t()
  defp flush(socket) do
    merge_pending(map_size(socket.assigns.pending), socket)
  end

  @spec merge_pending(non_neg_integer(), Socket.t()) :: Socket.t()
  defp merge_pending(0, socket), do: socket

  defp merge_pending(_count, socket) do
    socket
    |> update(:drivers, &Map.merge(&1, socket.assigns.pending))
    |> assign(:pending, %{})
  end

  @spec schedule_flush() :: reference()
  defp schedule_flush do
    Process.send_after(self(), :flush, flush_interval_ms())
  end

  @spec flush_interval_ms() :: pos_integer()
  defp flush_interval_ms do
    :fleet_pulse
    |> Application.get_env(__MODULE__, [])
    |> Keyword.get(:flush_interval_ms)
    |> interval_or_default()
  end

  @spec assign_stats(Socket.t()) :: Socket.t()
  defp assign_stats(socket) do
    assign(socket, :delivered_today, Dispatch.count_delivered_today())
  end

  @spec assign_history(Socket.t()) :: Socket.t()
  defp assign_history(socket) do
    status = socket.assigns[:history_status] || :all
    assign(socket, :history, Dispatch.list_orders(status: status, limit: 50))
  end

  @spec interval_or_default(term()) :: pos_integer()
  defp interval_or_default(value) when is_integer(value) and value > 0, do: value
  defp interval_or_default(_value), do: @default_flush_interval_ms

  @spec rows(index()) :: [DriverState.t()]
  defp rows(drivers) do
    drivers |> Map.values() |> Enum.sort_by(& &1.driver_id)
  end

  @spec online_count(index()) :: non_neg_integer()
  defp online_count(drivers) do
    Enum.count(Map.values(drivers), &(&1.status == :online))
  end

  @spec pending_count([Order.t()]) :: non_neg_integer()
  def pending_count(orders) do
    Enum.count(orders, &(&1.status == :pending))
  end

  @spec position(Types.coordinates() | nil) :: String.t()
  defp position(nil), do: "—"
  defp position({lat, lng}), do: "#{Float.round(lat, 5)}, #{Float.round(lng, 5)}"

  @spec order_point(float() | nil, float() | nil) :: String.t()
  defp order_point(nil, _lng), do: "—"
  defp order_point(_lat, nil), do: "—"
  defp order_point(lat, lng), do: "#{Float.round(lat, 4)}, #{Float.round(lng, 4)}"

  @spec speed(float() | nil) :: String.t()
  defp speed(nil), do: "—"
  defp speed(kmh), do: "#{Float.round(kmh, 1)} km/h"

  @spec seen(DateTime.t() | nil) :: String.t()
  defp seen(nil), do: "—"
  defp seen(at), do: Calendar.strftime(at, "%H:%M:%S")

  @spec when_at(DateTime.t() | nil) :: String.t()
  defp when_at(nil), do: "—"
  defp when_at(at), do: Calendar.strftime(at, "%d %b %H:%M")

  @spec to_status_filter(String.t()) :: Order.status() | :all
  defp to_status_filter("pending"), do: :pending
  defp to_status_filter("assigned"), do: :assigned
  defp to_status_filter("picked_up"), do: :picked_up
  defp to_status_filter("delivered"), do: :delivered
  defp to_status_filter("cancelled"), do: :cancelled
  defp to_status_filter(_status), do: :all
end
