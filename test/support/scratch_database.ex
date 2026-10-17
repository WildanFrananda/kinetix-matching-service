defmodule FleetPulse.ScratchDatabase do
  @moduledoc """
  A migrated database of its own, for tests whose transactions must really commit: the sandbox never
  commits, so it cannot show what one transaction sees of another, and the evidence log can never be
  emptied again. The repository runs as a dynamic repo; every process that uses it calls `use!/1`.
  """

  alias FleetPulse.Repo

  @type t :: %{name: String.t(), repo: pid()}

  @spec start!() :: t()
  def start! do
    name = "kinetix_matching_scratch_#{System.unique_integer([:positive])}"
    admin!(~s(CREATE DATABASE "#{name}"))

    {:ok, repo} =
      Repo.start_link(
        Keyword.merge(Repo.config(),
          name: nil,
          database: name,
          pool: DBConnection.ConnectionPool,
          pool_size: 4
        )
      )

    true = Process.unlink(repo)
    database = %{name: name, repo: repo}
    use!(database)
    _ = Ecto.Migrator.run(Repo, :up, all: true, dynamic_repo: repo, log: false)
    database
  end

  @spec use!(t()) :: :ok
  def use!(%{repo: repo}) do
    _ = Repo.put_dynamic_repo(repo)
    :ok
  end

  @spec stop!(t()) :: :ok
  def stop!(%{name: name, repo: repo}) do
    :ok = Supervisor.stop(repo)
    admin!(~s{DROP DATABASE "#{name}" WITH (FORCE)})
  end

  @spec admin!(String.t()) :: :ok
  defp admin!(statement) do
    config = Repo.config()

    {:ok, conn} =
      Postgrex.start_link(
        hostname: config[:hostname],
        port: config[:port],
        username: config[:username],
        password: config[:password],
        database: "postgres"
      )

    %Postgrex.Result{} = Postgrex.query!(conn, statement, [])
    GenServer.stop(conn)
  end
end
