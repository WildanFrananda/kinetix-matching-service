defmodule FleetPulse.LabSeedTest do
  use FleetPulse.DataCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.Dispatch.DeliveryEvidence
  alias FleetPulse.Dispatch.Order
  alias FleetPulse.LabSeed

  @now ~U[2026-11-03 03:00:00.000000Z]
  @day 86_400

  defp principal, do: "principal-#{System.unique_integer([:positive])}"

  defp evidence_of(principal_id) do
    DeliveryEvidence
    |> where([e], e.driver_principal_id == ^principal_id)
    |> order_by([e], asc: e.sequence)
    |> Repo.all()
  end

  test "delivers jobs for the courier with their evidence, the first the whole span before now" do
    courier = principal()
    driver = active_driver_fixture(courier)

    assert {:ok, 4} = LabSeed.courier_record(courier, 4, 120, @now)

    evidence = evidence_of(courier)

    assert Enum.map(evidence, & &1.delivered_at) == [
             DateTime.add(@now, -120 * @day, :second),
             DateTime.add(@now, -90 * @day, :second),
             DateTime.add(@now, -60 * @day, :second),
             DateTime.add(@now, -30 * @day, :second)
           ]

    assert Enum.all?(evidence, &(byte_size(&1.photo_sha256) == 32))
    assert Enum.all?(evidence, &(byte_size(&1.signature_sha256) == 32))

    jobs =
      Order
      |> where([o], o.driver_id == ^driver.id)
      |> order_by([o], asc: o.id)
      |> Repo.all()

    assert Enum.map(jobs, & &1.id) == Enum.map(evidence, & &1.order_id)
    assert Enum.all?(jobs, &(&1.status == :delivered))
    assert Enum.all?(jobs, &(&1.order_number == nil and &1.delivery_report_next_at == nil))
    assert Enum.map(jobs, & &1.delivered_at) == Enum.map(evidence, & &1.delivered_at)

    assert Enum.map(jobs, & &1.inserted_at) ==
             Enum.map(evidence, &DateTime.add(&1.delivered_at, -45 * 60, :second))
  end

  test "names no photo: each hash is of the seed's own label for its job" do
    courier = principal()
    _driver = active_driver_fixture(courier)

    assert {:ok, 1} = LabSeed.courier_record(courier, 1, 1, @now)

    [evidence] = evidence_of(courier)

    assert evidence.photo_sha256 ==
             :crypto.hash(:sha256, "kinetix-lab-seed:photo:#{evidence.order_id}")

    assert evidence.signature_sha256 ==
             :crypto.hash(:sha256, "kinetix-lab-seed:signature:#{evidence.order_id}")
  end

  test "refuses a principal no courier has" do
    assert {:error, :unknown_courier} = LabSeed.courier_record(principal(), 3, 30, @now)
  end

  test "refuses a courier an admin has not approved yet" do
    courier = principal()
    _pending = registered_driver_fixture(courier)

    assert {:error, :courier_not_active} = LabSeed.courier_record(courier, 3, 30, @now)
    assert evidence_of(courier) == []
  end

  test "refuses a count or a span out of bounds" do
    courier = principal()
    _driver = active_driver_fixture(courier)

    assert {:error, :invalid_delivery_count} = LabSeed.courier_record(courier, 0, 30, @now)
    assert {:error, :invalid_delivery_count} = LabSeed.courier_record(courier, 1_001, 30, @now)
    assert {:error, :invalid_span} = LabSeed.courier_record(courier, 3, 0, @now)
    assert {:error, :invalid_span} = LabSeed.courier_record(courier, 3, 3_651, @now)
    assert evidence_of(courier) == []
  end

  test "writes only to the lab's database" do
    courier = principal()
    _driver = active_driver_fixture(courier)

    assert LabSeed.lab_database?("kinetix_matching_dev")
    refute LabSeed.lab_database?("kinetix_matching")
    refute LabSeed.lab_database?("kinetix_matching_test")
    assert {:error, :not_a_lab_database} = LabSeed.seed_courier_record(courier, 3, 30)
    assert evidence_of(courier) == []
  end
end
