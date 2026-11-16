defmodule KinetixMatching.Observability.UUIDv7 do
  @moduledoc """
  RFC 9562 UUIDv7 generator using monotonic system time and cryptographic randomness.
  """

  @spec generate() :: String.t()
  def generate do
    unix_ts_ms = System.system_time(:millisecond)
    <<rand_a::12, _::4, rand_b::62, _::2>> = :crypto.strong_rand_bytes(10)

    bytes = <<
      unix_ts_ms::48,
      7::4,
      rand_a::12,
      2::2,
      rand_b::62
    >>

    format(bytes)
  end

  @spec format(<<_::128>>) :: String.t()
  defp format(<<a::32, b::16, c::16, d::16, e::48>>) do
    [
      Base.encode16(<<a::32>>, case: :lower),
      Base.encode16(<<b::16>>, case: :lower),
      Base.encode16(<<c::16>>, case: :lower),
      Base.encode16(<<d::16>>, case: :lower),
      Base.encode16(<<e::48>>, case: :lower)
    ]
    |> Enum.join("-")
  end
end
