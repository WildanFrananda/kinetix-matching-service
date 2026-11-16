defmodule KinetixMatching.Tracking.RedisPositionPublisher do
  @moduledoc """
  Publishes live courier position updates to Redis Pub/Sub (`matching:position:<orderNumber>`)
  using a lightweight RESP2 TCP client so downstream edge subscriptions receive latest-wins
  updates without adding external dependency churn.
  """

  @behaviour KinetixMatching.Tracking.PositionPublisher

  use GenServer

  require Logger

  @connect_timeout_ms 2_000
  @recv_timeout_ms 2_000

  @type t :: %__MODULE__{
          enabled: boolean(),
          host: String.t() | nil,
          port: :inet.port_number() | nil,
          username: String.t() | nil,
          password: String.t() | nil,
          socket: :gen_tcp.socket() | nil
        }

  defstruct [:host, :port, :username, :password, :socket, enabled: false]

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    GenServer.start_link(__MODULE__, opts, name: __MODULE__)
  end

  @impl KinetixMatching.Tracking.PositionPublisher
  @spec publish_position(String.t(), map()) :: :ok | {:error, term()}
  def publish_position(order_number, envelope) do
    case Process.whereis(__MODULE__) do
      nil -> :ok
      pid -> GenServer.cast(pid, {:publish, "matching:position:#{order_number}", envelope})
    end
  end

  @spec publish_sync(GenServer.server(), String.t(), map()) :: :ok | {:error, term()}
  def publish_sync(server \\ __MODULE__, order_number, envelope) do
    GenServer.call(server, {:publish, "matching:position:#{order_number}", envelope}, 5_000)
  end

  @spec encode_command([String.t()]) :: binary()
  def encode_command(parts) do
    header = "*#{length(parts)}\r\n"

    body =
      Enum.map_join(parts, fn part ->
        bin = to_string(part)
        "$#{byte_size(bin)}\r\n#{bin}\r\n"
      end)

    header <> body
  end

  @impl GenServer
  @spec init(keyword()) :: {:ok, t()}
  def init(opts) do
    config = Application.get_env(:kinetix_matching, __MODULE__, []) ++ opts

    state =
      case Keyword.get(config, :host) do
        host when is_binary(host) and host != "" ->
          %__MODULE__{
            enabled: true,
            host: host,
            port: Keyword.fetch!(config, :port),
            username: Keyword.get(config, :username),
            password: Keyword.get(config, :password)
          }

        _unconfigured ->
          %__MODULE__{enabled: false}
      end

    {:ok, state}
  end

  @impl GenServer
  @spec handle_cast({:publish, String.t(), map()}, t()) :: {:noreply, t()}
  def handle_cast({:publish, channel, envelope}, state) do
    {_reply, next_state} = do_publish(channel, envelope, state)
    {:noreply, next_state}
  end

  @impl GenServer
  @spec handle_call({:publish, String.t(), map()}, GenServer.from(), t()) ::
          {:reply, :ok | {:error, term()}, t()}
  def handle_call({:publish, channel, envelope}, _from, state) do
    {reply, next_state} = do_publish(channel, envelope, state)
    {:reply, reply, next_state}
  end

  @impl GenServer
  @spec terminate(term(), t()) :: :ok
  def terminate(_reason, %__MODULE__{socket: socket}) when not is_nil(socket) do
    :ok = :gen_tcp.close(socket)
  end

  def terminate(_reason, _state), do: :ok

  @spec do_publish(String.t(), map(), t()) :: {:ok | {:error, term()}, t()}
  defp do_publish(_channel, _envelope, %__MODULE__{enabled: false} = state) do
    {:ok, state}
  end

  defp do_publish(channel, envelope, %__MODULE__{} = state) do
    with {:ok, payload} <- Jason.encode(envelope),
         {:ok, connected} <- ensure_connected(state),
         {:ok, next_state} <- send_publish(connected, channel, payload) do
      {:ok, next_state}
    else
      {:error, reason} ->
        Logger.warning("redis position publish failed",
          channel: channel,
          reason: inspect(reason)
        )

        {{:error, reason}, close_socket(state)}
    end
  end

  @spec ensure_connected(t()) :: {:ok, t()} | {:error, term()}
  defp ensure_connected(%__MODULE__{socket: socket} = state) when not is_nil(socket),
    do: {:ok, state}

  defp ensure_connected(%__MODULE__{host: host, port: port} = state) do
    host_charlist = String.to_charlist(host)

    with {:ok, socket} <-
           :gen_tcp.connect(
             host_charlist,
             port,
             [:binary, active: false, packet: :line],
             @connect_timeout_ms
           ),
         :ok <- authenticate(socket, state.username, state.password) do
      {:ok, %{state | socket: socket}}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @spec authenticate(:gen_tcp.socket(), String.t() | nil, String.t() | nil) ::
          :ok | {:error, term()}
  defp authenticate(_socket, _username, nil), do: :ok
  defp authenticate(_socket, _username, ""), do: :ok

  defp authenticate(socket, username, password)
       when is_binary(username) and username != "" do
    send_and_expect_ok(socket, ["AUTH", username, password])
  end

  defp authenticate(socket, _username, password) do
    send_and_expect_ok(socket, ["AUTH", password])
  end

  @spec send_and_expect_ok(:gen_tcp.socket(), [String.t()]) :: :ok | {:error, term()}
  defp send_and_expect_ok(socket, parts) do
    with :ok <- :gen_tcp.send(socket, encode_command(parts)),
         {:ok, "+OK\r\n"} <- :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
      :ok
    else
      {:ok, line} -> {:error, {:redis_error, String.trim(line)}}
      {:error, reason} -> {:error, reason}
    end
  end

  @spec send_publish(t(), String.t(), String.t()) :: {:ok, t()} | {:error, term()}
  defp send_publish(%__MODULE__{socket: socket} = state, channel, payload) do
    with :ok <- :gen_tcp.send(socket, encode_command(["PUBLISH", channel, payload])),
         {:ok, ":" <> _rest} <- :gen_tcp.recv(socket, 0, @recv_timeout_ms) do
      {:ok, state}
    else
      {:ok, line} ->
        _ = close_socket(state)
        {:error, {:redis_error, String.trim(line)}}

      {:error, reason} ->
        _ = close_socket(state)
        {:error, reason}
    end
  end

  @spec close_socket(t()) :: t()
  defp close_socket(%__MODULE__{socket: nil} = state), do: state

  defp close_socket(%__MODULE__{socket: socket} = state) do
    :ok = :gen_tcp.close(socket)
    %{state | socket: nil}
  end
end
