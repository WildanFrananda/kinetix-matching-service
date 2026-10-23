defmodule FleetPulseWeb.SocketAuthTokenTest do
  use FleetPulseWeb.ConnCase, async: false

  import FleetPulse.TrackingFixtures

  alias FleetPulse.IdentityJwks

  @prefix "base64url.bearer.phx."

  defp upgrade(path, subprotocols) do
    server =
      start_supervised!({Bandit, plug: FleetPulseWeb.Endpoint, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    {:ok, socket} = :gen_tcp.connect(~c"127.0.0.1", port, [:binary, active: false, packet: :raw])

    request =
      "GET #{path} HTTP/1.1\r\n" <>
        "Host: localhost:#{port}\r\n" <>
        "Upgrade: websocket\r\n" <>
        "Connection: Upgrade\r\n" <>
        "Sec-WebSocket-Key: #{Base.encode64(:crypto.strong_rand_bytes(16))}\r\n" <>
        "Sec-WebSocket-Version: 13\r\n" <>
        "Sec-WebSocket-Protocol: #{subprotocols}\r\n" <>
        "Origin: http://localhost\r\n\r\n"

    :ok = :gen_tcp.send(socket, request)
    {:ok, response} = :gen_tcp.recv(socket, 0, 5_000)
    :ok = :gen_tcp.close(socket)

    response
  end

  defp status_line(response), do: response |> String.split("\r\n") |> hd()

  defp courier_token do
    principal = "principal-#{System.unique_integer([:positive])}"
    _driver = active_driver_fixture(principal)
    IdentityJwks.token(role: "courier", sub: principal)
  end

  defp as_the_courier_app_sends_it(token), do: Base.encode64(token, padding: false)

  test "a token entry that is not base64 at all is refused 403, not answered 500" do
    for socket <- ["/driver/websocket", "/merchant/websocket"] do
      response = upgrade(socket, "phoenix, #{@prefix}not*base64")

      assert status_line(response) == "HTTP/1.1 403 Forbidden", socket
    end
  end

  test "a token entry only base64url can read is refused 403, not answered 500" do
    encoded = Base.url_encode64(<<0xFB, 0xFF, 0xBF>>, padding: false)

    assert encoded =~ ~r/[-_]/

    assert status_line(upgrade("/driver/websocket", "phoenix, #{@prefix}#{encoded}")) ==
             "HTTP/1.1 403 Forbidden"
  end

  test "the courier app's encoding of a real token is accepted, and phoenix is the protocol" do
    token = courier_token()

    response =
      upgrade(
        "/driver/websocket?vsn=2.0.0",
        "phoenix, #{@prefix}#{as_the_courier_app_sends_it(token)}"
      )

    assert status_line(response) == "HTTP/1.1 101 Switching Protocols"
    assert response =~ ~r/sec-websocket-protocol: phoenix\r\n/i
  end

  test "the same token in base64url, padded or not, is the same entry" do
    token = courier_token()

    for encoded <- [Base.url_encode64(token, padding: false), Base.url_encode64(token)] do
      response = upgrade("/driver/websocket?vsn=2.0.0", "phoenix, #{@prefix}#{encoded}")

      assert status_line(response) == "HTTP/1.1 101 Switching Protocols"
    end
  end

  test "an access token encodes to the same text in the standard alphabet and in base64url" do
    for role <- ["courier", "seller", "admin"], _attempt <- 1..20 do
      token = IdentityJwks.token(role: role, sub: Ecto.UUID.generate())

      assert Base.encode64(token, padding: false) == Base.url_encode64(token, padding: false)
    end
  end
end
