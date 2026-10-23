defmodule FleetPulseWeb.ErrorJSONTest do
  use FleetPulseWeb.ConnCase, async: true

  test "renders 404 with the status message and a trace id" do
    assert FleetPulseWeb.ErrorJSON.render("404.json", %{}) ==
             %{errors: %{detail: "Not Found"}, traceId: "-"}
  end

  test "renders 500 without naming the failure, and claims nothing about what changed" do
    assert FleetPulseWeb.ErrorJSON.render("500.json", %{}) ==
             %{
               errors: %{
                 detail:
                   "something went wrong handling this request. It may have taken effect " <>
                     "before it failed: read the current state before repeating it."
               },
               traceId: "-"
             }
  end

  test "carries the correlation id the request arrived with" do
    Logger.metadata(request_id: "F-abc123")

    assert %{traceId: "F-abc123"} = FleetPulseWeb.ErrorJSON.render("500.json", %{})
    assert %{traceId: "F-abc123"} = FleetPulseWeb.ErrorJSON.render("422.json", %{})
  end

  test "falls back to a dash when no correlation id was set" do
    Logger.metadata(request_id: nil)

    assert %{traceId: "-"} = FleetPulseWeb.ErrorJSON.render("503.json", %{})
  end
end
