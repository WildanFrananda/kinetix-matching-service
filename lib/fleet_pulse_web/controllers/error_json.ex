defmodule FleetPulseWeb.ErrorJSON do
  @moduledoc """
  The body every failed JSON request gets back.
  """

  @type error_response :: %{errors: %{detail: String.t()}, traceId: String.t()}

  @spec render(String.t(), map()) :: error_response()
  def render("500.json", _assigns) do
    return_payload(
      "something went wrong handling this request. It may have taken effect before it failed: " <>
        "read the current state before repeating it."
    )
  end

  def render(template, _assigns) do
    return_payload(Phoenix.Controller.status_message_from_template(template))
  end

  @spec return_payload(String.t()) :: error_response()
  defp return_payload(detail) do
    %{errors: %{detail: detail}, traceId: trace_id()}
  end

  @spec trace_id() :: String.t()
  defp trace_id do
    case Logger.metadata()[:request_id] do
      id when is_binary(id) and id != "" -> id
      _absent -> "-"
    end
  end
end
