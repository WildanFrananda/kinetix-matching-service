defmodule FleetPulseWeb.SocketAuthToken do
  @moduledoc """
  Refuses with 403 a socket upgrade whose `base64url.bearer.phx.` subprotocol entry is not base64url
  that Phoenix's own decoder reads as the same bytes. Phoenix decodes the entry with
  `Base.decode64!/2`, which raises on anything else, and that raise was answered 500.
  """

  alias Plug.Conn

  @prefix "base64url.bearer.phx."
  @transport "websocket"

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        case FleetPulseWeb.SocketAuthToken.screen(conn, __MODULE__) do
          %Plug.Conn{halted: true} = refused -> refused
          screened -> super(screened, opts)
        end
      end
    end
  end

  @spec screen(Conn.t(), module()) :: Conn.t()
  def screen(%Conn{method: "GET", path_info: path_info} = conn, endpoint) do
    if token_socket?(path_info, endpoint), do: screen_token(conn), else: conn
  end

  def screen(conn, _endpoint), do: conn

  @spec token_socket?([String.t()], module()) :: boolean()
  defp token_socket?(path_info, endpoint) do
    Enum.any?(endpoint.__sockets__(), &upgrade_path?(&1, path_info))
  end

  @spec upgrade_path?({String.t(), module(), keyword()}, [String.t()]) :: boolean()
  defp upgrade_path?({path, _socket, opts}, path_info) do
    upgrade = String.split(path, "/", trim: true) ++ [@transport]
    Keyword.get(opts, :auth_token, false) and upgrade == path_info
  end

  @spec screen_token(Conn.t()) :: Conn.t()
  defp screen_token(conn) do
    conn
    |> Conn.get_req_header("sec-websocket-protocol")
    |> token_entries()
    |> verdict(conn)
  end

  @spec token_entries([String.t()]) :: [String.t()]
  defp token_entries([header | _later_headers]) do
    header
    |> Conn.Utils.list()
    |> Enum.filter(&String.starts_with?(&1, @prefix))
  end

  defp token_entries([]), do: []

  @spec verdict([String.t()], Conn.t()) :: Conn.t()
  defp verdict([@prefix <> encoded], conn) do
    if readable?(encoded), do: conn, else: refuse(conn)
  end

  defp verdict(_none_or_several, conn), do: conn

  @spec readable?(String.t()) :: boolean()
  defp readable?(encoded) do
    match?({:ok, _token}, Base.url_decode64(encoded, padding: false)) and
      match?({:ok, _token}, Base.decode64(encoded, padding: false))
  end

  @spec refuse(Conn.t()) :: Conn.t()
  defp refuse(conn) do
    conn
    |> Conn.send_resp(403, "")
    |> Conn.halt()
  end
end
