defmodule KinetixMatching.OrderServiceDoubleEndpoint do
  @moduledoc """
  Serves `KinetixMatching.OrderServiceDouble`.
  """

  use GRPC.Endpoint

  run(KinetixMatching.OrderServiceDouble)
end
