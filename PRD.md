# Product Requirement Document (PRD): FleetPulse

**High-Frequency Driver Tracking & Dispatch Engine**

---

## 1. Executive Summary

FleetPulse is a specialized, real-time driver tracking and dispatch engine built specifically for last-mile logistics and niche courier fleets. Traditional dispatch systems struggle with high-frequency GPS pinging, leading to database bottlenecks and delayed routing. FleetPulse leverages the Elixir/Phoenix ecosystem to handle concurrent WebSocket connections at scale. By maintaining driver state in-memory and utilizing Phoenix LiveView, FleetPulse delivers ultra-low latency tracking and interactive dispatch dashboards directly from the server, eliminating the need for a separate frontend SPA infrastructure.

---

## 2. Problem Statement

Niche logistics providers (e.g., medical supplies, sensitive cargo, local taxi services) require precise, real-time visibility of their fleet. Existing solutions face significant challenges:

- **Database Strain:** Updating a database table every 3 seconds for 1000+ drivers quickly exhausts connection pools and I/O resources.
- **Latency in Dispatch:** Delayed location updates result in suboptimal assignments and higher customer wait times.
- **Admin Dashboard Complexity:** Building and maintaining a separate React/Vue frontend to handle real-time WebSockets for the dispatch operator adds unnecessary overhead and sync issues.
- **Connection Overhead:** Managing thousands of persistent, concurrent connections from mobile devices drains resources on traditional stateless architectures.

---

## 3. Product Vision

To provide a highly resilient, low-latency tracking and dispatch backend that acts as the "nervous system" for specialized fleet operations. It seamlessly integrates driver telemetry via mobile apps and provides a robust, real-time operational dashboard for dispatchers using Phoenix LiveView.

---

## 4. Target Market

- **Primary:** Local / Regional last-mile delivery startups (groceries, rapid commerce).
- **Secondary:** Specialized courier fleets (medical transport, sensitive/high-value cargo).
- **Tertiary:** Mid-sized regional taxi or ride-hailing operators.

---

## 5. Core Features & Requirements

### 5.1. Real-Time Telemetry Ingestion (Driver App)

- **High-Frequency Pings:** System handles GPS coordinate updates (latitude, longitude, speed, bearing, timestamp) from native mobile driver apps every 3–5 seconds.
- **Tech Enabler:** Utilize Phoenix Channels / WebSockets for persistent connections with the driver's device.

### 5.2. In-Memory Fleet State Management

- **Ephemeral Storage:** Current driver locations and availability status (online, busy, offline) are held in memory.
- **Historical Batching:** The system batches location data and persists it to the database (PostgreSQL) periodically (e.g., every 30–60 seconds) for auditing and analytics.
- **Tech Enabler:** Each active driver is represented by a GenServer process. A Registry maps the Driver ID to the corresponding process, updating state instantly without DB writes.

### 5.3. Geofencing & Spatial Queries

- **Real-Time Proximity:** Instantly query "Which drivers are within a 3km radius of coordinates X, Y?"
- **Tech Enabler:** Utilize in-memory spatial indexing (e.g., ETS tables) for immediate dispatch queries, falling back to PostGIS for complex zone boundaries.

### 5.4. LiveView Dispatch Dashboard (Admin Client)

- **Live Map View:** Dispatch operators view a real-time, moving map of all active drivers without page reloads or polling.
- **Instant Interaction:** Operators can click on a driver to assign manual orders, with changes reflecting instantly.
- **Tech Enabler:** Phoenix LiveView connects directly to the server's internal state (via Phoenix PubSub). As GenServer driver states update, LiveView pushes differential DOM updates to the dispatcher's browser automatically.

### 5.5. Intelligent Dispatch Engine

- **Algorithmic Routing:** Evaluate available drivers based on proximity and load capacity to assign incoming orders.
- **Broadcast Assignment:** Instantly push order details to the selected driver via the active WebSocket connection.

---

## 6. Architecture & Elixir Implementation Details (Clean Code Approach)

This system will strictly adhere to Phoenix Contexts, separating domain logic from web delivery.

### 6.1. System Contexts

- **`FleetPulse.Tracking` Context:** Manages telemetry ingestion, GenServer driver state processes, and geofencing.
- **`FleetPulse.Dispatch` Context:** Handles order assignment logic and evaluates driver availability.
- **`FleetPulseWeb` (Web Layer):**
  - *Endpoint & Channels:* Handles mobile app WebSocket connections.
  - *Live (LiveView Modules):* Manages the real-time Admin/Dispatcher dashboard UI.

### 6.2. Architecture Flow

1. **Mobile App (Driver)** → Sends GPS via → **Phoenix Channel**
2. **Phoenix Channel** → Updates state in → **Driver GenServer**
3. **Driver GenServer** → Broadcasts new location via → **Phoenix PubSub**
4. **Admin Dashboard (LiveView)** → Subscribed to PubSub, receives update → Pushes minimal HTML diff to the Dispatcher's browser

