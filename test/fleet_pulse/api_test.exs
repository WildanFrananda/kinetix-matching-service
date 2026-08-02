defmodule FleetPulse.ApiTest do
  use FleetPulse.DataCase, async: true

  alias FleetPulse.Api
  alias FleetPulse.Api.Key

  test "create_key returns the plaintext once and stores only a hash" do
    assert {:ok, %Key{} = key, plaintext} = Api.create_key("Partner A")
    assert String.starts_with?(plaintext, "fp_")
    assert key.hashed_key != plaintext
    assert key.label == "Partner A"
  end

  test "authenticate accepts a valid key" do
    {:ok, _key, plaintext} = Api.create_key("Partner")
    assert {:ok, %Key{}} = Api.authenticate(plaintext)
  end

  test "authenticate rejects an unknown key" do
    assert {:error, :invalid} = Api.authenticate("fp_nonsense")
  end

  test "authenticate rejects a revoked key" do
    {:ok, key, plaintext} = Api.create_key("Partner")
    {:ok, _revoked} = Api.revoke_key(key.id)
    assert {:error, :invalid} = Api.authenticate(plaintext)
  end

  test "authenticate rejects non-binary input" do
    assert {:error, :invalid} = Api.authenticate(nil)
  end
end
