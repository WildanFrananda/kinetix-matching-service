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

  describe "valid_password?/2" do
    test "true for the right password, false for the wrong one" do
      driver = %Driver{hashed_password: Bcrypt.hash_pwd_salt("fixture-only-never-a-real-credential")}

      assert Driver.valid_password?(driver, "fixture-only-never-a-real-credential")
      refute Driver.valid_password?(driver, "nope")
    end

    test "false when the driver has no password set" do
      refute Driver.valid_password?(%Driver{hashed_password: nil}, "anything")
    end
  end
end
