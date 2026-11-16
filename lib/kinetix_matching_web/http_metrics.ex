defmodule KinetixMatchingWeb.HttpMetrics do
  @moduledoc """
  Times and counts every request this endpoint answers, under the estate's names.
  """

  alias KinetixMatching.Observability.Metrics
  alias Plug.Conn

  @methods ~w(GET HEAD POST PUT PATCH DELETE OPTIONS TRACE CONNECT)
  @other_method "OTHER"
  @unmatched "unmatched"
  @unknown_status "unknown"

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        conn
        |> KinetixMatchingWeb.HttpMetrics.watch(__MODULE__)
        |> super(opts)
      end
    end
  end

  @spec watch(Conn.t(), module()) :: Conn.t()
  def watch(conn, endpoint) do
    start = System.monotonic_time()

    Conn.register_before_send(conn, &record(&1, start, endpoint))
  end

  @spec record(Conn.t(), integer(), module()) :: Conn.t()
  defp record(conn, start, endpoint) do
    :telemetry.execute(
      Metrics.http_stop_event(),
      %{duration: System.monotonic_time() - start},
      %{
        method: method(conn.method),
        route: route(conn, endpoint),
        status: status(conn.status)
      }
    )

    conn
  end

  @spec route(Conn.t(), module()) :: String.t()
  defp route(conn, _endpoint) do
    KinetixMatchingWeb.Router
    |> Phoenix.Router.route_info(conn.method, conn.path_info, conn.host)
    |> template(conn.path_info)
  end

  @spec template(map() | :error, [String.t()]) :: String.t()
  defp template(%{route: route}, _path_info) when is_binary(route), do: braced(route)
  defp template(_no_route, ["ws", "v1", "events"]), do: "/ws/v1/events"
  defp template(_no_route, _path_info), do: @unmatched

  @spec braced(String.t()) :: String.t()
  defp braced(route), do: route |> String.split("/") |> Enum.map_join("/", &segment/1)

  @spec segment(String.t()) :: String.t()
  defp segment(":" <> name), do: "{#{name}}"
  defp segment("*" <> name), do: "{#{name}}"
  defp segment(literal), do: literal

  @spec status(non_neg_integer() | nil) :: String.t()
  defp status(status) when is_integer(status), do: Integer.to_string(status)
  defp status(_unset), do: @unknown_status

  @spec method(String.t()) :: String.t()
  defp method(method) when method in @methods, do: method
  defp method(_other), do: @other_method
end
