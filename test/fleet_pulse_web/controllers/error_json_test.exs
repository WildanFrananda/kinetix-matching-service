defmodule FleetPulseWeb.ErrorJSONTest do
  use FleetPulseWeb.ConnCase, async: true

  @request_id "kong-request-id-0003-cccccccccccc"

  test "renders 404 with the status message and the request's id" do
    assert FleetPulseWeb.ErrorJSON.render("404.json", %{request_id: @request_id}) ==
             %{errors: %{detail: "Not Found"}, traceId: @request_id}
  end

  test "renders 500 without naming the failure, and claims nothing about what changed" do
    assert FleetPulseWeb.ErrorJSON.render("500.json", %{request_id: @request_id}) ==
             %{
               errors: %{
                 detail:
                   "something went wrong handling this request. It may have taken effect " <>
                     "before it failed: read the current state before repeating it."
               },
               traceId: @request_id
             }
  end

  test "carries the request's id, never one left in the process's Logger metadata" do
    Logger.metadata(request_id: "an-earlier-request-id-0000000000")

    assert %{traceId: @request_id} =
             FleetPulseWeb.ErrorJSON.render("422.json", %{request_id: @request_id})

    assert %{traceId: "-"} = FleetPulseWeb.ErrorJSON.render("503.json", %{})
  end
end
