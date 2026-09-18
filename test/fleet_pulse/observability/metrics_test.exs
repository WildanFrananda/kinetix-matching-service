defmodule FleetPulse.Observability.MetricsTest do
  use ExUnit.Case, async: true

  alias FleetPulse.Observability.Metrics

  test "every outbound gRPC client is counted, as the estate's metrics contract requires" do
    callers =
      "lib/**/*.ex"
      |> Path.wildcard()
      |> Enum.reject(&String.starts_with?(&1, "lib/fleet_pulse/proto/"))
      |> Enum.filter(&(&1 |> File.read!() |> String.contains?("GRPC.Stub.")))

    refute callers == [],
           "this test is about outbound clients and found none; if that is now true, invert it back"

    registered =
      Metrics.definitions()
      |> Enum.map(& &1.name)
      |> Enum.map(&Enum.join(&1, "."))

    assert "kinetix.grpc.client.calls.total" in registered,
           """
           #{inspect(callers)} dials another service, so
           kinetix_grpc_client_calls_total{peer, grpc_method, grpc_code} must be registered in
           FleetPulse.Observability.Metrics and emitted where the call is made.
           """

    for caller <- callers do
      assert File.read!(caller) =~ "grpc_client_call_event",
             "#{caller} makes a gRPC call but never counts it"
    end
  end

  test "the scrape carries the contract's names and no others of its own invention" do
    {:ok, body} = Metrics.scrape()

    assert body =~ "kinetix_build_info"
    refute body =~ "vm_memory"
    refute body =~ "phoenix_"
  end
end
