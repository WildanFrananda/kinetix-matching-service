defmodule FleetPulse.FailingAssignment do
  @moduledoc """
  Makes Postgres raise on every write that assigns a job, inside the test's own sandbox transaction,
  so an assignment fails the way it does when the database fails while the transaction runs. The
  sandbox rolls the trigger back with everything else.
  """

  alias FleetPulse.Repo

  @spec refuse!() :: :ok
  def refuse! do
    %Postgrex.Result{} =
      Repo.query!("""
      CREATE FUNCTION refuse_assignment_in_test() RETURNS trigger LANGUAGE plpgsql AS $$
      BEGIN
        RAISE EXCEPTION 'the database failed while the assignment was written';
      END
      $$
      """)

    %Postgrex.Result{} =
      Repo.query!("""
      CREATE TRIGGER refuse_assignment_in_test BEFORE UPDATE ON orders
      FOR EACH ROW WHEN (NEW.status = 'assigned') EXECUTE FUNCTION refuse_assignment_in_test()
      """)

    :ok
  end
end
