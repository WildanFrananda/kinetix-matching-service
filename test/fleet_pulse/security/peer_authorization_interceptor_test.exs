defmodule FleetPulse.Security.PeerAuthorizationInterceptorTest do
  use ExUnit.Case, async: true

  alias FleetPulse.Security.PeerAuthorizationInterceptor, as: Guard

  @registry "fleet.v1.FleetRegistryService"
  @telemetry "fleet.v1.CourierTelemetryService"
  @shipping "shipping.v1.ShippingService"

  defp parse(value) do
    System.put_env("GRPC_ALLOWED_CALLERS", value)
    on_exit(fn -> System.delete_env("GRPC_ALLOWED_CALLERS") end)
    Guard.load_allowed_callers!()
  end

  describe "an empty allow list" do
    test "raises rather than silently refusing every caller" do
      System.put_env("GRPC_ALLOWED_CALLERS", "")
      on_exit(fn -> System.delete_env("GRPC_ALLOWED_CALLERS") end)

      assert_raise RuntimeError, ~r/GRPC_ALLOWED_CALLERS is empty/, fn ->
        Guard.load_allowed_callers!()
      end
    end

    test "raises on a list of nothing but separators" do
      System.put_env("GRPC_ALLOWED_CALLERS", " , , ")
      on_exit(fn -> System.delete_env("GRPC_ALLOWED_CALLERS") end)

      assert_raise RuntimeError, fn -> Guard.load_allowed_callers!() end
    end
  end

  describe "a bare entry" do
    test "may call any service on this endpoint" do
      allowed = parse("order,matching")

      assert Guard.permitted?(allowed, "order", @telemetry)
      assert Guard.permitted?(allowed, "order", @registry)
      assert Guard.permitted?(allowed, "matching", @shipping)
    end

    test "still refuses a caller that is not listed at all" do
      allowed = parse("order")

      refute Guard.permitted?(allowed, "identity", @registry)
      refute Guard.permitted?(allowed, "catalog", @telemetry)
    end

    test "tolerates whitespace around entries" do
      allowed = parse(" order , matching ")

      assert Guard.permitted?(allowed, "order", @telemetry)
      assert Guard.permitted?(allowed, "matching", @telemetry)
    end
  end

  describe "a scoped entry" do
    test "may call only the service it names" do
      allowed = parse("order,identity@#{@registry}")

      assert Guard.permitted?(allowed, "identity", @registry)
      refute Guard.permitted?(allowed, "identity", @telemetry)
      refute Guard.permitted?(allowed, "identity", @shipping)
    end

    test "accumulates when a caller is scoped to more than one service" do
      allowed = parse("identity@#{@registry},identity@#{@shipping}")

      assert Guard.permitted?(allowed, "identity", @registry)
      assert Guard.permitted?(allowed, "identity", @shipping)
      refute Guard.permitted?(allowed, "identity", @telemetry)
    end

    test "does not leak to a different caller" do
      allowed = parse("identity@#{@registry}")

      refute Guard.permitted?(allowed, "order", @registry)
    end
  end

  describe "a caller listed both ways" do
    test "a bare entry wins, whichever order it appears in" do
      before = parse("identity,identity@#{@registry}")
      assert Guard.permitted?(before, "identity", @telemetry)

      System.delete_env("GRPC_ALLOWED_CALLERS")

      after_scoped = parse("identity@#{@registry},identity")
      assert Guard.permitted?(after_scoped, "identity", @telemetry)
    end
  end

  describe "an unknown called service" do
    test "a scoped caller is refused when the called service cannot be named" do
      allowed = parse("identity@#{@registry}")

      refute Guard.permitted?(allowed, "identity", "")
    end

    test "a bare caller is still allowed when the called service cannot be named" do
      allowed = parse("order")

      assert Guard.permitted?(allowed, "order", "")
    end
  end
end
