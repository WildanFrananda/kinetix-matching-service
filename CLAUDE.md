# Enterprise Elixir & Phoenix Development Guide

## 🎯 Core Philosophy
This project strictly follows **Functional Programming** paradigms while maintaining **Enterprise Clean Architecture** standards (similar to patterns found in NestJS, Spring Boot, or Laravel). 
DO NOT force Object-Oriented Programming (OOP) patterns (classes, tight inheritance, state mutation) into this codebase.

## 1. Type Safety (Static Typing Simulation)
Although Elixir is dynamically typed, this project enforces strict type safety using **Typespecs** and **Dialyzer**.
- ALWAYS define `@type` for custom data structures (acting as TypeScript `interface` or Java `class` equivalents).
- ALWAYS use `@spec` to define function inputs and return types.
- Ensure all types are strictly validated before merging into the main branch.

```elixir
# Example of strict typing
@type t :: %__MODULE__{
  id: integer(),
  status: atom(),
  total: float()
}

@spec get_order(integer()) :: {:ok, t()} | {:error, :not_found}
```

## 2. Architecture: Phoenix Contexts (Domain-Driven Design)
Phoenix is treated strictly as the web delivery mechanism. Business logic MUST NOT reside in Controllers or Views.
- **`lib/app_web/` (Web Layer):** Contains Controllers, Routers, and JSON Views. Responsibilities are limited to parsing HTTP/Websocket requests and returning mapped responses.
- **`lib/app/` (Core/Domain Layer):** Contains **Contexts** (independent domain modules). This is the equivalent of the Service Layer.
- **`lib/app/repo.ex` (Data Layer):** Pure Ecto configurations and database interaction.

## 3. OOP to Elixir Equivalency Map
When translating enterprise OOP patterns to this project, adhere to these equivalencies:

| OOP Concept (Nest/Spring) | Elixir / Phoenix Pattern | Implementation Notes |
| :--- | :--- | :--- |
| **Interfaces** | `@behaviour` | Define contracts via `@callback`, implement using `@impl`. |
| **Dependency Injection** | App Config / Args | Pass module dependencies as function arguments or resolve via `Application.get_env/3` (useful for `Mox` testing). |
| **DTOs & Validation** | `Ecto.Changeset` | Use Changesets strictly for casting, validating, and filtering incoming data before it hits the domain logic. |
| **Entities / Models** | `Ecto.Schema` | Schemas are Pure Data Objects (PODO). They DO NOT contain `save()`, `update()`, or any behavioral methods. |
| **Repository / DAO** | `Ecto.Repo` + Context | Execute all database queries explicitly through the Repo module inside Context functions. |

## 4. Coding Standards & Best Practices
- **Error Handling:** Do not use `try/catch` or raise exceptions for standard control flow. Always return `{:ok, result}` and `{:error, reason}` tuples.
- **Control Flow:** Favor **Pattern Matching** at the function signature level over `if/else`, `cond`, or `switch` statements.
  ```elixir
  # ✅ Clean Elixir Code
  def process_payment(%{status: :paid} = payment), do: complete_order(payment)
  def process_payment(payment), do: handle_error(payment)
  ```
- **Data Transformation:** Utilize the pipe operator (`|>`) to sequence functional transformations. Avoid nested function calls or attempting "method chaining".
  ```elixir
  # ✅ Ecto Query standard
  Order
  |> where([o], o.status == :paid)
  |> order_by([o], desc: o.inserted_at)
  |> Repo.all()
  ```

## 5. Standard Mix Commands
- Start server: `mix phx.server`
- Type checking: `mix dialyzer`
- Run test suite: `mix test`
- Formatting: `mix format`

## 6. Decisions the code states but cannot explain

### A delivery is owed to order until order has recorded it

