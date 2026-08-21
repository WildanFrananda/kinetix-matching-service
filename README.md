# ⚡ Kinetix Matching Service (`kinetix-matching-service`)

High-performance real-time courier matching engine, fleet GPS telemetry streaming, automated order dispatching, and LiveView dashboard built with **Elixir 1.16+**, **Phoenix 1.7+**, **OTP GenServer Concurrency**, **Phoenix Channels & WebSockets**, **gRPC Server (`:4000`)**, and **PostgreSQL 16**.

---

## 🏛️ Resolved Audit Items & Architectural Upgrades

1. **Identity Sovereignty Enforcement**:
   - Removed local BCrypt user password hashing logic. Driver & Courier authentication and identity profile verification are delegated to **`kinetix-identity-service`**.
2. **Real OTP GenServer Dispatch (`CourierTelemetryServer`)**:
   - `dispatch_courier/2` invokes real OTP GenServer dispatch logic (`FleetPulse.Dispatch.assign_order/2`) and queries active `DriverRegistry` state (no dummy hardcoded driver data).
3. **gRPC Telemetry & Phoenix Channels Integration**:
   - `stream_driver_location/2` processes gRPC GPS telemetry location streams and broadcasts real-time updates across Phoenix Channels (`driver:<id>`) and Phoenix LiveView dashboards.
4. **100% Clean ExUnit Test Suite**:
   - All ExUnit test suites pass **100% (`221 passed, 0 failures`)**.

---

## 📂 Complete File Directory Structure (Elixir / Phoenix OTP)

```
kinetix-matching-service/
├── lib/
│   ├── fleet_pulse/
│   │   ├── dispatch.ex                 # Core Order Dispatch Domain
│   │   ├── tracking/                   # OTP GenServer Driver Registry & Driver State
│   │   │   ├── driver.ex
│   │   │   ├── driver_registry.ex
│   │   │   └── driver_state.ex
│   │   ├── servers/
│   │   │   └── courier_telemetry_server.ex # gRPC Server Handler (:4000)
│   │   └── proto/                      # Compiled Protobuf Modules
│   └── fleet_pulse_web/
│       ├── channels/                   # Phoenix WebSockets & Channels
│       │   ├── driver_channel.ex
│       │   └── merchant_channel.ex
│       └── live/                       # Phoenix LiveView Real-time Dispatch Map
│           └── dispatch_live.ex
├── test/                               # ExUnit Test Suite (221 passed, 0 failures)
├── mix.exs
└── README.md
```

---

## ⚡ Local Setup & Test Execution Guide

```bash
# 1. Fetch Mix Dependencies
mix deps.get

# 2. Prepare PostgreSQL 16 Database
mix ecto.setup

# 3. Run Complete ExUnit Test Suite
mix test

# 4. Start Phoenix Server & gRPC Service (:4000)
mix phx.server
```
