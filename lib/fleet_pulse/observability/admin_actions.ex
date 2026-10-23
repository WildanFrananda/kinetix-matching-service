defmodule FleetPulse.Observability.AdminActions do
  @moduledoc """
  The audit of what administrators do here: one `admin_action` log line at info and one count of
  `kinetix_admin_actions_total{action, outcome}` per decision. The line carries the actor (the
  token's `sub`), the action, the target and the outcome; the log formatter adds the request id.
  """

  require Logger

  alias FleetPulse.Observability.Metrics

  @outcomes [:done, :refused, :failed]
  @seed %{count: 0}

  @type outcome :: :done | :refused | :failed

  @spec record(String.t(), String.t(), String.t() | nil, outcome()) :: :ok
  def record(actor, action, target, outcome) when outcome in @outcomes do
    Logger.info("admin_action",
      event: "admin_action",
      actor: actor,
      action: action,
      target: target,
      outcome: Atom.to_string(outcome)
    )

    :telemetry.execute(Metrics.admin_action_event(), %{count: 1}, labels(action, outcome))
  end

  @spec seed([String.t()]) :: [String.t()]
  def seed(actions) do
    for action <- actions, outcome <- @outcomes do
      :ok = :telemetry.execute(Metrics.admin_action_event(), @seed, labels(action, outcome))
    end

    actions
  end

  @spec labels(String.t(), outcome()) :: %{action: String.t(), outcome: String.t()}
  defp labels(action, outcome), do: %{action: action, outcome: Atom.to_string(outcome)}
end
