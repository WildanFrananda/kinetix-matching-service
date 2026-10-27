defmodule FleetPulseWeb.ErrorJSON do
  @moduledoc """
  The body every failed JSON request gets back. `traceId` is the id `RequestTrace` gave this request,
  read from the render's assigns and never from the process, which may have served another request.
  """

  @type error_response :: %{errors: %{detail: String.t()}, traceId: String.t()}

  @spec render(String.t(), map()) :: error_response()
  def render("500.json", assigns) do
    return_payload(
      "something went wrong handling this request. It may have taken effect before it failed: " <>
        "read the current state before repeating it.",
      assigns
    )
  end

  def render(template, assigns) do
    return_payload(Phoenix.Controller.status_message_from_template(template), assigns)
  end

  @spec return_payload(String.t(), map()) :: error_response()
  defp return_payload(detail, assigns) do
    %{errors: %{detail: detail}, traceId: trace_id(assigns)}
  end

  @spec trace_id(map()) :: String.t()
  defp trace_id(%{request_id: id}) when is_binary(id) and id != "", do: id
  defp trace_id(_untraced), do: "-"
end
