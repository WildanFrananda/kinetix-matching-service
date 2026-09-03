# ⚡ Kinetix Matching Service (`kinetix-matching-service`)

High-performance real-time courier matching engine, fleet GPS telemetry streaming, automated order dispatching, and LiveView dashboard built with **Elixir 1.16+**, **Phoenix 1.7+**, **OTP GenServer Concurrency**, **Phoenix Channels & WebSockets**, **gRPC Server (`:50053`)**, and **PostgreSQL 16**.

---

## 🏛️ Resolved Audit Upgrades & Production Hardening

1. **Dependency Vulnerability Remediation**:
   - Upgraded Hex dependencies (`bandit 1.12.5`, `postgrex 0.22.4`, `phoenix 1.8.12`, `ecto 3.14.2`), patching Critical Remote Code Execution (RCE) and High Denial of Service (DoS) advisories.
2. **OTP Supervision Tree & Active gRPC Server (`:50053`)**:
   - Configured `FleetPulse.GrpcEndpoint` and registered `{GRPC.Server.Supervisor, endpoint: FleetPulse.GrpcEndpoint, port: 50053}` in `FleetPulse.Application` OTP children list so the gRPC server actively listens on port `:50053`.
3. **Single Source of Truth Identity Integration**:
   - `FleetPulse.Clients.IdentityClient` connects to `kinetix-identity-service:50052` for driver token validation and profile lookup, resolving identity sovereignty violations.
4. **Clean Driver Telemetry Data (No Hardcoded Fallbacks)**:
   - Removed hardcoded fallback strings `"081299887766"` and `"B 1234 KIN"` from `FleetPulse.CourierTelemetryServer`.
5. **100% ExUnit Test Suite Verification**:
   - Executed `mix test` ➔ **`221 passed, 0 failures (100% Passed)`**.

---

## 📂 Complete Repository Directory Structure

```
kinetix-matching-service/
├── lib/
│   ├── fleet_pulse/
│   │   ├── application.ex              # OTP Application Supervision Tree
│   │   ├── grpc_endpoint.ex            # gRPC Endpoint Configuration (:50053)
│   │   ├── dispatch.ex                 # Core Order Dispatch Domain
│   │   ├── tracking/                   # OTP GenServer Driver Registry & State
│   │   │   ├── driver.ex
│   │   │   ├── driver_registry.ex
│   │   │   └── driver_state.ex
│   │   ├── clients/
│   │   │   └── identity_client.ex      # gRPC Identity Client (:50052)
│   │   ├── servers/
│   │   │   └── courier_telemetry_server.ex # gRPC Courier Telemetry Handler
│   │   └── proto/                      # Protobuf Modules
│   └── fleet_pulse_web/
│       ├── channels/                   # Phoenix WebSockets & Channels
│       │   ├── driver_channel.ex
│       │   └── merchant_channel.ex
│       └── live/                       # Phoenix LiveView Real-time Map
│           └── dispatch_live.ex
├── test/                               # ExUnit Test Suite (221 passed, 0 failures)
├── mix.exs
└── README.md
```

---

## ⚡ Local Execution & Verification Commands

```bash
# 1. Run ExUnit Test Suite
mix test

# 2. Start Phoenix Server & gRPC Service (:50053)
mix phx.server
```
