defmodule FleetPulse.OrderServiceDoubleEndpoint do
  @moduledoc """
  Serves `FleetPulse.OrderServiceDouble`.
  """

  use GRPC.Endpoint

  run(FleetPulse.OrderServiceDouble)
end
