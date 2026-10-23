defmodule FleetPulseWeb.AdminActionsSeed do
  @moduledoc """
  Publishes `kinetix_admin_actions_total` at zero for every action an admin-only route names and
  every outcome, at boot.
  """

  alias FleetPulse.Observability.AdminActions

  @spec child_spec(keyword()) :: Supervisor.child_spec()
  def child_spec(opts) do
    router = Keyword.get(opts, :router, FleetPulseWeb.Router)

    %{
      id: __MODULE__,
      start: {Task, :start_link, [fn -> seed(router) end]},
      restart: :temporary,
      type: :worker
    }
  end

  @spec seed(module()) :: [String.t()]
  def seed(router) do
    router
    |> actions()
    |> AdminActions.seed()
  end

  @spec actions(module()) :: [String.t()]
  def actions(router) do
    router.__routes__()
    |> Enum.map(&Map.get(&1.metadata, :admin_action))
    |> Enum.reject(&is_nil/1)
    |> Enum.uniq()
  end
end