`Dispatch.mark_delivered` stores `delivered_at`, makes the report due at once and kicks `DeliveryReporter`,
which tells order outside the courier's reply (since 2026-10-21: the inline order call, up to 3 s + 8 s, could
outlast the app's 5 s push timeout). What does not go through is retried every minute, backing off a minute per
attempt up to an hour, with the time the parcel was actually delivered — order's `OrderDelivered` is
idempotent, so a repeat is answered as already recorded. Until 2026-10-13 the report was made once and a
failure was a log line: order never heard of the delivery, so the courier's fee was never settled, the return
window never started and the merchant was never paid. Only order's own refusal (`INVALID_ARGUMENT`, `NOT_FOUND`,
`FAILED_PRECONDITION`, `ALREADY_EXISTS`, `OUT_OF_RANGE`) stops the retrying; `UNAVAILABLE`,
`DEADLINE_EXCEEDED`, `PERMISSION_DENIED` and the rest mean order could not be asked, and every one of them
used to be reported as a refusal. The migration that added the columns queued every delivered job with an
order number, so a delivery order missed before is reported once more.

### A delivery needs a photo matching can see in the bucket, stored as the courier hashed it

`delivered` is refused without `pod_photo_url`, and the URL must name `pod/<this job's id>/<sha256>.jpg` in
the private `kinetix-pod` bucket, an object that is really there and whose stored checksum is the SHA-256 in its
name. The courier asks for an upload address over the channel (`pod_upload` with `photo_sha256`, lowercase hex,
only for a job they carry that is picked up); matching refuses one without the hash (`invalid_photo_hash`), and
signs a short-lived PUT for the public storage host (`OBJECT_STORE_PUBLIC_URL`) over `x-amz-checksum-sha256` and
`if-none-match: *`. The reply carries those headers as `upload_headers`, and the app sends exactly them: the store
then keeps only the bytes the courier hashed, refuses a second write to the key (`412`), and refuses a request
that leaves either header out. At `delivered` matching asks the object's checksum through the internal endpoint
(`HEAD` with `x-amz-checksum-mode: ENABLED`); an object that is absent, carries no checksum or carries another is
`invalid_proof`. If the bucket cannot be asked, the answer is `proof_unverifiable`, not a refusal: the courier
tries again. The object's first bytes, read with a ranged `GET`, must be a JPEG's (`FF D8 FF`): the store keeps
whatever bytes the courier hashed, so the checksum alone does not say they are a photo. The `HEAD` and the
`GET` each wait at most 1 s to connect and 1 s for an answer, so `delivered` answers inside the app's 5 s.
MinIO also accepted and enforced those headers unsigned (measured 2026-10-16), but whatever a store
does with them, only the signature stops a client from dropping them; `S3Test` fails if the upload address stops
signing them. The signature is required (`signature_required` without one, since 2026-10-21: AGENTS.md's
proof of delivery is photo and signature) and must be a PNG in a `data:image/png;base64,` URI, which is what
the app draws; a URL is not accepted, because matching cannot hash what a URL points to.

`pickup` and `delivered` repeated by the courier who made them answer success and change nothing, so a retry
after a lost reply is not `invalid_transition`; every transition locks the job's row first.

Before 2026-10-13 the app sent a path on the phone, which could never verify, and the server accepted a delivery
with no proof at all; until 2026-10-16 the upload address could be replayed for its ten minutes with any bytes.
A photo uploaded under the old `<uuid>.jpg` name carries no hash, so a courier holding one when this ships takes
the photo again. The backoffice reads a photo through a fifteen-minute presigned GET. The URLs are signed over
the Host header, so the gateway's storage route must keep the Host the phone sent (`preserve_host`).

### The store is any S3 that keeps a SHA-256 checksum

`FleetPulse.Storage.S3` speaks plain S3 through `SigV4`, and nothing in it is vendor-specific. Since 2026-10-18
the store is VersityGW, which replaced MinIO when MinIO's repositories were archived (infrastructure's
`docs/OBJECT-STORAGE.md` §8). The configuration is `OBJECT_STORE_*`; the store-backed tests are tagged
`:object_store` and run when `OBJECT_STORE_TEST_ENDPOINT`, `_ACCESS_KEY` and `_SECRET_KEY` name a store. A
checksum mismatch is AWS's `BadDigest`, which VersityGW, RustFS and SeaweedFS all answer; MinIO answered its own
`XAmzContentChecksumMismatch`, and the test asserted that until the move.

### Every delivery is in the evidence log

