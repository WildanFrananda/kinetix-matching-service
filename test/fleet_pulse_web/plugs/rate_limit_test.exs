defmodule FleetPulseWeb.Plugs.RateLimitTest do
  use FleetPulseWeb.ConnCase, async: false

  alias FleetPulseWeb.Plugs.RateLimit

  setup do
    previous = Application.get_env(:fleet_pulse, RateLimit)
    Application.put_env(:fleet_pulse, RateLimit, enabled: true, scale_ms: 60_000, login: 2)
    on_exit(fn -> Application.put_env(:fleet_pulse, RateLimit, previous) end)
    :ok
  end

  defp unique_ip, do: {10, 0, 0, rem(System.unique_integer([:positive]), 250) + 1}

  defp hit(ip) do
    conn = %{build_conn() | remote_ip: ip}
    RateLimit.call(conn, RateLimit.init(bucket: :login))
  end

  test "allows up to the limit, then returns 429" do
    ip = unique_ip()

    refute hit(ip).halted
    refute hit(ip).halted

    denied = hit(ip)
    assert denied.halted
    assert json_response(denied, 429)["error"] == "rate_limited"
  end

  test "counts each IP separately" do
    denied = %{build_conn() | remote_ip: unique_ip()}

    ip = unique_ip()
    hit(ip)
    hit(ip)
    assert hit(ip).halted

    fresh = RateLimit.call(denied, RateLimit.init(bucket: :login))
    refute fresh.halted
  end

  test "is a no-op when disabled" do
    Application.put_env(:fleet_pulse, RateLimit, enabled: false)
    ip = unique_ip()

    for _ <- 1..10, do: refute(hit(ip).halted)
  end
end
