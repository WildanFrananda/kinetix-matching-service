defmodule FleetPulseWeb.RequestTrace do
  @moduledoc """
  Gives every request the endpoint answers its own id before anything else runs, socket upgrades
  included: the client's `x-request-id` when `Plug.RequestId` accepts it, a fresh one otherwise. The
  id goes to the response's `x-request-id`, to the `:request_id` assign the error body reads and to
  the Logger metadata the log formatter reads.
  """

  alias Plug.Conn

  @spec __before_compile__(Macro.Env.t()) :: Macro.t()
  defmacro __before_compile__(_env) do
    quote do
      defoverridable call: 2

      def call(conn, opts) do
        conn
        |> FleetPulseWeb.RequestTrace.trace()
        |> super(opts)
      end
    end
  end

  @spec trace(Conn.t()) :: Conn.t()
  def trace(conn), do: Plug.RequestId.call(conn, Plug.RequestId.init(assign_as: :request_id))
end
