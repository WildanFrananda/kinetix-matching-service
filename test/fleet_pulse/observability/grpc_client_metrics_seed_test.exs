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

  test "every seeded label belongs to a client that really dials it" do
    sources = client_sources()

    for {peer, method} <- GrpcClientMetricsSeed.calls() do
      owners =
        Enum.filter(sources, fn {_path, source} ->
          source =~ ~s("#{peer}") and source =~ ~s("#{method}")
        end)

      assert owners != [],
             "the seed publishes peer #{peer} method #{method}, and no client under " <>
               "lib/fleet_pulse/clients declares both — a label nothing will ever emit"
    end
  end

  test "every gRPC client this service has is seeded" do
    seeded = MapSet.new(GrpcClientMetricsSeed.calls())

    for {path, source} <- client_sources() do
      peer = attribute!(source, path, ~r/@peer\s+"([^"]+)"/, "@peer")
      method = attribute!(source, path, ~r/@method\s+"([^"]+)"/, "@method")

      assert MapSet.member?(seeded, {peer, method}),
             "#{path} dials peer #{peer} method #{method}, and GrpcClientMetricsSeed does not " <>
               "publish it. Add it to @calls, or the counter stays absent until something fails."
    end
  end

  @spec client_sources() :: [{String.t(), String.t()}]
  defp client_sources do
    sources =
      "lib/fleet_pulse/clients/*_grpc.ex"
      |> Path.wildcard()
      |> Enum.map(fn path -> {path, File.read!(path)} end)

    assert sources != [],
           "no gRPC client sources matched lib/fleet_pulse/clients/*_grpc.ex; this test would " <>
             "otherwise pass by examining nothing"

    sources
  end

  @spec attribute!(String.t(), String.t(), Regex.t(), String.t()) :: String.t()
  defp attribute!(source, path, pattern, name) do
    case Regex.run(pattern, source) do
      [_whole, value] ->
        value

      nil ->
        flunk(
          "#{path} is a gRPC client with no #{name} attribute, so its metric cannot be seeded"
        )
    end
  end
end
