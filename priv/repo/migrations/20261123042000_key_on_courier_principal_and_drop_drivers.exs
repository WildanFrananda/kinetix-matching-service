defmodule KinetixMatching.Repo.Migrations.KeyOnCourierPrincipalAndDropDrivers do
  @moduledoc """
  Moves courier identity ownership to kinetix-identity-service (TO-D2, TO-D3).

  Every courier reference in `location_pings`, `deliveries`, and `order_unassignments`
  is re-keyed on `courier_principal_id` (`varchar(255)`), backfilled from `drivers.principal_id`,
  and the local `drivers` table is dropped.
  """
  use Ecto.Migration

  def up do
    alter table(:location_pings) do
      add(:courier_principal_id, :string, size: 255)
    end

    alter table(:deliveries) do
      add(:courier_principal_id, :string, size: 255)
    end

    alter table(:order_unassignments) do
      add(:courier_principal_id, :string, size: 255)
    end

    execute("""
    DO $$
    DECLARE
      unresolved_pings integer;
      unresolved_unassignments integer;
      unresolved_deliveries integer;
    BEGIN
      SELECT count(*) INTO unresolved_pings FROM location_pings
      WHERE driver_id NOT IN (
        SELECT id FROM drivers WHERE principal_id IS NOT NULL AND principal_id <> ''
      );

      SELECT count(*) INTO unresolved_unassignments FROM order_unassignments
      WHERE driver_id NOT IN (
        SELECT id FROM drivers WHERE principal_id IS NOT NULL AND principal_id <> ''
      );

      SELECT count(*) INTO unresolved_deliveries FROM deliveries
      WHERE driver_id IS NOT NULL AND driver_id NOT IN (
        SELECT id FROM drivers WHERE principal_id IS NOT NULL AND principal_id <> ''
      );

      IF unresolved_pings > 0 OR unresolved_unassignments > 0 OR unresolved_deliveries > 0 THEN
        RAISE EXCEPTION
          'Cannot drop drivers: unresolved driver_id rows (location_pings=%, order_unassignments=%, deliveries=%). Reconcile principals and retry.',
          unresolved_pings, unresolved_unassignments, unresolved_deliveries;
      END IF;
    END $$
    """)

    execute("""
    UPDATE location_pings
    SET courier_principal_id = d.principal_id
    FROM drivers d
    WHERE location_pings.driver_id = d.id
    """)

    execute("""
    UPDATE order_unassignments
    SET courier_principal_id = d.principal_id
    FROM drivers d
    WHERE order_unassignments.driver_id = d.id
    """)

    execute("""
    UPDATE deliveries
    SET courier_principal_id = d.principal_id
    FROM drivers d
    WHERE deliveries.driver_id = d.id
      AND d.principal_id IS NOT NULL
      AND d.principal_id <> ''
    """)

    execute("""
    DO $$
    DECLARE unresolved integer;
    BEGIN
      SELECT count(*) INTO unresolved FROM deliveries
      WHERE driver_id IS NOT NULL AND (courier_principal_id IS NULL OR courier_principal_id = '');
      IF unresolved > 0 THEN
        RAISE EXCEPTION
          '% delivery row(s) still reference a driver without a principal_id in drivers.',
          unresolved;
      END IF;
    END $$
    """)

    alter table(:location_pings) do
      modify(:courier_principal_id, :string, size: 255, null: false)
    end

    alter table(:order_unassignments) do
      modify(:courier_principal_id, :string, size: 255, null: false)
    end

    drop(constraint(:deliveries, :deliveries_driver_presence))
    drop_if_exists(index(:location_pings, [:driver_id, :recorded_at]))
    drop_if_exists(index(:deliveries, [:driver_id]))
    drop_if_exists(index(:order_unassignments, [:driver_id]))

    alter table(:location_pings) do
      remove(:driver_id)
    end

    alter table(:deliveries) do
      remove(:driver_id)
    end

    alter table(:order_unassignments) do
      remove(:driver_id)
    end

    create(unique_index(:location_pings, [:courier_principal_id, :recorded_at]))
    create(index(:deliveries, [:courier_principal_id]))
    create(index(:order_unassignments, [:courier_principal_id]))

    create(
      constraint(:location_pings, :location_pings_courier_principal_id_present,
        check: "courier_principal_id <> ''"
      )
    )

    create(
      constraint(:order_unassignments, :order_unassignments_courier_principal_id_present,
        check: "courier_principal_id <> ''"
      )
    )

    create(
      constraint(:deliveries, :deliveries_courier_principal_presence,
        check:
          "(courier_principal_id IS NOT NULL AND courier_principal_id <> '') OR status IN ('pending', 'cancelled')"
      )
    )

    drop(table(:drivers))
  end

  def down do
    create table(:drivers) do
      add(:vehicle_plate, :string, size: 20, null: false)
      add(:capacity_kg, :integer, null: false, default: 0)
      add(:status, :string, null: false, default: "offline")
      add(:active, :boolean, null: false, default: true)
      add(:principal_id, :string)

      timestamps(type: :utc_datetime)
    end

    create(unique_index(:drivers, [:vehicle_plate]))
    create(unique_index(:drivers, [:principal_id]))
    create(index(:drivers, [:active, :status]))

    create(
      constraint(:drivers, :drivers_status_valid,
        check: "status IN ('online', 'busy', 'offline')"
      )
    )

    create(constraint(:drivers, :drivers_capacity_kg_non_negative, check: "capacity_kg >= 0"))

    execute("""
    INSERT INTO drivers (vehicle_plate, capacity_kg, status, active, principal_id, inserted_at, updated_at)
    SELECT
      'RESTORED-' || row_number() OVER (ORDER BY principal_id),
      0,
      'offline',
      true,
      principal_id,
      now(),
      now()
    FROM (
      SELECT courier_principal_id AS principal_id FROM location_pings
      UNION
      SELECT courier_principal_id AS principal_id FROM deliveries WHERE courier_principal_id IS NOT NULL
      UNION
      SELECT courier_principal_id AS principal_id FROM order_unassignments
    ) principals
    """)

    alter table(:location_pings) do
      add(:driver_id, references(:drivers, on_delete: :restrict))
    end

    alter table(:deliveries) do
      add(:driver_id, references(:drivers, on_delete: :restrict))
    end

    alter table(:order_unassignments) do
      add(:driver_id, references(:drivers, on_delete: :restrict))
    end

    execute("""
    UPDATE location_pings
    SET driver_id = d.id
    FROM drivers d
    WHERE location_pings.courier_principal_id = d.principal_id
    """)

    execute("""
    UPDATE deliveries
    SET driver_id = d.id
    FROM drivers d
    WHERE deliveries.courier_principal_id = d.principal_id
    """)

    execute("""
    UPDATE order_unassignments
    SET driver_id = d.id
    FROM drivers d
    WHERE order_unassignments.courier_principal_id = d.principal_id
    """)

    alter table(:location_pings) do
      modify(:driver_id, :bigint, null: false)
    end

    alter table(:order_unassignments) do
      modify(:driver_id, :bigint, null: false)
    end

    drop(constraint(:deliveries, :deliveries_courier_principal_presence))
    drop(constraint(:location_pings, :location_pings_courier_principal_id_present))
    drop(constraint(:order_unassignments, :order_unassignments_courier_principal_id_present))

    drop_if_exists(index(:location_pings, [:courier_principal_id, :recorded_at]))
    drop_if_exists(index(:deliveries, [:courier_principal_id]))
    drop_if_exists(index(:order_unassignments, [:courier_principal_id]))

    alter table(:location_pings) do
      remove(:courier_principal_id)
    end

    alter table(:deliveries) do
      remove(:courier_principal_id)
    end

    alter table(:order_unassignments) do
      remove(:courier_principal_id)
    end

    create(unique_index(:location_pings, [:driver_id, :recorded_at]))
    create(index(:deliveries, [:driver_id]))

    create(
      constraint(:deliveries, :deliveries_driver_presence,
        check: "driver_id IS NOT NULL OR status IN ('pending', 'cancelled')"
      )
    )
  end
end
