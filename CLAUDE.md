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

`Dispatch.mark_delivered` stores `delivered_at` and asks `DeliveryReport.attempt/1` to tell order once. What
does not go through is retried by `DeliveryReporter` every minute, backing off a minute per attempt up to an
hour, with the time the parcel was actually delivered — order's `OrderDelivered` is idempotent, so a repeat
is answered as already recorded. Until 2026-10-13 the report was made once and a failure was a log line:
order never heard of the delivery, so the courier's fee was never settled, the return window never started
and the merchant was never paid. Only order's own refusal (`INVALID_ARGUMENT`, `NOT_FOUND`,
`FAILED_PRECONDITION`, `ALREADY_EXISTS`, `OUT_OF_RANGE`) stops the retrying; `UNAVAILABLE`,
`DEADLINE_EXCEEDED`, `PERMISSION_DENIED` and the rest mean order could not be asked, and every one of them
used to be reported as a refusal. The migration that added the columns queued every delivered job with an
order number, so a delivery order missed before is reported once more.

### A delivery needs a photo matching can see in the bucket

`delivered` is refused without `pod_photo_url`, and the URL must name an object under
`pod/<this job's id>/` in the private `kinetix-pod` bucket that is really there. The courier asks for an
upload address over the channel (`pod_upload`, only for a job they carry that is picked up); matching signs
a short-lived PUT for the public storage host (`MINIO_PUBLIC_URL`) and checks the object through the
internal endpoint before it accepts the delivery. If the bucket cannot be asked, the answer is
`proof_unverifiable`, not a refusal: the courier tries again. Before 2026-10-13 the app sent a path on the
phone, which could never verify, and the server accepted a delivery with no proof at all. The backoffice
reads a photo through a fifteen-minute presigned GET. The URLs are signed over the Host header only, so the
gateway's storage route must keep the Host the phone sent (`preserve_host`).

### The fleet's positions are the backoffice's

`/drivers`, `/drivers/nearby` and `/drivers/:id` answer to `admin` only. Every seller could read every
courier's live position, speed and heading, and an offline courier's last one, and nothing in the estate
used the routes as a seller.

### No arrival time is made up

`DispatchCourier` leaves `eta_minutes` at zero. It was a constant 10 whatever the distance; nothing read it,
and an estimate the fleet does not have is not one to send.
