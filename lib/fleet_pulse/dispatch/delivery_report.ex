defmodule FleetPulse.Dispatch.DeliveryReport do
  @moduledoc """
  Tells order that a courier delivered, and keeps telling it until order has recorded it.
  """

  import Ecto.Query

  require Logger

  alias FleetPulse.Clients.Order, as: OrderClient
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Repo
  alias FleetPulse.Tracking

  @max_backoff_minutes 60
  @max_error_length 500

  @type outcome :: :reported | :deferred | :halted

  @spec attempt(Order.t()) :: {outcome(), Order.t()}
  def attempt(%Order{order_number: nil} = order) do
    halt(order, "this fleet job carries no order number, so there is no order to tell")
  end

  def attempt(%Order{} = order) do
    with {:ok, driver} <- Tracking.fetch_driver(order.driver_id),
         {:ok, principal} <- payable_principal(driver) do
      order
      |> report(principal)
      |> record(order, principal)
    else
      _unpayable ->
        defer(
          order,
          "driver #{order.driver_id} has no identity principal, so nobody can be named as the courier"
        )
    end
  end

  @spec due(pos_integer()) :: [Order.t()]
  def due(limit) do
    now = DateTime.utc_now()

    Order
    |> where([o], o.status == :delivered)
    |> where([o], is_nil(o.delivery_reported_at))
    |> where([o], not is_nil(o.delivery_report_next_at) and o.delivery_report_next_at <= ^now)
    |> order_by([o], asc: o.delivery_report_next_at)
    |> limit(^limit)
    |> Repo.all()
  end

  @spec report(Order.t(), String.t()) :: :ok | {:error, OrderClient.error()}
  defp report(order, principal) do
    OrderClient.delivered(order.order_number, principal, order.delivered_at || order.updated_at)
  end

  @spec record(:ok | {:error, OrderClient.error()}, Order.t(), String.t()) ::
          {outcome(), Order.t()}
  defp record(:ok, order, principal) do
    Logger.info("[Order] #{order.order_number} recorded as delivered by #{principal}")

    order
    |> Ecto.Changeset.change(
      delivery_reported_at: DateTime.utc_now(),
      delivery_report_attempts: order.delivery_report_attempts + 1,
      delivery_report_next_at: nil,
      delivery_report_error: nil
    )
    |> Repo.update!()
    |> then(&{:reported, &1})
  end

  defp record({:error, :refused}, order, principal) do
    halt(order, "order refused the delivery by #{principal}")
  end

  defp record({:error, reason}, order, _principal) do
    defer(order, "order could not be told (#{reason})")
  end

  @spec defer(Order.t(), String.t()) :: {outcome(), Order.t()}
  defp defer(order, reason) do
    attempts = order.delivery_report_attempts + 1
    backoff = min(attempts, @max_backoff_minutes) * 60

    Logger.warning(
      "[Order] #{order.order_number} is delivered and order does not know yet " <>
        "after #{attempts} attempt(s): #{reason}. Next attempt in #{backoff}s."
    )

    order
    |> Ecto.Changeset.change(
      delivery_report_attempts: attempts,
      delivery_report_next_at: DateTime.add(DateTime.utc_now(), backoff, :second),
      delivery_report_error: trim(reason)
    )
    |> Repo.update!()
    |> then(&{:deferred, &1})
  end

  @spec halt(Order.t(), String.t()) :: {outcome(), Order.t()}
  defp halt(order, reason) do
    Logger.error(
      "[Order] #{inspect(order.order_number)} is delivered and will not be reported again " <>
        "without a person: #{reason}"
    )

    order
    |> Ecto.Changeset.change(
      delivery_report_attempts: order.delivery_report_attempts + 1,
      delivery_report_next_at: nil,
      delivery_report_error: trim(reason)
    )
    |> Repo.update!()
    |> then(&{:halted, &1})
  end

  @spec payable_principal(FleetPulse.Tracking.Driver.t()) ::
          {:ok, String.t()} | {:error, :unlinked}
  defp payable_principal(%{principal_id: principal})
       when is_binary(principal) and principal != "",
       do: {:ok, principal}

  defp payable_principal(_driver), do: {:error, :unlinked}

  @spec trim(String.t()) :: String.t()
  defp trim(reason), do: String.slice(reason, 0, @max_error_length)
end