`delivery_evidence` holds one row per delivered job — the photo's SHA-256, the signature's (the decoded PNG's;
none only for deliveries before 2026-10-21), the courier's principal and `delivered_at` — inserted in the
transaction that marks the job delivered, before the update. Postgres enforces it: a trigger refuses any change
of a job to `delivered` (and any job inserted as delivered) whose evidence row was not written earlier in the
same transaction, so a new code path that forgets the log fails at its first statement; triggers on the log refuse `UPDATE`, `DELETE` and `TRUNCATE`;
one row per job. A courier without an identity principal cannot deliver (`unlinked`): the log must name who
did. Deliveries made before the log existed are not in it, by decision: their photos were never hashed when they
were taken, and a hash computed now would prove only what the bucket holds now.

The log is the notary's evidence of delivery (notary PLAN decision 38), read through
`fulfillment.v1.DeliveryEvidenceService/DeliveriesSince`. Its cursor is `(transaction_id xid8, sequence)` and it
serves only rows below `pg_snapshot_xmin(pg_current_snapshot())`, so a row whose transaction commits after a later
one's can never be skipped; a transaction left open anywhere in the cluster holds the feed back, it never makes
it skip. The feed tests run in a scratch database of their own (`FleetPulse.ScratchDatabase`), because the
sandbox never commits and the log can never be emptied.

### Each caller reaches only the RPCs it makes

`GRPC_ALLOWED_CALLERS` takes `peer` (every method), `peer@package.Service` or `peer@package.Service/Method`. A listed
peer may also use server reflection, which describes the published contract and nothing else — the mesh probes
(`trace_test.sh`, `verify_p1.sh`, `handshake_matrix.sh`) resolve methods through it, as order's do. The notary needs
`notary@fulfillment.v1.DeliveryEvidenceService/DeliveriesSince`. Server reflection lists every service the endpoint
runs; until 2026-10-16 it left out `FleetRegistryService`. v1.0.0 parses neither a method entry nor the reflection
rule, so infrastructure keeps matching's list to service entries until this release is live.

### The fleet's positions are the backoffice's

`/drivers`, `/drivers/nearby` and `/drivers/:id` answer to `admin` only. Every seller could read every
courier's live position, speed and heading, and an offline courier's last one, and nothing in the estate
used the routes as a seller.

### A parcel weighs at least what the sender says

`DispatchCourier` carries `parcel_weight_grams`, and the job is booked with it in whole kilograms rounded up, so a
1,200 g parcel is 2 kg: the capacity check (`min_capacity_kg`) must never see a parcel lighter than it is. Zero
means the sender stated no weight, which is what order sends for an order placed before 2026-10-18, and books 0 kg
as every job did before; a negative weight is refused as `INVALID_PARCEL_WEIGHT`.

### An unknown signing key is looked for at most every ten seconds

`TokenVerifier` answers a token's `kid` from the keys it holds. A `kid` it does not hold makes it fetch identity's
JWKS again only if its last fetch was at least `@unknown_key_refresh_ms` (ten seconds) ago; otherwise it answers
with what that fetch found: `:invalid_token` if identity answered, `:identity_unavailable` if it did not. The
breaker opened only after failures, so until 2026-10-19 a stream of forged tokens with made-up key ids, while
identity was up, made identity answer once per request.

### No arrival time is made up

`DispatchCourier` leaves `eta_minutes` at zero. It was a constant 10 whatever the distance; nothing read it,
and an estimate the fleet does not have is not one to send.

### A courier is on duty only when it says so

Joining `driver:<id>` binds the driver's `DriverState` to that channel (monitored) and changes nothing else; the
join reply carries the status. Only `status` puts a driver on duty, and the status is decided inside
`DriverState` from the jobs it carries, so it cannot race a claim: `offline` always; `online` is `busy` once the
driver carries `max_orders` jobs; `busy` only with a job (`no_active_job`). The `status` reply carries what was
decided. A cold `DriverState` (node restart, or reaped) starts `offline` with its job count read from `orders`.
`DriverState` writes every change of status to `drivers.status` (`StatusRecord`), and `/driver/me` answers the
live status (`offline` when nothing tracks the driver), so neither can show a courier stale: until 2026-10-21
claims and releases never reached the row. The channel that serves the driver dying takes it off duty; one a
reconnect replaced changes nothing. The idle reaper never stops a driver with a live channel: until 2026-10-21
it stopped a connected courier who had been offline for fifteen minutes, and `status online` then answered `ok`
to a courier nothing tracked.

### Dispatch uses only positions sent while on duty

