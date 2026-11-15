defmodule KinetixMatchingWeb.ChannelCase do
  @moduledoc """
  This module defines the test case to be used by channel tests.

  Channel tests are never async: `Snapshot.fetch/1` runs inside the
  `DriverState` process, which owns no sandbox connection of its own, so the
  suite depends on `DataCase.setup_sandbox/1` putting the pool into shared
  mode for non-async tests.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      @endpoint KinetixMatchingWeb.Endpoint

      import Phoenix.ChannelTest
      import KinetixMatchingWeb.Endpoint
    end
  end

  setup tags do
    KinetixMatching.DataCase.setup_sandbox(tags)
    :ok
  end
end
