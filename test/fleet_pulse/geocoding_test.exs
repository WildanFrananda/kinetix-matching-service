defmodule FleetPulse.GeocodingTest do
  use FleetPulse.DataCase, async: false

  alias FleetPulse.FakeGeocoder
  alias FleetPulse.Geocoding
  alias FleetPulse.Geocoding.GeocodedAddress

  @address "Jl. Jenderal Sudirman No. 5, Jakarta"
  @point %{latitude: -6.2088, longitude: 106.8456, display_name: "Jakarta, Indonesia"}

  setup do
    :ok = FakeGeocoder.start()
    :ok = FakeGeocoder.reset()
    :ok
  end

  test "asks the geocoder for an address it has never seen" do
    FakeGeocoder.always({:ok, @point})

    assert {:ok, {-6.2088, 106.8456}} = Geocoding.coordinates_for(@address)
    assert FakeGeocoder.call_count() == 1
  end

  test "never asks twice for the same address" do
    FakeGeocoder.always({:ok, @point})

    assert {:ok, first} = Geocoding.coordinates_for(@address)
    assert {:ok, second} = Geocoding.coordinates_for(@address)
    assert {:ok, third} = Geocoding.coordinates_for(@address)

    assert first == second and second == third
    assert FakeGeocoder.call_count() == 1
  end

  test "treats spacing and case as the same address, so one spelling is one request" do
    FakeGeocoder.always({:ok, @point})

    assert {:ok, _} = Geocoding.coordinates_for(@address)
    assert {:ok, _} = Geocoding.coordinates_for("  " <> String.upcase(@address) <> "  ")
    assert {:ok, _} = Geocoding.coordinates_for(String.replace(@address, " ", "   "))

    assert FakeGeocoder.call_count() == 1
  end

  test "fails closed when the geocoder does not know the address" do
    FakeGeocoder.always({:error, :not_found})

    assert {:error, :not_found} = Geocoding.coordinates_for(@address)
    assert Repo.aggregate(GeocodedAddress, :count) == 0
  end

  test "fails closed when the geocoder is unreachable" do
    FakeGeocoder.always({:error, :unavailable})

    assert {:error, :unavailable} = Geocoding.coordinates_for(@address)
  end

  test "fails closed when the geocoder rate-limits the lookup" do
    FakeGeocoder.always({:error, :rate_limited})

    assert {:error, :rate_limited} = Geocoding.coordinates_for(@address)
  end

  test "does not remember a failure, so a recovered geocoder is asked again" do
    FakeGeocoder.always({:error, :unavailable})
    assert {:error, :unavailable} = Geocoding.coordinates_for(@address)

    FakeGeocoder.always({:ok, @point})
    assert {:ok, {-6.2088, 106.8456}} = Geocoding.coordinates_for(@address)
  end

  test "refuses an empty address without asking anybody" do
    assert {:error, :not_found} = Geocoding.coordinates_for("   ")
    assert {:error, :not_found} = Geocoding.coordinates_for(nil)
    assert FakeGeocoder.call_count() == 0
  end

  test "records which provider answered, so a bad batch can be found later" do
    FakeGeocoder.always({:ok, @point})
    assert {:ok, _} = Geocoding.coordinates_for(@address)

    stored = Repo.one(GeocodedAddress)
    assert stored.provider == to_string(FleetPulse.FakeGeocoder)
    assert stored.display_name == "Jakarta, Indonesia"
  end

  test "forgetting an address makes the next lookup ask again" do
    FakeGeocoder.always({:ok, @point})
    assert {:ok, _} = Geocoding.coordinates_for(@address)
    assert FakeGeocoder.call_count() == 1

    :ok = Geocoding.forget(@address)

    assert {:ok, _} = Geocoding.coordinates_for(@address)
    assert FakeGeocoder.call_count() == 2
  end

  test "refuses a point that is not on Earth rather than passing it on" do
    FakeGeocoder.always({:ok, %{latitude: 91.0, longitude: 0.0, display_name: "nowhere"}})

    assert {:error, :unavailable} = Geocoding.coordinates_for(@address)
    assert Repo.aggregate(GeocodedAddress, :count) == 0
  end
end
