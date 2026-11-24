defmodule KinetixMatchingWeb.Events.Envelope do
  @moduledoc """
  Unified camelCase JSON event envelope builder conforming to Edge X21.
  """

  alias KinetixMatching.Observability.UUIDv7

  @schema_version 1

  @type error_spec :: %{
          code: String.t(),
          reason: String.t(),
          message: String.t(),
          retryable: boolean()
        }

  @spec server_event(
          String.t(),
          String.t() | nil,
          non_neg_integer() | nil,
          map(),
          DateTime.t()
        ) :: map()
  def server_event(event, order_id, sequence, data, occurred_at \\ DateTime.utc_now())
      when is_binary(event) and is_map(data) do
    %{
      event: event,
      eventId: UUIDv7.generate(),
      schemaVersion: @schema_version,
      orderId: order_id,
      sequence: sequence,
      occurredAt: iso8601(occurred_at),
      data: data
    }
  end

  @spec ack(String.t() | nil, map(), DateTime.t()) :: map()
  def ack(request_id, data, occurred_at \\ DateTime.utc_now()) when is_map(data) do
    %{
      event: "command.ack",
      requestId: request_id,
      schemaVersion: @schema_version,
      occurredAt: iso8601(occurred_at),
      data: data
    }
  end

  @spec error(String.t() | nil, atom() | String.t(), DateTime.t()) :: map()
  def error(request_id, reason, occurred_at \\ DateTime.utc_now()) do
    %{
      event: "command.error",
      requestId: request_id,
      schemaVersion: @schema_version,
      occurredAt: iso8601(occurred_at),
      error: error_detail(reason)
    }
  end

  @spec pong(String.t() | nil, DateTime.t()) :: map()
  def pong(request_id, server_time \\ DateTime.utc_now()) do
    %{
      event: "system.pong",
      requestId: request_id,
      schemaVersion: @schema_version,
      occurredAt: iso8601(server_time),
      data: %{
        serverTime: iso8601(server_time)
      }
    }
  end

  @spec iso8601(DateTime.t() | nil) :: String.t() | nil
  def iso8601(nil), do: nil
  def iso8601(%DateTime{} = timestamp), do: DateTime.to_iso8601(timestamp)

  @spec error_detail(atom() | String.t()) :: error_spec()
  defp error_detail(:invalid_payload),
    do: detail("INVALID_PAYLOAD", "invalid_payload", "Request frame is invalid", false)

  defp error_detail(:unsupported_schema_version),
    do:
      detail(
        "UNSUPPORTED_SCHEMA_VERSION",
        "unsupported_schema_version",
        "Only schemaVersion 1 is supported",
        false
      )

  defp error_detail(:unknown_event),
    do: detail("UNKNOWN_EVENT", "unknown_event", "Unknown command event", false)

  defp error_detail(:rate_limited),
    do: detail("RATE_LIMITED", "rate_limited", "Rate limit exceeded; slow down", true)

  defp error_detail(:invalid_telemetry),
    do: detail("INVALID_TELEMETRY", "invalid_telemetry", "Invalid GPS telemetry payload", false)

  defp error_detail(:invalid_batch),
    do: detail("INVALID_BATCH", "invalid_batch", "Invalid offline ping batch payload", false)

  defp error_detail(:batch_too_large),
    do:
      detail(
        "BATCH_TOO_LARGE",
        "batch_too_large",
        "Ping batch exceeds maximum allowed size",
        false
      )

  defp error_detail(:invalid_status),
    do: detail("INVALID_STATUS", "invalid_status", "Duty status is invalid", false)

  defp error_detail(:invalid_order_id),
    do:
      detail("INVALID_ORDER_ID", "invalid_order_id", "orderId must be a positive integer", false)

  defp error_detail(:invalid_photo_hash),
    do:
      detail(
        "INVALID_PHOTO_HASH",
        "invalid_photo_hash",
        "photoSha256 must be a valid SHA-256 hex digest",
        false
      )

  defp error_detail(:invalid_proof),
    do: detail("INVALID_PROOF", "invalid_proof", "Proof of delivery is invalid", false)

  defp error_detail(:proof_unverifiable),
    do:
      detail(
        "PROOF_UNVERIFIABLE",
        "proof_unverifiable",
        "Uploaded proof photo could not be verified yet",
        true
      )

  defp error_detail(:invalid_transition),
    do:
      detail(
        "INVALID_TRANSITION",
        "invalid_transition",
        "Order cannot transition from its current state",
        false
      )

  defp error_detail(:no_active_job),
    do:
      detail(
        "NO_ACTIVE_JOB",
        "no_active_job",
        "Busy duty status requires an active assigned job",
        false
      )

  defp error_detail(:forbidden),
    do: detail("FORBIDDEN", "forbidden", "Action not permitted for this principal", false)

  defp error_detail(:not_found),
    do: detail("NOT_FOUND", "not_found", "Requested resource was not found", false)

  defp error_detail(:pending_approval),
    do:
      detail(
        "PENDING_APPROVAL",
        "pending_approval",
        "Courier account is pending admin approval",
        false
      )

  defp error_detail(:unavailable),
    do: detail("UNAVAILABLE", "unavailable", "Service temporarily unavailable", true)

  defp error_detail(:identity_unavailable),
    do:
      detail(
        "IDENTITY_UNAVAILABLE",
        "identity_unavailable",
        "Identity service temporarily unavailable",
        true
      )

  defp error_detail(other) when is_atom(other) do
    reason = Atom.to_string(other)
    detail(String.upcase(reason), reason, "Command failed", false)
  end

  defp error_detail(other) when is_binary(other) do
    detail(String.upcase(other), other, "Command failed", false)
  end

  defp error_detail(_other) do
    detail("UNPROCESSABLE", "unprocessable", "Command could not be processed", false)
  end

  @spec detail(String.t(), String.t(), String.t(), boolean()) :: error_spec()
  defp detail(code, reason, message, retryable) do
    %{
      code: code,
      reason: reason,
      message: message,
      retryable: retryable
    }
  end
end
