defmodule KinetixMatchingWeb.EventSocketPlugTest do
  use KinetixMatchingWeb.ConnCase, async: false

  import Bitwise
  import KinetixMatching.TrackingFixtures

  alias KinetixMatching.Dispatch
  alias KinetixMatching.IdentityJwks
  alias KinetixMatching.Tracking

  defp open_ws(path, headers \\ []) do
    server =
      start_supervised!({Bandit, plug: KinetixMatchingWeb.Endpoint, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    extra_headers =
      Enum.map_join(headers, "", fn {name, value} -> "#{name}: #{value}\r\n" end)

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: localhost:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{Base.encode64(:crypto.strong_rand_bytes(16))}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        extra_headers <> "\r\n"

    :ok = :gen_tcp.send(socket, request)
    {:ok, socket}
  end

  defp read_http_and_initial_frames(socket) do
    {:ok, chunk} = :gen_tcp.recv(socket, 0, 5_000)

    case String.split(chunk, "\r\n\r\n", parts: 2) do
      [head, rest] -> {head, rest}
      [head] -> {head, <<>>}
    end
  end

  defp send_masked_text_frame(socket, payload) do
    mask = :crypto.strong_rand_bytes(4)
    len = byte_size(payload)
    header = <<1::1, 0::3, 1::4, 1::1, len::7>>

    masked =
      payload
      |> :binary.bin_to_list()
      |> Enum.with_index()
      |> Enum.map(fn {byte, idx} ->
        bxor(byte, :binary.at(mask, rem(idx, 4)))
      end)
      |> :erlang.list_to_binary()

    :gen_tcp.send(socket, header <> mask <> masked)
  end

  defp decode_next_text_frame(socket, buffer \\ <<>>) do
    case parse_ws_frame(buffer) do
      {:ok, payload, rest} ->
        {Jason.decode!(payload), rest}

      :incomplete ->
        {:ok, more} = :gen_tcp.recv(socket, 0, 5_000)
        decode_next_text_frame(socket, buffer <> more)
    end
  end

  defp parse_ws_frame(<<_fin_opcode::8, 0::1, len::7, payload::binary-size(len), rest::binary>>)
       when len < 126 do
    {:ok, payload, rest}
  end

  defp parse_ws_frame(
         <<_fin_opcode::8, 0::1, 126::7, len::16, payload::binary-size(len), rest::binary>>
       ) do
    {:ok, payload, rest}
  end

  defp parse_ws_frame(_incomplete), do: :incomplete

  defp courier_token do
    principal = "principal-#{System.unique_integer([:positive])}"
    driver = active_driver_fixture(principal)
    {driver, IdentityJwks.token(role: "courier", sub: principal)}
  end

  test "upgrades with Authorization Bearer token, pushes snapshot, and answers system.ping" do
    {driver, token} = courier_token()
    on_exit(fn -> _ = Tracking.stop_tracking(driver.id) end)

    {:ok, socket} = open_ws("/ws/v1/events", [{"Authorization", "Bearer #{token}"}])
    {head, rest} = read_http_and_initial_frames(socket)
    assert head =~ "HTTP/1.1 101 Switching Protocols"

    {snapshot, leftover} = decode_next_text_frame(socket, rest)
    assert snapshot["event"] == "matching.job.snapshot"
    assert snapshot["schemaVersion"] == 1
    assert snapshot["data"]["dutyStatus"] == "offline"
    assert snapshot["data"]["activeOrder"] == nil

    ping =
      Jason.encode!(%{
        event: "system.ping",
        requestId: "req-ws-1",
        schemaVersion: 1,
        data: %{}
      })

    :ok = send_masked_text_frame(socket, ping)
    {pong, _rest} = decode_next_text_frame(socket, leftover)
    assert pong["event"] == "system.pong"
    assert pong["requestId"] == "req-ws-1"
    assert is_binary(pong["data"]["serverTime"])

    :ok = :gen_tcp.close(socket)
  end

  test "refuses seller token cleanly on handshake and delivers active orders snapshot" do
    merchant_id = "seller-#{System.unique_integer([:positive])}"

    {:ok, order} =
      Dispatch.create_order(%{
        pickup_latitude: -6.2,
        pickup_longitude: 106.8,
        dropoff_latitude: -6.21,
        dropoff_longitude: 106.81,
        merchant_principal_id: merchant_id,
        order_number: "ORD-#{System.unique_integer([:positive])}"
      })

    token = IdentityJwks.token(role: "seller", sub: merchant_id)
    {:ok, socket} = open_ws("/ws/v1/events", [{"Authorization", "Bearer #{token}"}])
    {head, rest} = read_http_and_initial_frames(socket)
    assert head =~ "HTTP/1.1 101 Switching Protocols"

    {snapshot, _rest} = decode_next_text_frame(socket, rest)
    assert snapshot["event"] == "matching.job.snapshot"
    assert [pushed] = snapshot["data"]["orders"]
    assert pushed["id"] == order.id
    assert pushed["orderNumber"] == order.order_number
    assert pushed["eventSequence"] == 1

    :ok = :gen_tcp.close(socket)
  end

  test "rejects missing or invalid bearer tokens with 401" do
    {:ok, no_header} = open_ws("/ws/v1/events")
    {head1, _} = read_http_and_initial_frames(no_header)
    assert head1 =~ "HTTP/1.1 401 Unauthorized"
    :ok = :gen_tcp.close(no_header)

    {:ok, bad_token} = open_ws("/ws/v1/events", [{"Authorization", "Bearer nope"}])
    {head2, _} = read_http_and_initial_frames(bad_token)
    assert head2 =~ "HTTP/1.1 401 Unauthorized"
    :ok = :gen_tcp.close(bad_token)
  end

  test "rejects customer role, unlinked courier, and pending approval with 403" do
    customer = IdentityJwks.token(role: "customer", sub: "cust-1")
    {:ok, s1} = open_ws("/ws/v1/events", [{"Authorization", "Bearer #{customer}"}])
    {h1, _} = read_http_and_initial_frames(s1)
    assert h1 =~ "HTTP/1.1 403 Forbidden"
    :ok = :gen_tcp.close(s1)

    unlinked = IdentityJwks.token(role: "courier", sub: "principal-unknown")
    {:ok, s2} = open_ws("/ws/v1/events", [{"Authorization", "Bearer #{unlinked}"}])
    {h2, _} = read_http_and_initial_frames(s2)
    assert h2 =~ "HTTP/1.1 403 Forbidden"
    :ok = :gen_tcp.close(s2)

    pending_principal = "pending-#{System.unique_integer([:positive])}"
    _pending = registered_driver_fixture(pending_principal)
    pending_tok = IdentityJwks.token(role: "courier", sub: pending_principal)
    {:ok, s3} = open_ws("/ws/v1/events", [{"Authorization", "Bearer #{pending_tok}"}])
    {h3, _} = read_http_and_initial_frames(s3)
    assert h3 =~ "HTTP/1.1 403 Forbidden"
    :ok = :gen_tcp.close(s3)
  end
end
