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

  describe "in production" do
    @production %{
      "DATABASE_URL" => "ecto://matching:not-a-secret@localhost/kinetix_matching",
      "SECRET_KEY_BASE" => String.duplicate("not_a_deployed_secret_", 4),
      "OBJECT_STORE_ENDPOINT" => "http://object-store.test:9000",
      "OBJECT_STORE_PUBLIC_URL" => "https://storage.kinetix.test",
      "OBJECT_STORE_POD_BUCKET" => "kinetix-pod",
      "OBJECT_STORE_REGION" => "us-east-1",
      "OBJECT_STORE_ACCESS_KEY" => "test-access-key",
      "OBJECT_STORE_SECRET_KEY" => "test-secret-key",
      "PHX_HOST" => "api.kinetix.test"
    }

    setup do
      previous = Map.new(@production, fn {name, _value} -> {name, System.get_env(name)} end)
      on_exit(fn -> Enum.each(previous, &restore/1) end)

      Enum.each(@production, fn {name, value} -> System.put_env(name, value) end)
      :ok
    end

    defp read_production, do: Config.Reader.read!(@runtime, env: :prod)

    test "the endpoint's public host is PHX_HOST" do
      endpoint = read_production()[:fleet_pulse][FleetPulseWeb.Endpoint]

      assert endpoint[:url] == [host: "api.kinetix.test", port: 443, scheme: "https"]
    end

    test "refuses to start without PHX_HOST, rather than serving as example.com" do
      System.delete_env("PHX_HOST")

      assert_raise RuntimeError, ~r/PHX_HOST is missing/, &read_production/0
    end

    test "refuses to start with PHX_HOST set to nothing" do
      System.put_env("PHX_HOST", "")

      assert_raise RuntimeError, ~r/PHX_HOST is missing/, &read_production/0
    end
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
