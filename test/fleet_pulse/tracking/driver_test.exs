defmodule FleetPulse.Tracking.DriverTest do
  use ExUnit.Case, async: true
  alias FleetPulse.Tracking.Driver

  describe "validations" do
    test "valid with required attributes" do
      cs = Driver.changeset(%Driver{}, %{
        name: "Test Driver",
        phone: "0812345678",
        vehicle_plate: "B 1234 KIN"
      })

      assert cs.valid?
    end
  end

  describe "principal_changeset/2" do
    test "links a driver to an identity principal" do
      changeset = Driver.principal_changeset(%Driver{}, %{principal_id: "abc-123"})

      assert changeset.valid?
      assert Ecto.Changeset.get_change(changeset, :principal_id) == "abc-123"
    end

    test "refuses a link with no principal" do
      changeset = Driver.principal_changeset(%Driver{}, %{})

      refute changeset.valid?
      assert {"can't be blank", _meta} = changeset.errors[:principal_id]
    end
  end
end
