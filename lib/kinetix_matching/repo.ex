defmodule KinetixMatching.Repo do
  use Ecto.Repo,
    otp_app: :kinetix_matching,
    adapter: Ecto.Adapters.Postgres
end
