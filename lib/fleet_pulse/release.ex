defmodule FleetPulse.Release do
  @moduledoc """
  Used for executing DB release tasks when run in production without Mix
  installed.
  """
  @app :fleet_pulse

  @spec migrate() :: :ok
  def migrate do
    _ = load_app()

    Enum.each(repos(), fn repo ->
      {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :up, all: true))
    end)
  end

  @spec rollback(module(), integer()) :: {:ok, term(), [atom()]}
  def rollback(repo, version) do
    _ = load_app()
    {:ok, _, _} = Ecto.Migrator.with_repo(repo, &Ecto.Migrator.run(&1, :down, to: version))
  end

  @spec seed_courier_record(String.t(), pos_integer(), pos_integer()) :: :ok
  def seed_courier_record(principal_id, deliveries, span_days) do
    _ = load_app()

    {:ok, outcome, _apps} =
      Ecto.Migrator.with_repo(FleetPulse.Repo, fn _repo ->
        FleetPulse.LabSeed.seed_courier_record(principal_id, deliveries, span_days)
      end)

    report_seed(outcome, principal_id)
  end

  @spec report_seed({:ok, non_neg_integer()} | {:error, FleetPulse.LabSeed.refusal()}, String.t()) ::
          :ok
  defp report_seed({:ok, count}, principal_id) do
    IO.puts("seeded #{count} delivered jobs with their evidence for #{principal_id}")
  end

  defp report_seed({:error, reason}, principal_id) do
    IO.puts(:stderr, "the lab seed refused #{principal_id}: #{reason}")
    System.halt(1)
  end

  @spec repos() :: [module()]
  defp repos do
    Application.fetch_env!(@app, :ecto_repos)
  end

  @spec load_app() :: :ok | {:error, term()}
  defp load_app do
    # Many platforms require SSL when connecting to the database
    _ = Application.ensure_all_started(:ssl)
    Application.ensure_loaded(@app)
  end
end
