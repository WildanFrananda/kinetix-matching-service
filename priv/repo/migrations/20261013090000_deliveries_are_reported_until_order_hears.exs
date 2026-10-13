defmodule FleetPulse.Repo.Migrations.DeliveriesAreReportedUntilOrderHears do
  use Ecto.Migration

  @moduledoc """
  A delivery is owed to order until order has recorded it.
  """

  def up do
    alter table(:orders) do
      add :delivered_at, :utc_datetime_usec
      add :delivery_reported_at, :utc_datetime_usec
      add :delivery_report_attempts, :integer, null: false, default: 0
      add :delivery_report_next_at, :utc_datetime_usec
      add :delivery_report_error, :string, size: 500
    end

    execute("""
    UPDATE orders
    SET delivered_at = updated_at,
        delivery_report_next_at = now()
    WHERE status = 'delivered'
      AND order_number IS NOT NULL
    """)

    create index(
             :orders,
             [:delivery_report_next_at],
             where: "delivery_reported_at IS NULL AND delivery_report_next_at IS NOT NULL",
             name: :orders_delivery_report_due
           )
  end

  def down do
    drop index(:orders, [:delivery_report_next_at], name: :orders_delivery_report_due)

    alter table(:orders) do
      remove :delivery_report_error
      remove :delivery_report_next_at
      remove :delivery_report_attempts
      remove :delivery_reported_at
      remove :delivered_at
    end
  end
end
