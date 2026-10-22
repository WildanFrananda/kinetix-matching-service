defmodule FleetPulse.Tracking.OfflineHistory do
  @moduledoc """
  Positions a courier's phone recorded while it had no connection, sent later in batches. They are
  history: stored in `location_pings` beside the 30-second sample of the live position, under the same
  retention, and never applied to `DriverState`, so they neither move the courier nor count for dispatch.
  """

  require Logger

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.LocationPing
  alias FleetPulse.Tracking.Telemetry
  alias FleetPulse.Types

  @max_batch 100
  @max_age_seconds 86_400

  @type refusal :: :invalid_telemetry | :ahead_of_server_clock | :too_old

  @type outcome :: %{
          stored: [non_neg_integer()],
          duplicates: [non_neg_integer()],
          refused: [%{index: non_neg_integer(), reason: refusal()}]
        }

  @type error :: :invalid_batch | :batch_too_large | :unavailable

  @spec max_batch() :: pos_integer()
  def max_batch, do: @max_batch

  @spec record(Types.id(), term(), DateTime.t()) :: {:ok, outcome()} | {:error, error()}
  def record(_driver_id, pings, _now) when is_list(pings) and length(pings) > @max_batch,
    do: {:error, :batch_too_large}

  def record(driver_id, pings, now) when is_list(pings) do
    {accepted, refused} =
      pings
      |> Enum.with_index()
      |> Enum.map(fn {raw, index} -> classify(raw, index, now) end)
      |> Enum.split_with(&match?({:ok, _index, _telemetry}, &1))

    {first, repeated} = first_of_each_moment(accepted)

    with {:ok, inserted} <- insert(driver_id, first, now) do
      {stored, duplicates} = Enum.split_with(first, &MapSet.member?(inserted, moment(&1)))

      {:ok,
       %{
         stored: indexes(stored),
         duplicates: Enum.sort(indexes(duplicates) ++ indexes(repeated)),
         refused:
           Enum.map(refused, fn {:error, index, reason} -> %{index: index, reason: reason} end)
       }}
    end
  end

  def record(_driver_id, _pings, _now), do: {:error, :invalid_batch}

  @spec classify(term(), non_neg_integer(), DateTime.t()) ::
          {:ok, non_neg_integer(), Telemetry.t()} | {:error, non_neg_integer(), refusal()}
  defp classify(raw, index, now) do
    with {:ok, telemetry} <- Telemetry.from_params(raw),
         :ok <- not_ahead(telemetry, now),
         :ok <- not_too_old(telemetry, now) do
      {:ok, index, telemetry}
    else
      {:error, reason} -> {:error, index, reason}
    end
  end

  @spec not_ahead(Telemetry.t(), DateTime.t()) :: :ok | {:error, :ahead_of_server_clock}
  defp not_ahead(telemetry, now) do
    case Telemetry.not_ahead_of(telemetry, now) do
      :ok -> :ok
      {:error, :invalid_telemetry} -> {:error, :ahead_of_server_clock}
    end
  end

  @spec not_too_old(Telemetry.t(), DateTime.t()) :: :ok | {:error, :too_old}
  defp not_too_old(%{recorded_at: recorded_at}, now) do
    if DateTime.diff(now, recorded_at, :second) > @max_age_seconds,
      do: {:error, :too_old},
      else: :ok
  end

  @spec first_of_each_moment([{:ok, non_neg_integer(), Telemetry.t()}]) ::
          {[{:ok, non_neg_integer(), Telemetry.t()}], [{:ok, non_neg_integer(), Telemetry.t()}]}
  defp first_of_each_moment(accepted) do
    {first, repeated, _seen} =
      Enum.reduce(accepted, {[], [], MapSet.new()}, fn entry, {first, repeated, seen} ->
        key = moment(entry)

        if MapSet.member?(seen, key),
          do: {first, [entry | repeated], seen},
          else: {[entry | first], repeated, MapSet.put(seen, key)}
      end)

    {Enum.reverse(first), Enum.reverse(repeated)}
  end

  @spec insert(Types.id(), [{:ok, non_neg_integer(), Telemetry.t()}], DateTime.t()) ::
          {:ok, MapSet.t(integer())} | {:error, :unavailable}
  defp insert(_driver_id, [], _now), do: {:ok, MapSet.new()}

  defp insert(driver_id, entries, now) do
    stored_at = %{now | microsecond: {elem(now.microsecond, 0), 6}}

    rows =
      Enum.map(entries, fn {:ok, _index, telemetry} -> row(driver_id, telemetry, stored_at) end)

    {_count, inserted} =
      Repo.insert_all(LocationPing, rows, on_conflict: :nothing, returning: [:recorded_at])

    {:ok, MapSet.new(inserted, &DateTime.to_unix(&1.recorded_at, :microsecond))}
  rescue
    error ->
      Logger.error(
        "[Tracking] offline positions of driver #{driver_id} could not be stored: " <>
          Exception.message(error)
      )

      {:error, :unavailable}
  end

  @spec row(Types.id(), Telemetry.t(), DateTime.t()) :: map()
  defp row(driver_id, telemetry, stored_at) do
    %{
      driver_id: driver_id,
      latitude: telemetry.latitude,
      longitude: telemetry.longitude,
      speed_kmh: telemetry.speed_kmh,
      bearing_deg: telemetry.bearing_deg,
      recorded_at: telemetry.recorded_at,
      inserted_at: stored_at
    }
  end

  @spec moment({:ok, non_neg_integer(), Telemetry.t()}) :: integer()
  defp moment({:ok, _index, telemetry}), do: DateTime.to_unix(telemetry.recorded_at, :microsecond)

  @spec indexes([{:ok, non_neg_integer(), Telemetry.t()}]) :: [non_neg_integer()]
  defp indexes(entries), do: Enum.map(entries, fn {:ok, index, _telemetry} -> index end)
end
