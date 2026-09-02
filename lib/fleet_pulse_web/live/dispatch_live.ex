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

  def handle_event("select_driver", %{"id" => id}, socket) when is_binary(id) do
    {:noreply, select_driver(socket, String.to_integer(id))}
  end

  def handle_event("close_driver", _params, socket) do
    {:noreply, assign(socket, :selected, nil)}
  end

  def handle_event(
        "assign_to_driver",
        %{"driver_id" => driver_id, "order_id" => order_id},
        socket
      )
      when is_binary(driver_id) and is_binary(order_id) do
    did = String.to_integer(driver_id)

    flashed =
      case Dispatch.assign_order_to_driver(String.to_integer(order_id), did) do
        {:ok, order} -> put_flash(socket, :info, "Order ##{order.id} → driver ##{did}.")
        {:error, :unavailable} -> put_flash(socket, :error, "Driver is not available.")
        {:error, _reason} -> put_flash(socket, :error, "Could not assign the order.")
      end

    {:noreply, flashed |> assign_orders() |> assign_history() |> select_driver(did)}
  end

  @impl Phoenix.LiveView
  @spec render(map()) :: Rendered.t()
  def render(assigns) do
    ~H"""
    <div class="min-h-screen bg-slate-950 text-slate-100 font-sans antialiased selection:bg-indigo-500 selection:text-white">
      <%!-- Top Glassmorphism Navigation Bar --%>
      <header class="sticky top-0 z-40 w-full border-b border-slate-800/80 bg-slate-900/80 backdrop-blur-xl px-6 py-3 shadow-2xl shadow-slate-950/50">
        <div class="mx-auto flex max-w-7xl items-center justify-between">
          <div class="flex items-center gap-3">
            <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-gradient-to-tr from-indigo-600 to-violet-500 text-white shadow-lg shadow-indigo-500/30">
              <span class="text-xl">🛰️</span>
            </div>
            <div>
              <div class="flex items-center gap-2">
                <h1 class="bg-gradient-to-r from-cyan-400 via-indigo-300 to-purple-400 bg-clip-text text-xl font-extrabold tracking-tight text-transparent">
                  FleetPulse Dispatch
                </h1>
                <span class="rounded-full bg-indigo-500/10 border border-indigo-500/30 px-2 py-0.5 text-[10px] font-bold text-indigo-400 tracking-wider uppercase">
                  Enterprise
                </span>
              </div>
              <p class="text-xs text-slate-400">
                High-Frequency Telemetry & Autonomous Routing Engine
              </p>
            </div>
          </div>

          <div class="flex items-center gap-5">
            <div class="hidden sm:flex items-center gap-2 rounded-full border border-emerald-500/20 bg-emerald-500/10 px-3 py-1 text-xs font-semibold text-emerald-400 shadow-inner">
              <span class="relative flex h-2 w-2">
                <span class="animate-ping absolute inline-flex h-full w-full rounded-full bg-emerald-400 opacity-75"></span>
                <span class="relative inline-flex h-2 w-2 rounded-full bg-emerald-500"></span>
              </span>
              LIVE ENGINE ACTIVE
            </div>

            <div class="flex items-center gap-3 border-l border-slate-800 pl-5">
              <div class="flex h-8 w-8 items-center justify-center rounded-full bg-slate-800 font-semibold text-xs text-indigo-300 ring-2 ring-indigo-500/30">
                {String.at(@current_admin.email, 0) |> String.upcase()}
              </div>
              <span class="hidden md:inline text-xs font-medium text-slate-300">{@current_admin.email}</span>
              <.link
                href={~p"/admin/log_out"}
                method="delete"
                class="rounded-lg border border-slate-700/80 bg-slate-800/50 px-3 py-1.5 text-xs font-medium text-slate-300 transition-all hover:bg-slate-700 hover:text-white hover:border-slate-600
    active:scale-95"
              >
                Log out
              </.link>
            </div>
          </div>
        </div>
      </header>

      <Layouts.flash_group flash={@flash} />

      <main class="mx-auto max-w-7xl px-6 py-8 space-y-8">
        <%!-- KPI Stat Grid --%>
        <div class="grid grid-cols-1 gap-5 sm:grid-cols-2 lg:grid-cols-4">
          <div class="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/60 p-5 shadow-xl backdrop-blur-xl transition-all duration-300 hover:border-cyan-500/40 hover:shadow-
    cyan-950/20">
            <div class="flex items-center justify-between text-slate-400">
              <span class="text-xs font-semibold uppercase tracking-wider">Drivers online</span>
              <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-cyan-500/10 text-cyan-400">
                ⚡
              </div>
            </div>
            <div class="mt-3 flex items-baseline gap-2">
              <span class="text-3xl font-black text-white tabular-nums tracking-tight">{online_count(
                @drivers
              )}</span>
              <span class="text-xs font-medium text-slate-400">/ {map_size(@drivers)} tracked</span>
            </div>
            <div class="mt-2 h-1.5 w-full overflow-hidden rounded-full bg-slate-800">
              <div
                class="h-full bg-gradient-to-r from-cyan-500 to-blue-500"
                style={"width: #{if map_size(@drivers) > 0, do: (online_count(@drivers) / map_size(@drivers) * 100), else: 0}%"}
              >
              </div>
            </div>
          </div>

          <div class="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/60 p-5 shadow-xl backdrop-blur-xl transition-all duration-300 hover:border-indigo-500/40 hover:shadow-
    indigo-950/20">
            <div class="flex items-center justify-between text-slate-400">
              <span class="text-xs font-semibold uppercase tracking-wider">Active Orders</span>
              <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-indigo-500/10 text-indigo-400">
                📦
              </div>
            </div>
            <div class="mt-3 text-3xl font-black text-white tabular-nums tracking-tight">
              {length(@orders)}
            </div>
            <p class="mt-1 text-xs text-slate-400">In-flight delivery load</p>
          </div>

          <div class="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/60 p-5 shadow-xl backdrop-blur-xl transition-all duration-300 hover:border-amber-500/40 hover:shadow-
    amber-950/20">
            <div class="flex items-center justify-between text-slate-400">
              <span class="text-xs font-semibold uppercase tracking-wider">Waiting Assign</span>
              <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-amber-500/10 text-amber-400">
                ⏳
              </div>
            </div>
            <div class="mt-3 text-3xl font-black text-amber-400 tabular-nums tracking-tight">
              {pending_count(@orders)}
            </div>
            <p class="mt-1 text-xs text-slate-400">Pending auto/manual dispatch</p>
          </div>

          <div class="relative overflow-hidden rounded-2xl border border-slate-800 bg-slate-900/60 p-5 shadow-xl backdrop-blur-xl transition-all duration-300 hover:border-emerald-500/40 hover:shadow-
    emerald-950/20">
            <div class="flex items-center justify-between text-slate-400">
              <span class="text-xs font-semibold uppercase tracking-wider">Delivered today</span>
              <div class="flex h-8 w-8 items-center justify-center rounded-lg bg-emerald-500/10 text-emerald-400">
                ✅
              </div>
            </div>
            <div class="mt-3 text-3xl font-black text-emerald-400 tabular-nums tracking-tight">
              {@delivered_today}
            </div>
            <p class="mt-1 text-xs text-slate-400">Completed jobs today</p>
          </div>
        </div>

        <%!-- Live Telemetry Map Container --%>
        <div class="relative overflow-hidden rounded-3xl border border-slate-800 bg-slate-900/80 shadow-2xl backdrop-blur-2xl">
          <div class="flex items-center justify-between border-b border-slate-800/80 px-6 py-4">
            <div class="flex items-center gap-2">
              <div class="h-2.5 w-2.5 rounded-full bg-cyan-400 animate-ping"></div>
              <h2 class="text-sm font-bold uppercase tracking-wider text-slate-200">
                Live Spatial Map (CARTO Dark)
              </h2>
            </div>
            <div class="text-xs text-slate-400">Real-time driver markers broadcasted via PubSub</div>
          </div>
          <div
            id="fleet-map-container"
            phx-hook=".FleetMap"
            phx-update="ignore"
            class="h-[520px] w-full bg-slate-950"
          >
          </div>
        </div>

        <script :type={Phoenix.LiveView.ColocatedHook} name=".FleetMap">
          import L from "leaflet"

          export default {
            mounted() {
              this.map = L.map(this.el).setView([-6.3000, 106.8456], 12)
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
                    const marker = L.circleMarker(latLng, {
                      radius: 8,
                      fillColor: driver.status === 'online' ? '#10b981' : (driver.status === 'busy' ? '#f59e0b' : '#64748b'),
                      color: '#ffffff',
                      weight: 2,
                      opacity: 1,
                      fillOpacity: 0.9
                    })
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
                <div class="p-2 text-slate-900 font-sans min-w-[140px]">
                  <div class="font-bold text-sm text-slate-900">🚚 Driver #${driver.id}</div>
                  <div class="text-xs text-slate-600 mt-1">Status: <span class="font-bold uppercase text-indigo-600">${driver.status}</span></div>
                  <div class="text-xs text-slate-600">Speed: <span class="font-semibold text-slate-800">${speed} km/h</span></div>
                </div>
              `
            }
          }
        </script>

        <%!-- Order Dispatch & Creation Section --%>
        <div class="rounded-3xl border border-slate-800 bg-slate-900/60 p-6 shadow-xl backdrop-blur-xl">
          <div class="mb-6 flex items-center justify-between border-b border-slate-800 pb-4">
            <div>
              <h2 class="text-lg font-bold text-white">Order Dispatch Management</h2>
              <p class="text-xs text-slate-400">
                Create new delivery orders or manually trigger immediate driver assignment.
              </p>
            </div>
            <span class="rounded-lg bg-indigo-500/10 border border-indigo-500/20 px-3 py-1 text-xs font-medium text-indigo-300">
              {length(@orders)} Active orders
            </span>
          </div>

          <.form
            for={@order_form}
            id="order-form"
            phx-submit="create_order"
            class="mb-8 grid grid-cols-1 gap-4 sm:grid-cols-2 lg:grid-cols-6 items-end rounded-2xl border border-slate-800/80 bg-slate-950/60 p-5"
          >
            <div>
              <label class="block text-xs font-semibold text-slate-300 mb-1">Pickup Lat</label>
              <.input
                field={@order_form[:pickup_latitude]}
                type="number"
                step="any"
                placeholder="-7.2088"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white
    placeholder-slate-500 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold text-slate-300 mb-1">Pickup Lng</label>
              <.input
                field={@order_form[:pickup_longitude]}
                type="number"
                step="any"
                placeholder="106.8100"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white
    placeholder-slate-500 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold text-slate-300 mb-1">Dropoff Lat</label>
              <.input
                field={@order_form[:dropoff_latitude]}
                type="number"
                step="any"
                placeholder="-7.2100"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white
    placeholder-slate-500 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold text-slate-300 mb-1">Dropoff Lng</label>
              <.input
                field={@order_form[:dropoff_longitude]}
                type="number"
                step="any"
                placeholder="106.8200"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white
    placeholder-slate-500 focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
              />
            </div>
            <div>
              <label class="block text-xs font-semibold text-slate-300 mb-1">Weight (kg)</label>
              <.input
                field={@order_form[:weight_kg]}
                type="number"
                placeholder="5.0"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white placeholder-slate-500
    focus:border-indigo-500 focus:outline-none focus:ring-1 focus:ring-indigo-500"
              />
            </div>
            <div>
              <button
                type="submit"
                class="w-full rounded-xl bg-gradient-to-r from-indigo-500 via-purple-500 to-pink-500 hover:from-indigo-600 hover:to-pink-600 px-4 py-2 text-xs font-bold text-white
    shadow-lg shadow-indigo-500/25 transition-all active:scale-95"
              >
                + Create Order
              </button>
            </div>
          </.form>

          <div class="overflow-x-auto rounded-2xl border border-slate-800 bg-slate-950/40">
            <.table id="orders" rows={@orders}>
              <:col :let={order} label="ID">
                <span class="font-mono text-xs font-bold text-indigo-400">#{order.id}</span>
              </:col>
              <:col :let={order} label="Status"><.status_badge status={order.status} /></:col>
              <:col :let={order} label="Pickup">
                <span class="font-mono text-xs text-slate-300">{order_point(
                  order.pickup_latitude,
                  order.pickup_longitude
                )}</span>
              </:col>
              <:col :let={order} label="Weight">
                <span class="text-xs font-medium text-slate-200">{order.weight_kg} kg</span>
              </:col>
              <:col :let={order} label="Assigned Driver">
                <span class="font-mono text-xs text-slate-300">{if order.driver_id,
                  do: "Driver ##{order.driver_id}",
                  else: "—"}</span>
              </:col>
              <:col :let={order} label="Actions">
                <div class="flex items-center gap-2">
                  <button
                    :if={order.status == :pending}
                    phx-click="assign_order"
                    phx-value-id={order.id}
                    class="rounded-lg bg-indigo-600/80 hover:bg-indigo-500 px-3 py-1 text-xs font-medium text-white shadow-sm transition-all"
                  >
                    Assign Now
                  </button>
                  <button
                    phx-click="cancel_order"
                    phx-value-id={order.id}
                    class="rounded-lg bg-rose-600/20 hover:bg-rose-600/40 border border-rose-500/30 px-3 py-1 text-xs font-medium text-rose-300 transition-all"
                  >
                    Cancel
                  </button>
                </div>
              </:col>
            </.table>
          </div>
        </div>

        <%!-- Active Fleet Drivers Section --%>
        <div class="rounded-3xl border border-slate-800 bg-slate-900/60 p-6 shadow-xl backdrop-blur-xl">
          <div class="mb-6 flex items-center justify-between border-b border-slate-800 pb-4">
            <div>
              <h2 class="text-lg font-bold text-white">Tracked Fleet Roster</h2>
              <p class="text-xs text-slate-400">
                Live positions and active statuses of all registered drivers.
              </p>
            </div>
            <span class="rounded-lg bg-cyan-500/10 border border-cyan-500/20 px-3 py-1 text-xs font-medium text-cyan-300">
              {map_size(@drivers)} Drivers Tracked
            </span>
          </div>

          <div class="overflow-x-auto rounded-2xl border border-slate-800 bg-slate-950/40">
            <.table id="drivers" rows={rows(@drivers)}>
              <:col :let={driver} label="Driver">
                <div class="flex items-center gap-2">
                  <span class="h-2 w-2 rounded-full bg-emerald-400"></span>
                  <span class="font-mono text-xs font-bold text-white">Driver #{driver.driver_id}</span>
                </div>
              </:col>
              <:col :let={driver} label="Status"><.status_badge status={driver.status} /></:col>
              <:col :let={driver} label="Active Jobs">
                <span class="rounded-full bg-indigo-500/10 border border-indigo-500/30 px-2 py-0.5 text-xs font-mono font-semibold text-indigo-300">
                  {active_count_badge(driver)}
                </span>
              </:col>
              <:col :let={driver} label="Coordinates">
                <span class="font-mono text-xs text-slate-300">{position(driver.coordinates)}</span>
              </:col>
              <:col :let={driver} label="Speed">
                <span class="font-mono text-xs font-semibold text-cyan-300">{speed(driver.speed_kmh)}</span>
              </:col>
              <:col :let={driver} label="Last Ping">
                <span class="text-xs text-slate-400">{seen(driver.synced_at)}</span>
              </:col>
              <:col :let={driver} label="">
                <button
                  phx-click="select_driver"
                  phx-value-id={driver.driver_id}
                  class="rounded-lg border border-slate-700 bg-slate-800/70 hover:bg-slate-700 px-3 py-1 text-xs font-medium text-slate-200 transition-all"
                >
                  View Details
                </button>
              </:col>
            </.table>
          </div>
        </div>

        <%!-- Selected Driver Detail Modal/Card --%>
        <div
          :if={@selected}
          class="rounded-3xl border border-indigo-500/40 bg-slate-900/90 p-6 shadow-2xl shadow-indigo-500/10 backdrop-blur-2xl animate-fade-in"
        >
          <div class="flex items-center justify-between mb-6 border-b border-slate-800 pb-4">
            <div class="flex items-center gap-3">
              <div class="flex h-10 w-10 items-center justify-center rounded-xl bg-indigo-500/20 text-indigo-400 font-bold">
                🚚
              </div>
              <div>
                <h3 class="text-lg font-bold text-white">
                  Driver #{@selected.record.id} — {@selected.record.name}
                </h3>
                <p class="text-xs text-slate-400">Phone: {@selected.record.phone}</p>
              </div>
            </div>
            <button
              phx-click="close_driver"
              class="rounded-lg border border-slate-700 bg-slate-800 px-3 py-1.5 text-xs font-medium text-slate-300 hover:bg-slate-700"
            >Close</button>
          </div>

          <div class="grid grid-cols-2 gap-4 sm:grid-cols-4 mb-6">
            <div class="rounded-2xl border border-slate-800 bg-slate-950/60 p-4">
              <div class="text-xs text-slate-400">Vehicle Plate</div>
              <div class="font-mono text-sm font-bold text-white mt-1">
                {@selected.record.vehicle_plate}
              </div>
            </div>
            <div class="rounded-2xl border border-slate-800 bg-slate-950/60 p-4">
              <div class="text-xs text-slate-400">Payload Capacity</div>
              <div class="text-sm font-bold text-white mt-1">{@selected.record.capacity_kg} kg</div>
            </div>
            <div class="rounded-2xl border border-slate-800 bg-slate-950/60 p-4">
              <div class="text-xs text-slate-400">Queue Load</div>
              <div class="text-sm font-mono font-bold text-indigo-300 mt-1">
                {if @selected.state,
                  do: "#{@selected.state.active_orders_count}/#{@selected.state.max_orders} Jobs",
                  else: "0 Jobs"}
              </div>
            </div>
            <div class="rounded-2xl border border-slate-800 bg-slate-950/60 p-4">
              <div class="text-xs text-slate-400">Current Position</div>
              <div class="font-mono text-xs font-medium text-slate-200 mt-1">
                {driver_position(@selected.state)}
              </div>
            </div>
          </div>

          <%!-- Multi-Order Queue List --%>
          <div :if={@selected.orders != []} class="space-y-3 mb-6">
            <div class="text-xs font-bold uppercase tracking-wider text-indigo-400">
              Active Assigned Orders ({length(@selected.orders)})
            </div>
            <div
              :for={order <- @selected.orders}
              class="flex items-center justify-between rounded-2xl border border-indigo-500/30 bg-indigo-500/10 p-4"
            >
              <div>
                <div class="text-sm font-bold text-white">Order #{order.id}</div>
                <div class="text-xs text-slate-300">
                  Weight: <span class="font-bold">{order.weight_kg} kg</span>
                </div>
              </div>
              <.status_badge status={order.status} />
            </div>
          </div>

          <form
            :if={
              @selected.record.status == :online and
                (@selected.state == nil or
                   @selected.state.active_orders_count < @selected.state.max_orders)
            }
            phx-submit="assign_to_driver"
            class="flex items-end gap-3 rounded-2xl border border-slate-800 bg-slate-950/60 p-4"
          >
            <input type="hidden" name="driver_id" value={@selected.record.id} />
            <div class="flex-1">
              <label class="block text-xs font-semibold text-slate-300 mb-1">Assign Pending Order</label>
              <select
                name="order_id"
                class="w-full rounded-xl border border-slate-800 bg-slate-900 px-3 py-2 text-xs text-white focus:border-indigo-500 focus:outline-none"
              >
                <option :for={o <- pending_orders(@orders)} value={o.id}>
                  Order #{o.id} — {o.weight_kg} kg
                </option>
              </select>
            </div>
            <button
              type="submit"
              class="rounded-xl bg-indigo-600 hover:bg-indigo-500 px-4 py-2 text-xs font-bold text-white shadow-lg transition-all"
            >
              Direct Assign
            </button>
          </form>
        </div>

        <%!-- Order History Section --%>
        <div class="rounded-3xl border border-slate-800 bg-slate-900/60 p-6 shadow-xl backdrop-blur-xl">
          <div class="mb-6 flex items-center justify-between border-b border-slate-800 pb-4">
            <div>
              <h2 class="text-lg font-bold text-white">Order Audit History</h2>
              <p class="text-xs text-slate-400">Historical delivery log and state transitions.</p>
            </div>
            <form id="history-form" phx-change="filter_history">
              <select
                name="status"
                class="rounded-xl border border-slate-800 bg-slate-950 px-3 py-1.5 text-xs text-slate-200 focus:border-indigo-500 focus:outline-none"
              >
                <option value="all" selected={@history_status == :all}>All Statuses</option>
                <option value="pending" selected={@history_status == :pending}>Pending</option>
                <option value="assigned" selected={@history_status == :assigned}>Assigned</option>
                <option value="picked_up" selected={@history_status == :picked_up}>Picked up</option>
                <option value="delivered" selected={@history_status == :delivered}>Delivered</option>
                <option value="cancelled" selected={@history_status == :cancelled}>Cancelled</option>
              </select>
            </form>
          </div>

          <div class="overflow-x-auto rounded-2xl border border-slate-800 bg-slate-950/40">
            <.table id="history" rows={@history}>
              <:col :let={order} label="Order ID">
                <span class="font-mono text-xs font-bold text-indigo-400">#{order.id}</span>
              </:col>
              <:col :let={order} label="Status"><.status_badge status={order.status} /></:col>
              <:col :let={order} label="Driver">
                <span class="font-mono text-xs text-slate-300">{if order.driver_id,
                  do: "Driver ##{order.driver_id}",
                  else: "—"}</span>
              </:col>
              <:col :let={order} label="Weight">
                <span class="text-xs font-medium text-slate-200">{order.weight_kg} kg</span>
              </:col>
              <:col :let={order} label="Created At">
                <span class="text-xs text-slate-400">{when_at(order.inserted_at)}</span>
              </:col>
            </.table>
          </div>
        </div>

        <%!-- Pending Drivers Approval Banner --%>
        <div
          :if={length(@pending_approval) > 0}
          class="rounded-3xl border border-amber-500/30 bg-amber-500/5 p-6 shadow-xl backdrop-blur-xl"
        >
          <div class="mb-4 flex items-center justify-between border-b border-amber-500/20 pb-3">
            <h2 class="text-base font-bold text-amber-300">
              ⚠️ Drivers Pending Verification ({length(@pending_approval)})
            </h2>
            <span class="text-xs text-amber-400/80">Requires admin approval to access dispatch network</span>
          </div>

          <div class="overflow-x-auto rounded-2xl border border-slate-800 bg-slate-950/60">
            <.table id="pending-drivers" rows={@pending_approval}>
              <:col :let={driver} label="Name">
                <span class="text-xs font-bold text-white">{driver.name}</span>
              </:col>
              <:col :let={driver} label="Phone">
                <span class="font-mono text-xs text-slate-300">{driver.phone}</span>
              </:col>
              <:col :let={driver} label="Plate">
                <span class="font-mono text-xs text-slate-300">{driver.vehicle_plate}</span>
              </:col>
              <:col :let={driver} label="Capacity">
                <span class="text-xs font-medium text-slate-200">{driver.capacity_kg} kg</span>
              </:col>
              <:col :let={driver} label="Actions">
                <div class="flex items-center gap-2">
                  <button
                    phx-click="approve_driver"
                    phx-value-id={driver.id}
                    class="rounded-lg bg-emerald-600/80 hover:bg-emerald-500 px-3 py-1 text-xs font-bold text-white shadow-sm transition-all"
                  >
                    Approve
                  </button>
                  <button
                    phx-click="reject_driver"
                    phx-value-id={driver.id}
                    class="rounded-lg bg-rose-600/30 hover:bg-rose-600/50 border border-rose-500/30 px-3 py-1 text-xs font-bold text-rose-300 transition-all"
                  >
                    Reject
                  </button>
                </div>
              </:col>
            </.table>
          </div>
        </div>
      </main>
    </div>
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
    |> assign(:selected, nil)
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

  @spec select_driver(Socket.t(), Types.id()) :: Socket.t()
  defp select_driver(socket, driver_id) do
    case Tracking.fetch_driver(driver_id) do
      {:ok, record} ->
        assign(socket, :selected, %{
          record: record,
          state: driver_state(driver_id),
          order: Dispatch.active_order_for_driver(driver_id),
          orders: Dispatch.active_orders_for_driver(driver_id)
        })

      {:error, :not_found} ->
        put_flash(socket, :error, "Driver not found.")
    end
  end

  @spec active_count_badge(DriverState.t()) :: String.t()
  defp active_count_badge(%DriverState{active_orders_count: count, max_orders: max_orders}) do
    "#{count}/#{max_orders} Jobs"
  end

  defp active_count_badge(_state), do: "0/1 Jobs"

  @spec driver_state(Types.id()) :: DriverState.t() | nil
  defp driver_state(driver_id) do
    case Tracking.fetch_state(driver_id) do
      {:ok, state} -> state
      {:error, :not_found} -> nil
    end
  end

  @spec driver_position(DriverState.t() | nil) :: String.t()
  defp driver_position(nil), do: "—"
  defp driver_position(%DriverState{coordinates: coords}), do: position(coords)

  @spec pending_orders([Order.t()]) :: [Order.t()]
  defp pending_orders(orders), do: Enum.filter(orders, &(&1.status == :pending))

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
