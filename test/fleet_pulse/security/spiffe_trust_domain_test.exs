defmodule FleetPulse.Security.SpiffeTrustDomainTest do
  use ExUnit.Case, async: false

  alias FleetPulse.Security.Spiffe

  setup do
    previous = System.get_env("KINETIX_TRUST_DOMAIN")

    on_exit(fn ->
      case previous do
        nil -> System.delete_env("KINETIX_TRUST_DOMAIN")
        value -> System.put_env("KINETIX_TRUST_DOMAIN", value)
      end
    end)

    :ok
  end

  describe "trust_domain/0" do
    test "keeps the domain the estate runs today when the variable is unset" do
      assert Spiffe.trust_domain() == "kinetix.local"
      assert Spiffe.trust_domains() == ["kinetix.local"]
    end

    test "accepts a comma-separated list, which is what makes a cutover gradual" do
      System.put_env("KINETIX_TRUST_DOMAIN", "kinetix.local, prod.kinetix")
      assert Spiffe.trust_domains() == ["kinetix.local", "prod.kinetix"]

      for domain <- ["kinetix.local", "prod.kinetix"] do
        id = "spiffe://" <> domain <> "/service/order"
        named = Enum.find_value(Spiffe.trust_domains(), fn d -> Spiffe.service_in(id, d) end)
        assert named == {:ok, "order"}
      end
    end

    test "still refuses a domain outside the list" do
      System.put_env("KINETIX_TRUST_DOMAIN", "kinetix.local,prod.kinetix")
      id = "spiffe://staging.kinetix/service/order"
      assert Enum.find_value(Spiffe.trust_domains(), fn d -> Spiffe.service_in(id, d) end) == nil
    end

    test "can be pointed at another domain without recompiling" do
      System.put_env("KINETIX_TRUST_DOMAIN", "prod.kinetix")
      assert Spiffe.trust_domain() == "prod.kinetix"
    end

    test "a blank value is not a domain" do
      System.put_env("KINETIX_TRUST_DOMAIN", "   ")
      assert Spiffe.trust_domain() == "kinetix.local"
    end
  end

  describe "service_in/2" do
    test "names the service in an id from the configured domain" do
      assert Spiffe.service_in("spiffe://kinetix.local/service/order", "kinetix.local") ==
               {:ok, "order"}

      assert Spiffe.service_in("spiffe://prod.kinetix/service/order", "prod.kinetix") ==
               {:ok, "order"}
    end

    test "names nobody for an id from another trust domain" do
      assert Spiffe.service_in("spiffe://prod.kinetix/service/order", "kinetix.local") == nil
      assert Spiffe.service_in("spiffe://kinetix.local/service/order", "prod.kinetix") == nil
    end

    test "refuses a domain this one is merely a prefix of" do
      assert Spiffe.service_in(
               "spiffe://kinetix.local.example.com/service/order",
               "kinetix.local"
             ) == nil
    end

    test "refuses an id that names no service, or names a path" do
      assert Spiffe.service_in("spiffe://kinetix.local/service/", "kinetix.local") == nil
      assert Spiffe.service_in("spiffe://kinetix.local/service/a/b", "kinetix.local") == nil
      assert Spiffe.service_in("spiffe://kinetix.local/agent/x", "kinetix.local") == nil
      assert Spiffe.service_in("https://kinetix.local/service/order", "kinetix.local") == nil
    end
  end
end
