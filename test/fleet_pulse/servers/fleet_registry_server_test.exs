defmodule FleetPulse.Servers.FleetRegistryServerTest do
  use FleetPulse.DataCase, async: false

  alias FleetPulse.Proto.Fleet.V1.ActivateDriverRequest
  alias FleetPulse.Proto.Fleet.V1.RegisterDriverRequest
  alias FleetPulse.Servers.FleetRegistryServer
  alias FleetPulse.Tracking

  defp principal, do: "principal-#{System.unique_integer([:positive])}"
  defp plate, do: "B #{System.unique_integer([:positive])} REG"

  defp register(overrides \\ %{}) do
    attrs =
      Map.merge(%{principal_id: principal(), vehicle_plate: plate(), capacity_kg: 150}, overrides)

    FleetRegistryServer.register_driver(struct!(RegisterDriverRequest, attrs), nil)
  end

  defp activate(principal_id) do
    FleetRegistryServer.activate_driver(%ActivateDriverRequest{principal_id: principal_id}, nil)
  end

  describe "RegisterDriver" do
    test "files a vehicle and hands back the id the socket topic is named after" do
      sub = principal()

      res = register(%{principal_id: sub, vehicle_plate: "b 77 low"})

      assert res.success
      assert res.driver_id > 0
      refute res.already_registered
      assert {:ok, driver} = Tracking.fetch_driver(res.driver_id)
      assert driver.principal_id == sub
      assert driver.vehicle_plate == "B 77 LOW"
    end

    test "leaves the new driver inactive" do
      res = register()

      assert {:ok, driver} = Tracking.fetch_driver(res.driver_id)
      refute driver.active
    end

    test "a repeated call is the same row, flagged as already registered" do
      sub = principal()

      first = register(%{principal_id: sub})
      again = register(%{principal_id: sub})

      assert first.success and again.success
      assert again.driver_id == first.driver_id
      refute first.already_registered
      assert again.already_registered
    end

    test "a repeated call with a different vehicle does not silently change the vehicle" do
      sub = principal()

      first = register(%{principal_id: sub, vehicle_plate: "B 1 FIRST"})
      again = register(%{principal_id: sub, vehicle_plate: "B 2 SECOND"})

      assert again.driver_id == first.driver_id
      assert {:ok, driver} = Tracking.fetch_driver(again.driver_id)
      assert driver.vehicle_plate == "B 1 FIRST"
    end

    test "refuses a request with no principal" do
      res = register(%{principal_id: ""})

      refute res.success
      assert res.error.error_code == "BLANK_PRINCIPAL"
    end

    test "refuses a request with no vehicle plate" do
      res = register(%{vehicle_plate: "   "})

      refute res.success
      assert res.error.error_code == "BLANK_VEHICLE_PLATE"
    end

    test "refuses a capacity of zero, which is also what an unset field looks like" do
      res = register(%{capacity_kg: 0})

      refute res.success
      assert res.error.error_code == "NO_CAPACITY"
    end

    test "writes nothing when it refuses" do
      sub = principal()

      res = register(%{principal_id: sub, capacity_kg: 0})

      refute res.success
      assert {:error, :unlinked} = Tracking.driver_for_principal(sub)
    end
  end

  describe "ActivateDriver" do
    test "lets an approved driver work" do
      sub = principal()
      registered = register(%{principal_id: sub})

      res = activate(sub)

      assert res.success
      assert res.driver_id == registered.driver_id
      refute res.already_active
      assert {:ok, driver} = Tracking.driver_for_principal(sub)
      assert driver.active
    end

    test "approving twice is reported, not refused" do
      sub = principal()
      register(%{principal_id: sub})

      first = activate(sub)
      again = activate(sub)

      assert first.success and again.success
      refute first.already_active
      assert again.already_active
      assert again.driver_id == first.driver_id
    end

    test "refuses a principal with no vehicle filed" do
      res = activate(principal())

      refute res.success
      assert res.error.error_code == "NO_DRIVER_RECORD"
    end

    test "refuses a blank principal" do
      res = activate("")

      refute res.success
      assert res.error.error_code == "BLANK_PRINCIPAL"
    end
  end
end
