defmodule FleetPulse.Dispatch.EvidenceFeed do
  @moduledoc """
  Reads the delivery evidence log in commit-safe order. The cursor is `(transaction_id, sequence)`,
  and only rows of transactions older than every transaction still running are served: a row whose
  transaction commits after a later one's can never fall behind a cursor that already moved past it.
  """

  alias FleetPulse.Repo

  @type position :: {non_neg_integer(), non_neg_integer()}

  @type delivery :: %{
          position: position(),
          order_number: String.t() | nil,
          driver_principal_id: String.t(),
          photo_sha256: binary(),
          signature_sha256: binary() | nil,
          delivered_at: DateTime.t()
        }

  @type page :: %{deliveries: [delivery()], next: position(), has_more: boolean()}

  @query """
  SELECT transaction_id::text, sequence, order_number, driver_principal_id, photo_sha256,
         signature_sha256, delivered_at
  FROM delivery_evidence
  WHERE (transaction_id, sequence) > ($1::text::xid8, $2)
    AND transaction_id < pg_snapshot_xmin(pg_current_snapshot())
  ORDER BY transaction_id, sequence
  LIMIT $3
  """

  @spec since(position(), pos_integer()) :: page()
  def since({transaction_id, sequence} = after_position, limit) do
    %Postgrex.Result{rows: rows} =
      Repo.query!(@query, [Integer.to_string(transaction_id), sequence, limit + 1])

    {deliveries, beyond} =
      rows
      |> Enum.map(&delivery/1)
      |> Enum.split(limit)

    %{
      deliveries: deliveries,
      next: next_position(deliveries, after_position),
      has_more: beyond != []
    }
  end

  @spec delivery(list()) :: delivery()
  defp delivery([transaction_id, sequence, order_number, driver, photo, signature, delivered_at]) do
    %{
      position: {String.to_integer(transaction_id), sequence},
      order_number: order_number,
      driver_principal_id: driver,
      photo_sha256: photo,
      signature_sha256: signature,
      delivered_at: delivered_at
    }
  end

  @spec next_position([delivery()], position()) :: position()
  defp next_position([], after_position), do: after_position
  defp next_position(deliveries, _after_position), do: List.last(deliveries).position
end
