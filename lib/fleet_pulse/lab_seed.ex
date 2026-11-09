defmodule FleetPulse.LabSeed do
  @moduledoc """
  Demo data for the lab: delivered jobs for one approved courier, each with its evidence row,
  spread evenly over a span of days that ends now. The jobs carry no order number, so nothing is
  reported to order, and no photo is in the bucket: the evidence hashes name the seed, not a photo.
  It writes only to a database whose name ends in `_dev`, the lab's.
  """

  import Ecto.Query

  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.Repo
  alias FleetPulse.Tracking.Driver

  @type refusal ::
          :not_a_lab_database
          | :invalid_delivery_count
          | :invalid_span
          | :unknown_courier
          | :courier_not_active

  @max_deliveries 1_000
  @max_span_days 3_650
  @seconds_per_day 86_400
  @minutes_on_the_road 45
  @pickup {-6.2088, 106.8456}
  @dropoff {-6.1751, 106.8650}

  @spec seed_courier_record(String.t(), pos_integer(), pos_integer()) ::
          {:ok, non_neg_integer()} | {:error, refusal()}
  def seed_courier_record(principal_id, deliveries, span_days) do
    %Postgrex.Result{rows: [[database]]} = Repo.query!("SELECT current_database()")

    if lab_database?(database) do
      courier_record(principal_id, deliveries, span_days, DateTime.utc_now())
    else
      {:error, :not_a_lab_database}
    end
  end

  @spec lab_database?(String.t()) :: boolean()
  def lab_database?(database), do: String.ends_with?(database, "_dev")

  @spec courier_record(String.t(), integer(), integer(), DateTime.t()) ::
          {:ok, non_neg_integer()} | {:error, refusal()}
  def courier_record(_principal_id, deliveries, _span_days, _now)
      when not is_integer(deliveries) or deliveries < 1 or deliveries > @max_deliveries,
      do: {:error, :invalid_delivery_count}

  def courier_record(_principal_id, _deliveries, span_days, _now)
      when not is_integer(span_days) or span_days < 1 or span_days > @max_span_days,
      do: {:error, :invalid_span}

  def courier_record(principal_id, deliveries, span_days, now) do
    with {:ok, driver} <- active_courier(principal_id) do
      fn -> write_deliveries(driver, deliveries, span_days, now) end
      |> Repo.transact()
    end
  end

  @spec active_courier(String.t()) ::
          {:ok, Driver.t()} | {:error, :unknown_courier | :courier_not_active}
  defp active_courier(principal_id) do
    Driver
    |> where([d], d.principal_id == ^principal_id)
    |> Repo.one()
    |> courier_standing()
  end

  @spec courier_standing(Driver.t() | nil) ::
          {:ok, Driver.t()} | {:error, :unknown_courier | :courier_not_active}
  defp courier_standing(nil), do: {:error, :unknown_courier}
  defp courier_standing(%Driver{active: true} = driver), do: {:ok, driver}
  defp courier_standing(%Driver{}), do: {:error, :courier_not_active}

  @spec write_deliveries(Driver.t(), pos_integer(), pos_integer(), DateTime.t()) ::
          {:ok, non_neg_integer()}
  defp write_deliveries(driver, deliveries, span_days, now) do
    step = div(span_days * @seconds_per_day, deliveries)
    first = DateTime.add(now, -span_days * @seconds_per_day, :second)

    Enum.each(0..(deliveries - 1), fn index ->
      write_delivery(driver, index, DateTime.add(first, index * step, :second))
    end)

    {:ok, deliveries}
  end

  @spec write_delivery(Driver.t(), non_neg_integer(), DateTime.t()) :: Order.t()
  defp write_delivery(driver, index, delivered_at) do
    assigned_at = DateTime.add(delivered_at, -@minutes_on_the_road * 60, :second)
    job = Repo.insert!(job_of(driver, index, assigned_at))

    job
    |> DeliveryEvidence.changeset(
      driver.principal_id,
      seed_digest("photo", job.id),
      seed_digest("signature", job.id),
      delivered_at
    )
    |> Repo.insert!()

    job
    |> Ecto.Changeset.change(
      status: :delivered,
      delivered_at: delivered_at,
      updated_at: delivered_at
    )
    |> Repo.update!()
  end

  @spec job_of(Driver.t(), non_neg_integer(), DateTime.t()) :: Order.t()
  defp job_of(driver, index, assigned_at) do
    {pickup_latitude, pickup_longitude} = @pickup
    {dropoff_latitude, dropoff_longitude} = @dropoff
    offset = rem(index, 20) * 0.001

    %Order{
      pickup_latitude: pickup_latitude,
      pickup_longitude: pickup_longitude,
      dropoff_latitude: dropoff_latitude + offset,
      dropoff_longitude: dropoff_longitude - offset,
      weight_kg: 1,
      status: :picked_up,
      driver_id: driver.id,
      awb_number: Order.issue_awb(),
      assigned_at: assigned_at,
      inserted_at: assigned_at,
      updated_at: assigned_at
    }
  end

  @spec seed_digest(String.t(), pos_integer()) :: binary()
  defp seed_digest(kind, job_id), do: :crypto.hash(:sha256, "kinetix-lab-seed:#{kind}:#{job_id}")
end