---

## 7. Metrics for Success

- **Latency:** End-to-end latency from driver ping to Dispatcher dashboard update under 100ms.
- **Throughput:** Sustain 10,000+ concurrent driver connections updating every 5 seconds on a single node.
- **Development Velocity:** Reduce administrative UI development time by 50% by avoiding a separate SPA architecture.

---

## 8. Out of Scope (For V1)

- Complex Turn-by-Turn Navigation (integrate with Mapbox SDK on client instead).
- Billing and Payment Processing.

---

## 9. Phase 2 Roadmap (Post-V1)

V1 delivers the core loop — telemetry ingestion, in-memory fleet state,
proximity dispatch with atomic claim, the real-time LiveView dashboard, the
driver channel, and driver auth/registration. Phase 2 closes remaining
behavioural gaps and hardens the system for production. Items are prioritised;
`P0` is executed first.

### 9.1. Automatic Re-Dispatch of Pending Orders — **P0 (next)**

**Problem.** An order created when no eligible driver is in range returns
`no_driver_available` and then sits `pending` **forever** — nothing ever
re-attempts it. This is a real behavioural gap, not polish: the "intelligent
dispatch" of 5.5 is incomplete without it.

**Solution.** A supervised process subscribes to fleet driver-state changes on
the `tracking:fleet` PubSub topic. When a driver becomes available (goes
`online`, or is freed after a delivery), it re-attempts the oldest pending
orders whose pickup is within range of that driver, using the existing
`Dispatch.assign_order/2`. No polling — it reacts to the same broadcasts the
dashboard already consumes.

**Behaviour.** Order in → no driver nearby → stays `pending` → a courier comes
online within range → the order is **auto-assigned and pushed to their device**.

**Notes.** Reuses `Dispatch.assign_order/2` (atomic claim already prevents
double-assignment) and the `dispatch:orders` broadcast (the dashboard updates
live). Must avoid a thundering-herd re-attempt when many drivers connect at
once; bound the work per event.

### 9.2. Business Observability (Telemetry & Metrics) — P1

**Problem.** The system exposes VM/Phoenix/DB metrics but **zero business
metrics**: orders per minute, average time-to-assign, active drivers,
`no_driver_available` rate, delivery success. You cannot operate what you
cannot see.

**Solution.** Emit `:telemetry` events at domain checkpoints (order created,
assigned, picked up, delivered, cancelled, dispatch failed) and surface them as
metrics in the existing `FleetPulseWeb.Telemetry` / LiveDashboard.

### 9.3. Rate Limiting on Public Auth Endpoints — P1

**Problem.** `POST /driver/register` and `POST /driver/session` are public and
unthrottled — open to registration spam and credential stuffing.

**Solution.** Per-IP and per-phone rate limiting (fixed window or token bucket)
on both endpoints, returning `429 Too Many Requests` when exceeded.

### 9.4. Location History Retention — P2

**Problem.** `location_pings` is append-only and grows without bound
(~3 GB/day at the PRD's target scale).

**Solution.** A periodic job that prunes pings older than a configurable
retention window (e.g. 30 days), keeping the audit trail bounded.

### 9.5. Merchant API & Real-Time WebSocket Integration — P0 (Next Feature)

**Problem.** Currently, order creation is restricted to internal dispatchers via the Admin LiveView interface. External merchant applications cannot programmatically place delivery orders or track their active orders in real-time.

**Solution.** Expose a dedicated Merchant API suite & Phoenix WebSocket Channel (`MerchantChannel`) to enable multi-tenant merchant applications to seamlessly integrate with FleetPulse:

1. **Merchant Authentication & Schema Multi-Tenancy:**
   - Extend `Order` schema to include `merchant_id` for strict multi-tenant isolation.
   - Merchant authentication via API Key / Bearer tokens tied to specific merchant accounts.

2. **Order Intake REST Endpoint (`POST /api/v1/merchant/orders`):**
   - Accept order payload (pickup coords, dropoff coords, weight_kg, merchant_order_ref).
   - Trigger atomic order creation & automatic dispatch evaluation (`FleetPulse.Dispatch.create_order/1`).

3. **Real-Time Merchant Phoenix Channel (`merchant:orders:<merchant_id>`):**
   - Establish persistent WebSockets for real-time bidirectional status updates.
   - Stream live order status transitions (`pending` → `assigned` → `picked_up` → `delivered` / `cancelled`).
   - Push driver telemetry updates (driver position & ETA) while an order is actively assigned to a merchant's package.

### Explicitly deferred (no concrete demand yet)

- PostGIS polygon service zones (radius + haversine over ETS suffices today).
- Multi-order queue per driver (one active order per driver is enough for V1).
- ETA display and map-marker click-to-assign (UI polish, not new capability).
- Customer-facing mobile applications (focus is on Driver App and Admin Dashboard).