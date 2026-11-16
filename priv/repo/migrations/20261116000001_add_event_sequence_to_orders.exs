defmodule KinetixMatching.Repo.Migrations.AddEventSequenceToOrders do
  use Ecto.Migration

  def change do
    alter table(:orders) do
      add :event_sequence, :bigint, null: false, default: 0
    end
  end
end
