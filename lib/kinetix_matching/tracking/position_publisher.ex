defmodule KinetixMatching.Tracking.PositionPublisher do
  @moduledoc """
  Port for publishing live courier position envelopes scoped to an active order number.
  """

  @callback publish_position(String.t(), map()) :: :ok | {:error, term()}

  @spec publish_position(String.t() | nil, map()) :: :ok | {:error, term()}
  def publish_position(order_number, envelope)
      when is_binary(order_number) and order_number != "" and is_map(envelope) do
    impl().publish_position(order_number, envelope)
  end

  def publish_position(_order_number, _envelope), do: :ok

  @spec impl() :: module()
  defp impl do
    config = Application.get_env(:kinetix_matching, __MODULE__, [])
    Keyword.get(config, :impl, KinetixMatching.Tracking.RedisPositionPublisher)
  end
end
