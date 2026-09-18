defmodule FleetPulse.Observability.GrpcClientMetricsSeedTest do
  use ExUnit.Case, async: false

  alias FleetPulse.Observability.GrpcClientMetricsSeed
  alias FleetPulse.Observability.Metrics

  @registry :grpc_client_metrics_seed_test
  @family "kinetix_grpc_client_calls_total"

  setup do
    start_supervised!(
      {TelemetryMetricsPrometheus.Core,
       name: @registry, metrics: Metrics.definitions(), start_async: false}
    )

    :ok
  end

  defp scrape, do: TelemetryMetricsPrometheus.Core.scrape(@registry)

  defp series(body) do
    body
    |> String.split("\n")
    |> Enum.filter(&String.starts_with?(&1, @family <> "{"))
  end

  test "the family appears in the scrape before any call has been placed" do
    refute scrape() =~ @family

    GrpcClientMetricsSeed.seed()

    assert scrape() =~ @family
  end

  test "every seeded series says zero, because no call has been placed" do
    GrpcClientMetricsSeed.seed()

    lines = series(scrape())
    refute lines == []

    for line <- lines do
      assert String.ends_with?(line, "} 0"),
             "the seed published a call that never happened: #{line}"
    end
  end

  test "the seed names the peer and method the client actually dials" do
    GrpcClientMetricsSeed.seed()
    body = scrape()

    for {peer, method} <- GrpcClientMetricsSeed.calls() do
      assert body =~ ~s(peer="#{peer}"), "#{peer} was not published"
      assert body =~ ~s(grpc_method="#{method}"), "#{method} was not published"
    end
  end

  test "the seeded labels are the ones the client emits" do
    source = File.read!("lib/fleet_pulse/clients/payment_grpc.ex")

    for {peer, method} <- GrpcClientMetricsSeed.calls() do
      assert source =~ ~s("#{peer}"), "the client does not use peer #{peer}"
      assert source =~ ~s("#{method}"), "the client does not use method #{method}"
    end
  end
end
