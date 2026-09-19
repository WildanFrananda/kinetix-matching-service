defmodule FleetPulse.Tracking.DriverTest do
  use ExUnit.Case, async: true
  alias FleetPulse.Tracking.Driver

  describe "changeset/2" do
    test "valid with a vehicle plate, which is all this row is about" do
      cs = Driver.changeset(%Driver{}, %{vehicle_plate: "B 1234 KIN"})

      assert cs.valid?
    end

    test "refuses a row with no vehicle" do
      cs = Driver.changeset(%Driver{}, %{})

      refute cs.valid?
      assert {"can't be blank", _meta} = cs.errors[:vehicle_plate]
    end

    test "upcases the plate, so two spellings are not two vehicles" do
      cs = Driver.changeset(%Driver{}, %{vehicle_plate: "b 1234 kin"})

      assert Ecto.Changeset.get_change(cs, :vehicle_plate) == "B 1234 KIN"
    end

    test "refuses a capacity beyond any real vehicle" do
      cs = Driver.changeset(%Driver{}, %{vehicle_plate: "B 1 A", capacity_kg: 5_001})

      refute cs.valid?
    end

    test "ignores a name or a phone number in the attributes" do
      cs =
        Driver.changeset(%Driver{}, %{
          vehicle_plate: "B 1 A",
          name: "Somebody",
          phone: "0812345678"
        })

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :name) == nil
      assert Ecto.Changeset.get_change(cs, :phone) == nil
    end
  end

  describe "registration_changeset/3" do
    test "binds the principal from the caller, never from the body" do
      cs =
        Driver.registration_changeset(
          %Driver{},
          %{vehicle_plate: "B 1 A", principal_id: "forged"},
          "from-the-token"
        )

      assert cs.valid?
      assert Ecto.Changeset.get_change(cs, :principal_id) == "from-the-token"
    end

    test "leaves a new registration inactive" do
      cs = Driver.registration_changeset(%Driver{}, %{vehicle_plate: "B 1 A"}, "principal-1")

      assert Ecto.Changeset.get_change(cs, :active) == false
    end

    test "still requires the vehicle" do
      cs = Driver.registration_changeset(%Driver{}, %{}, "principal-1")

      refute cs.valid?
      assert {"can't be blank", _meta} = cs.errors[:vehicle_plate]
    end
  end
end
