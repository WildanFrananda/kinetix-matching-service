defmodule FleetPulse.Tracking.StatusRecord do
  @moduledoc """
  Writes a driver's live status to `drivers.status`, so the row says what `DriverState` decided. A write
  that fails is logged and leaves the live state as it is: the live state is the answer, the row its copy.
  """

  import Ecto.Query

  require Logger

  alias FleetPulse.Repo
  alias FleetPulse.Tracking.Driver
  alias FleetPulse.Types

  @spec write(Types.id(), Driver.status()) :: :ok | {:error, Exception.t()}
  def write(driver_id, status) do
    {_count, nil} =
      Driver
      |> where([d], d.id == ^driver_id)
      |> Repo.update_all(set: [status: status, updated_at: DateTime.utc_now(:second)])

    :ok
  rescue
    error ->
      Logger.warning(
        "[Tracking] driver #{driver_id} is #{status}, and the drivers row could not be told: " <>
          Exception.message(error)
      )

      {:error, error}
  end
end