A position counts for automatic dispatch only if it arrived after the driver last went on duty
(`DriverState.fresh?/1`), so the app sends a ping right after `status online` even if it has not moved. A
`ping` recorded before the position held is not applied, one stamped more than five minutes ahead of the server
is `invalid_telemetry`, and a driver may send `ping_limit` pings per `ping_window_ms` (`config.exs`;
`rate_limited` beyond). HTTP rate limits are the gateway's, and the
edge service's once it exists: behind Kong every request comes from Kong's address, so a per-IP limit here
would throttle every client as one. The unmounted `Plugs.RateLimit` was removed on 2026-10-21.

### Positions recorded offline are history, never the live position

The app keeps the positions it records without a connection (AGENTS.md: the offline Hive queue) and sends them
with `ping_batch` (`OfflineHistory`): `{"pings": [ping, ...]}`, each entry the fields of a `ping`. They go to
`location_pings`, the table the `PersistenceBatcher` writes the live position's 30-second sample to, with the
same 30-day retention counted from when the row was stored, and never to `DriverState`: they move no courier
and count for no dispatch. One courier and one `recorded_at` is one row, so a repeat is a duplicate, and a
batch may come in any order. A batch holds at most 100 positions (under seven minutes of driving at the app's
four-second cadence, one `INSERT` that keeps the channel process from blocking long, and a reply that stays
small); a fix more than five minutes ahead of the server (`ahead_of_server_clock`) or more than a day old
(`too_old`) is refused, as is one that is not a fix (`invalid_telemetry`). The reply names each entry by its
index as `stored`, `duplicates` or `refused`, so an `ok` reply settles the whole batch and the app deletes it;
an error reply (`rate_limited`, `invalid_batch`, `batch_too_large`, `unavailable`) settles nothing. Batches have
their own budget, `ping_batch_limit` per `ping_batch_window_ms`, which neither spends nor blocks live pings.
Only `Snapshot`, on a cold start, reads the table: the newest row, shown as the last known position and never
fresh.

### An administrator takes a job off a courier; nobody here cancels one order is waiting on

`POST /backoffice/dispatches/:id/unassign` returns an `assigned` job to `pending`, records who did it in
`order_unassignments`, frees the courier and tells its app (`order_unassigned`, then `active_order`).
`ReDispatcher` offers the job at once, never to a courier it was taken from; an administrator may still hand it
back by name. Order is not told: it calls `DispatchCourier` only until one succeeds, and the waybill and the
order number stay on the job; the courier who delivers is named in `OrderDelivered`. A `picked_up` job is
neither unassigned nor cancelled: the parcel is in the courier's hands. A job with an order number is not
cancelled here (`bound_to_order`): order would never hear of it and its paid order would wait for a courier
forever. That waits on the admin-cancel fact reaching order over RabbitMQ from an outbox
(infrastructure's `docs/MIDDLEWARE-ADOPTION.md`, P1 and P2), which is not built.

### A socket's token travels in a header

Both sockets take the access token from Phoenix's `auth_token` (the `Sec-WebSocket-Protocol` entry
`base64url.bearer.phx.<unpadded base64 of the token>`, offered beside `phoenix`). The `token` query parameter
is still read for app builds that send it; the gateway's access log records every query string, so it goes
once no installed app uses it.

### An outage is never a business answer

A database that cannot be reached is 503 on HTTP (`Plug.Exception` for `DBConnection.ConnectionError`), not
500. `FleetRegistryService` and `CourierTelemetryService` answer a reason they do not know with gRPC
`INTERNAL`, never `success: false`: identity treats a refusal as final and returns the account to the customer.
Order retries `DispatchCourier` on any error status and on any refusal but `ORDER_ALREADY_FINISHED`.

### Required configuration fails at start

`ORDER_GRPC_HOST` (order's gRPC address) and `IDENTITY_JWKS_URL` refuse to start when unset or empty; until
2026-10-21 a missing order address was found at the first delivery, as a retry that could never succeed.
`KINETIX_TIME_ZONE` is the platform's clock, an IANA name, the zone warehouse reads too: "delivered today" counts
from midnight on it (`PlatformTimeZone`, on the `tz` database), and the application refuses to start on a name
that is not a zone. It was the UTC day, which starts at 07:00 in Jakarta.

