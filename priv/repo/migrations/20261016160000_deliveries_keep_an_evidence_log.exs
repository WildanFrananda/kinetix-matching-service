defmodule FleetPulse.Repo.Migrations.DeliveriesKeepAnEvidenceLog do
  use Ecto.Migration

  @moduledoc """
  Every delivery is in the evidence log, written before the job is marked delivered.
  """

  def up do
    execute("""
    CREATE TABLE delivery_evidence (
        sequence bigint GENERATED ALWAYS AS IDENTITY PRIMARY KEY,
        transaction_id xid8 NOT NULL DEFAULT pg_current_xact_id(),
        order_id bigint NOT NULL REFERENCES orders (id),
        order_number varchar(255),
        driver_principal_id varchar(255) NOT NULL,
        photo_sha256 bytea NOT NULL,
        signature_sha256 bytea,
        delivered_at timestamptz NOT NULL,
        CONSTRAINT delivery_evidence_photo_sha256_length CHECK (octet_length(photo_sha256) = 32),
        CONSTRAINT delivery_evidence_signature_sha256_length
            CHECK (signature_sha256 IS NULL OR octet_length(signature_sha256) = 32),
        CONSTRAINT delivery_evidence_driver_principal_present CHECK (driver_principal_id <> '')
    )
    """)

    create unique_index(:delivery_evidence, [:order_id])

    create index(:delivery_evidence, [:transaction_id, :sequence])

    execute("""
    CREATE FUNCTION delivery_evidence_is_append_only() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        RAISE EXCEPTION 'delivery_evidence is append-only: % refused', TG_OP;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER delivery_evidence_no_update_or_delete
        BEFORE UPDATE OR DELETE ON delivery_evidence
        FOR EACH ROW EXECUTE FUNCTION delivery_evidence_is_append_only()
    """)

    execute("""
    CREATE TRIGGER delivery_evidence_no_truncate
        BEFORE TRUNCATE ON delivery_evidence
        FOR EACH STATEMENT EXECUTE FUNCTION delivery_evidence_is_append_only()
    """)

    execute("""
    CREATE FUNCTION order_delivery_is_logged() RETURNS trigger LANGUAGE plpgsql AS $$
    BEGIN
        IF NOT EXISTS (
            SELECT 1 FROM delivery_evidence e
            WHERE e.order_id = NEW.id
              AND e.transaction_id = pg_current_xact_id()
        ) THEN
            RAISE EXCEPTION 'job % was marked delivered with no evidence written before it in the same transaction',
                NEW.id;
        END IF;
        RETURN NULL;
    END
    $$
    """)

    execute("""
    CREATE TRIGGER orders_insert_delivered_is_logged
        AFTER INSERT ON orders
        FOR EACH ROW WHEN (NEW.status = 'delivered')
        EXECUTE FUNCTION order_delivery_is_logged()
    """)

    execute("""
    CREATE TRIGGER orders_delivery_is_logged
        AFTER UPDATE OF status ON orders
        FOR EACH ROW WHEN (NEW.status = 'delivered' AND OLD.status IS DISTINCT FROM NEW.status)
        EXECUTE FUNCTION order_delivery_is_logged()
    """)
  end

  def down do
    execute("DROP TRIGGER orders_delivery_is_logged ON orders")
    execute("DROP TRIGGER orders_insert_delivered_is_logged ON orders")
    execute("DROP FUNCTION order_delivery_is_logged()")
    execute("DROP TRIGGER delivery_evidence_no_truncate ON delivery_evidence")
    execute("DROP TRIGGER delivery_evidence_no_update_or_delete ON delivery_evidence")
    execute("DROP FUNCTION delivery_evidence_is_append_only()")

    drop table(:delivery_evidence)
  end
end
