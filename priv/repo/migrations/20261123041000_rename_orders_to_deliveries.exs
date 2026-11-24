defmodule KinetixMatching.Repo.Migrations.RenameOrdersToDeliveries do
  use Ecto.Migration

  @spec up() :: :ok
  def up do
    execute("DROP TRIGGER orders_delivery_is_logged ON orders")
    execute("DROP TRIGGER orders_insert_delivered_is_logged ON orders")
    execute("DROP FUNCTION order_delivery_is_logged()")

    rename(table(:orders), to: table(:deliveries))

    execute("ALTER INDEX orders_order_number_index RENAME TO deliveries_order_number_index")
    execute("ALTER INDEX orders_awb_number_index RENAME TO deliveries_awb_number_index")

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_pickup_latitude_range TO deliveries_pickup_latitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_pickup_longitude_range TO deliveries_pickup_longitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_dropoff_latitude_range TO deliveries_dropoff_latitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_dropoff_longitude_range TO deliveries_dropoff_longitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_weight_kg_non_negative TO deliveries_weight_kg_non_negative"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_status_valid TO deliveries_status_valid"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT orders_driver_presence TO deliveries_driver_presence"
    )

    rename(table(:delivery_evidence), :order_id, to: :delivery_id)
    rename(table(:order_unassignments), :order_id, to: :delivery_id)

    execute(
      "ALTER TABLE delivery_evidence RENAME CONSTRAINT delivery_evidence_order_id_fkey TO delivery_evidence_delivery_id_fkey"
    )

    execute(
      "ALTER TABLE order_unassignments RENAME CONSTRAINT order_unassignments_order_id_fkey TO order_unassignments_delivery_id_fkey"
    )

    execute("""
    CREATE FUNCTION delivery_is_logged() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM delivery_evidence e
        WHERE e.delivery_id = NEW.id
          AND e.transaction_id = pg_current_xact_id()
      ) THEN
        RAISE EXCEPTION 'job % cannot be marked delivered with no evidence written before it in this transaction',
          NEW.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER deliveries_insert_delivered_is_logged
    BEFORE INSERT ON deliveries
    FOR EACH ROW
    WHEN (NEW.status = 'delivered')
    EXECUTE FUNCTION delivery_is_logged()
    """)

    execute("""
    CREATE TRIGGER deliveries_delivery_is_logged
    BEFORE UPDATE OF status ON deliveries
    FOR EACH ROW
    WHEN (NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered')
    EXECUTE FUNCTION delivery_is_logged()
    """)

    :ok
  end

  @spec down() :: :ok
  def down do
    execute("DROP TRIGGER deliveries_delivery_is_logged ON deliveries")
    execute("DROP TRIGGER deliveries_insert_delivered_is_logged ON deliveries")
    execute("DROP FUNCTION delivery_is_logged()")

    rename(table(:order_unassignments), :delivery_id, to: :order_id)
    rename(table(:delivery_evidence), :delivery_id, to: :order_id)

    execute(
      "ALTER TABLE delivery_evidence RENAME CONSTRAINT delivery_evidence_delivery_id_fkey TO delivery_evidence_order_id_fkey"
    )

    execute(
      "ALTER TABLE order_unassignments RENAME CONSTRAINT order_unassignments_delivery_id_fkey TO order_unassignments_order_id_fkey"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_driver_presence TO orders_driver_presence"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_status_valid TO orders_status_valid"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_weight_kg_non_negative TO orders_weight_kg_non_negative"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_dropoff_longitude_range TO orders_dropoff_longitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_dropoff_latitude_range TO orders_dropoff_latitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_pickup_longitude_range TO orders_pickup_longitude_range"
    )

    execute(
      "ALTER TABLE deliveries RENAME CONSTRAINT deliveries_pickup_latitude_range TO orders_pickup_latitude_range"
    )

    execute("ALTER INDEX deliveries_order_number_index RENAME TO orders_order_number_index")
    execute("ALTER INDEX deliveries_awb_number_index RENAME TO orders_awb_number_index")

    rename(table(:deliveries), to: table(:orders))

    execute("""
    CREATE FUNCTION order_delivery_is_logged() RETURNS trigger
    LANGUAGE plpgsql AS $$
    BEGIN
      IF NOT EXISTS (
        SELECT 1 FROM delivery_evidence e
        WHERE e.order_id = NEW.id
          AND e.transaction_id = pg_current_xact_id()
      ) THEN
        RAISE EXCEPTION 'job % cannot be marked delivered with no evidence written before it in this transaction',
          NEW.id
          USING ERRCODE = 'check_violation';
      END IF;
      RETURN NEW;
    END;
    $$
    """)

    execute("""
    CREATE TRIGGER orders_insert_delivered_is_logged
    BEFORE INSERT ON orders
    FOR EACH ROW
    WHEN (NEW.status = 'delivered')
    EXECUTE FUNCTION order_delivery_is_logged()
    """)

    execute("""
    CREATE TRIGGER orders_delivery_is_logged
    BEFORE UPDATE OF status ON orders
    FOR EACH ROW
    WHEN (NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM 'delivered')
    EXECUTE FUNCTION order_delivery_is_logged()
    """)

    :ok
  end
end
