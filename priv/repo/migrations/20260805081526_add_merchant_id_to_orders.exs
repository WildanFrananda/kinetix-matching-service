defmodule FleetPulse.Repo.Migrations.AddMerchantIdToOrders do
  @moduledoc """
  Adds merchant_id column and index to the orders table for multi-tenant isolation.
  """

  use Ecto.Migration

  def change do
    alter table(:orders) do
      add :merchant_id, :integer
    end

    create index(:orders, [:merchant_id])
  end
end
