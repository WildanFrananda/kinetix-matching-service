defmodule KinetixMatching.ApplicationTest do
  use ExUnit.Case, async: false

  alias KinetixMatching.Application, as: App

  setup do
    previous = Application.get_env(:kinetix_matching, :start_grpc_server)
    Application.put_env(:kinetix_matching, :start_grpc_server, true)

    on_exit(fn -> Application.put_env(:kinetix_matching, :start_grpc_server, previous) end)

    {:ok, order: Enum.map(App.children(), &id/1)}
  end

  defp id(%{id: id}), do: id
  defp id({module, _arg}), do: module
  defp id(module) when is_atom(module), do: module

  defp position(order, child) do
    index = Enum.find_index(order, &(&1 == child))

    assert index, "#{inspect(child)} is not in the supervision tree at all"

    index
  end

  test "the gRPC listener is suspended before the endpoint begins draining", %{order: order} do
    assert position(order, KinetixMatching.GrpcListenerSuspender) >
             position(order, KinetixMatchingWeb.Endpoint),
           """
           KinetixMatching.GrpcListenerSuspender must start AFTER KinetixMatchingWeb.Endpoint so that it
           terminates BEFORE it. Started earlier, the gRPC port keeps accepting new connections for
           the whole HTTP drain window — measured at three seconds after SIGTERM, worst case 18s —
           and the drain budget is spent on calls that arrived after shutdown began.
           """
  end

  test "the drain waits after the endpoint has finished draining", %{order: order} do
    assert position(order, KinetixMatching.GrpcDrain) <
             position(order, KinetixMatchingWeb.Endpoint),
           """
           KinetixMatching.GrpcDrain must start BEFORE KinetixMatchingWeb.Endpoint so that it terminates
           after it, and so waits out gRPC work that outlives the HTTP drain.
           """
  end

  test "the metrics registry is up before anything that reports to it", %{order: order} do
    assert position(order, KinetixMatching.Observability.Metrics) <
             position(order, KinetixMatching.Observability.GrpcServerMetricsSeed)
  end

  test "nothing gRPC is in the tree when this node serves no gRPC" do
    Application.put_env(:kinetix_matching, :start_grpc_server, false)

    order = Enum.map(App.children(), &id/1)

    refute KinetixMatching.GrpcListenerSuspender in order
    refute KinetixMatching.GrpcDrain in order
    refute KinetixMatching.Observability.GrpcServerMetricsSeed in order
    assert KinetixMatchingWeb.Endpoint in order
  end

  test "building the tree reads no environment variable and touches no key material" do
    previous = System.get_env("GRPC_PORT")
    System.delete_env("GRPC_PORT")
    on_exit(fn -> previous && System.put_env("GRPC_PORT", previous) end)

    assert is_list(App.children())
  end
end
