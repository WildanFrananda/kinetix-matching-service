defimpl Plug.Exception, for: DBConnection.ConnectionError do
  @spec status(Exception.t()) :: 503
  def status(_unreachable), do: 503

  @spec actions(Exception.t()) :: []
  def actions(_unreachable), do: []
end
