defmodule FleetPulse.RuntimeConfigTest do
  use ExUnit.Case, async: false

  @runtime Path.expand("../../config/runtime.exs", __DIR__)
  @required ["ORDER_GRPC_HOST", "KINETIX_TIME_ZONE"]

  setup do
    previous = Map.new(@required, &{&1, System.get_env(&1)})
    on_exit(fn -> Enum.each(previous, &restore/1) end)

    System.put_env("ORDER_GRPC_HOST", "kinetix-order-service:50055")
    System.put_env("KINETIX_TIME_ZONE", "Asia/Jakarta")
    :ok
  end

  defp restore({name, nil}), do: System.delete_env(name)
  defp restore({name, value}), do: System.put_env(name, value)

  defp read, do: Config.Reader.read!(@runtime, env: :dev)

  test "names order's address and the platform's zone when both are set" do
    config = read()

    assert config[:fleet_pulse][FleetPulse.Clients.OrderGrpc][:host] ==
             "kinetix-order-service:50055"

    assert config[:fleet_pulse][:time_zone] == "Asia/Jakarta"
  end

  for name <- @required do
    test "refuses to start without #{name}" do
      System.delete_env(unquote(name))

      assert_raise RuntimeError, ~r/#{unquote(name)} is missing/, &read/0
    end

    test "refuses to start with #{name} set to nothing" do
      System.put_env(unquote(name), "")

      assert_raise RuntimeError, ~r/#{unquote(name)} is missing/, &read/0
    end
  end
end
