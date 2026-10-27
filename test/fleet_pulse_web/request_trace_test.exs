defmodule FleetPulseWeb.RequestTraceTest do
  use FleetPulseWeb.ConnCase, async: false

  import ExUnit.CaptureLog
  import FleetPulse.TrackingFixtures

  alias FleetPulse.IdentityJwks
  alias FleetPulse.Repo
  alias FleetPulse.Security.TokenVerifier

  @earlier_id "kong-earlier-request-0001-aaaaaaaaaaaa"
  @this_id "kong-this-request-0002-bbbbbbbbbbbb"
  @prefix "base64url.bearer.phx."
  @sockets ["/driver/websocket", "/merchant/websocket"]

  defp listen do
    server =
      start_supervised!({Bandit, plug: FleetPulseWeb.Endpoint, port: 0, startup_log: false})

    {:ok, {_address, port}} = ThousandIsland.listener_info(server)
    port
  end

  defp connect(port) do
    {:ok, conn} = Mint.HTTP1.connect(:http, "127.0.0.1", port, mode: :passive)
    conn
  end

  defp exchange(conn, path, headers) do
    {:ok, conn, ref} = Mint.HTTP1.request(conn, "GET", path, headers, nil)
    receive_response(conn, ref, %{status: nil, headers: [], body: "", done: false})
  end

  defp exchange_raising(conn, path, headers) do
    {conn, response} = exchange(conn, path, headers)
    {:error, _conn, %Mint.TransportError{reason: :closed}, []} = Mint.HTTP1.recv(conn, 0, 5_000)
    response
  end

  defp receive_response(conn, _ref, %{done: true} = response), do: {conn, response}

  defp receive_response(conn, ref, response) do
    {:ok, conn, parts} = Mint.HTTP1.recv(conn, 0, 5_000)
    receive_response(conn, ref, Enum.reduce(parts, response, &collect(&1, ref, &2)))
  end

  defp collect({:status, ref, status}, ref, response), do: %{response | status: status}
  defp collect({:headers, ref, headers}, ref, response), do: %{response | headers: headers}

  defp collect({:data, ref, data}, ref, response),
    do: %{response | body: response.body <> data}

  defp collect({:done, ref}, ref, response), do: %{response | done: true}

  defp header(response, name) do
    for {key, value} <- response.headers, String.downcase(key) == name, do: value
  end

  defp trace_id(response), do: Jason.decode!(response.body)["traceId"]

  defp upgrade(token, request_id) do
    [
      {"upgrade", "websocket"},
      {"connection", "Upgrade"},
      {"sec-websocket-key", Base.encode64(:crypto.strong_rand_bytes(16))},
      {"sec-websocket-version", "13"},
      {"origin", "http://localhost"}
    ]
    |> with_token(token)
    |> with_request_id(request_id)
  end

  defp with_token(headers, nil), do: headers

  defp with_token(headers, token) do
    [
      {"sec-websocket-protocol", "phoenix, #{@prefix}#{Base.url_encode64(token, padding: false)}"}
      | headers
    ]
  end

  defp with_request_id(headers, nil), do: headers
  defp with_request_id(headers, id), do: [{"x-request-id", id} | headers]

  defp courier_token, do: IdentityJwks.token(role: "courier", sub: Ecto.UUID.generate())

  defp token_for("/driver/websocket"), do: courier_token()
  defp token_for("/merchant/websocket"), do: IdentityJwks.token(role: "seller")

  defp accepted_token_for("/driver/websocket") do
    principal = Ecto.UUID.generate()
    _driver = active_driver_fixture(principal)
    IdentityJwks.token(role: "courier", sub: principal)
  end

  defp accepted_token_for("/merchant/websocket"), do: IdentityJwks.token(role: "seller")

  defp served_earlier(port) do
    {conn, earlier} =
      port
      |> connect()
      |> exchange("/health", [{"x-request-id", @earlier_id}])

    assert earlier.status == 200
    assert header(earlier, "x-request-id") == [@earlier_id]
    conn
  end

  defp while_the_database_cannot_serve(fun) do
    Repo.checkout(fn -> capture_log(fun) end)
  end

  defp without_the_token_verifier(fun) do
    :ok = Supervisor.terminate_child(FleetPulse.Supervisor, TokenVerifier)

    on_exit(fn ->
      {:ok, _verifier} = Supervisor.restart_child(FleetPulse.Supervisor, TokenVerifier)
    end)

    capture_log(fun)
  end

  describe "a driver handshake the database fails" do
    test "names this request's id, not the one an earlier request left on the connection" do
      port = listen()
      conn = served_earlier(port)

      while_the_database_cannot_serve(fn ->
        response =
          exchange_raising(
            conn,
            "/driver/websocket?vsn=2.0.0",
            upgrade(courier_token(), @this_id)
          )

        assert response.status == 503
        assert trace_id(response) == @this_id
        assert header(response, "x-request-id") == [@this_id]
      end)
    end

    test "names a fresh id when the client sent none, never the earlier request's" do
      port = listen()
      conn = served_earlier(port)

      while_the_database_cannot_serve(fn ->
        response =
          exchange_raising(conn, "/driver/websocket?vsn=2.0.0", upgrade(courier_token(), nil))

        assert response.status == 503
        assert [fresh] = header(response, "x-request-id")
        assert trace_id(response) == fresh
        refute fresh in [@earlier_id, "-"]
      end)
    end

    test "names this request's id on a fresh connection, never a dash" do
      port = listen()

      while_the_database_cannot_serve(fn ->
        for request_id <- [@this_id, nil] do
          response =
            port
            |> connect()
            |> exchange_raising(
              "/driver/websocket?vsn=2.0.0",
              upgrade(courier_token(), request_id)
            )

          assert response.status == 503
          assert [id] = header(response, "x-request-id")
          assert trace_id(response) == id
          assert id != "-"
          assert request_id in [nil, id]
        end
      end)
    end
  end

  for socket <- @sockets do
    describe "a #{socket} handshake that fails unhandled" do
      @socket socket

      test "names this request's id on a connection that served an earlier one" do
        port = listen()

        without_the_token_verifier(fn ->
          response =
            port
            |> served_earlier()
            |> exchange_raising("#{@socket}?vsn=2.0.0", upgrade(token_for(@socket), @this_id))

          assert response.status == 500
          assert trace_id(response) == @this_id
          assert header(response, "x-request-id") == [@this_id]
        end)
      end

      test "names a fresh id on a fresh connection, never a dash" do
        port = listen()

        without_the_token_verifier(fn ->
          response =
            port
            |> connect()
            |> exchange_raising("#{@socket}?vsn=2.0.0", upgrade(token_for(@socket), nil))

          assert response.status == 500
          assert [fresh] = header(response, "x-request-id")
          assert trace_id(response) == fresh
          assert fresh != "-"
        end)
      end
    end

    describe "a #{socket} handshake accepted" do
      @socket socket

      test "carries this request's id in its header" do
        {_conn, response} =
          listen()
          |> served_earlier()
          |> exchange("#{@socket}?vsn=2.0.0", upgrade(accepted_token_for(@socket), @this_id))

        assert response.status == 101
        assert header(response, "x-request-id") == [@this_id]
      end
    end

    describe "a #{socket} handshake refused" do
      @socket socket

      test "carries this request's id in its header" do
        {_conn, response} =
          listen()
          |> served_earlier()
          |> exchange("#{@socket}?vsn=2.0.0", upgrade(nil, @this_id))

        assert response.status == 403
        assert response.body == ""
        assert header(response, "x-request-id") == [@this_id]
      end
    end
  end

  describe "an HTTP request" do
    test "answers an error with its own id on a connection that served an earlier one" do
      port = listen()

      {_conn, response} =
        port
        |> served_earlier()
        |> exchange("/api/v1/no-such-route", [{"x-request-id", @this_id}])

      assert response.status == 404
      assert trace_id(response) == @this_id
      assert header(response, "x-request-id") == [@this_id]
    end

    test "gets a fresh id when the client's is too short to be one" do
      port = listen()

      {_conn, response} =
        port
        |> connect()
        |> exchange("/api/v1/no-such-route", [{"x-request-id", "short"}])

      assert [fresh] = header(response, "x-request-id")
      assert trace_id(response) == fresh
      refute fresh in ["short", "-"]
    end
  end
end
