defmodule KinetixMatching.Observability.UUIDv7Test do
  use ExUnit.Case, async: true

  alias KinetixMatching.Observability.UUIDv7

  test "generates valid RFC 9562 version 7 UUIDs" do
    uuid = UUIDv7.generate()

    assert Regex.match?(
             ~r/^[0-9a-f]{8}-[0-9a-f]{4}-7[0-9a-f]{3}-[89ab][0-9a-f]{3}-[0-9a-f]{12}$/,
             uuid
           )
  end

  test "generates unique values across consecutive calls" do
    uuids = for _ <- 1..100, do: UUIDv7.generate()
    assert length(Enum.uniq(uuids)) == 100
  end
end
