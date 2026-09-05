defmodule FleetPulse.Repo.Migrations.AddPrincipalIdToDrivers do
  @moduledoc """
  Links a driver row to the identity principal that authenticates as it, and removes the local
  password.

  Identity is the only service on this platform that may hold a credential. A second password
  store means a second place to leak from, a second reset flow, and two answers to the question
  of who somebody is.

  `principal_id` is nullable: drivers registered before this migration have no principal yet, and
  an unlinked driver simply cannot open a socket until an operator links it. That is visible as a
  refusal rather than as a silent fallback to whichever driver happened to match.
  """
  use Ecto.Migration

  def up do
    alter table(:drivers) do
      add :principal_id, :string
      remove :hashed_password
    end

    create unique_index(:drivers, [:principal_id])
  end

  def down do
    drop index(:drivers, [:principal_id])

    alter table(:drivers) do
      remove :principal_id
      add :hashed_password, :string
    end
  end
end
