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
