defmodule FleetPulse.Repo.Migrations.AddPodFieldsToOrders do
  use Ecto.Migration

  def change do
    alter table(:orders) do
      add :pod_photo_url, :string
      add :pod_signature, :text
    end
  end
end
