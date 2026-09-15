if Mix.env() == :prod do
  raise "Refusing to seed in prod."
end

IO.puts("""
Nothing to seed. Operators and drivers are identity accounts.
See the comments at the top of priv/repo/seeds.exs.
""")
