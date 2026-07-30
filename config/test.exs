import Config

# We don't run a server during test. If one is required,
# you can enable the server option below.
config :eva_web, EvaWebWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4002],
  secret_key_base: "nR0lcjQq9rhLV4SH5zZe17osThy3eA2sAAUiKNDAetOhfDL6K2OmVFCTrvKEHYnQ",
  server: false

# In test we don't send emails
config :eva_web, EvaWeb.Mailer, adapter: Swoosh.Adapters.Test

# The new-session picker asks the provider for its model list. Point the default provider at a
# closed port so the suite exercises the unreachable path deterministically, instead of depending
# on whether LM Studio happens to be running on the machine.
config :eva_web, :eva, base_url: "http://127.0.0.1:1"

# Keep the suite away from the real ~/.eva/web.json — it belongs to whoever is running the tests.
config :eva_web, :settings_path, Path.join(System.tmp_dir!(), "eva_web_test_settings.json")

# Disable swoosh api client as it is only required for production adapters
config :swoosh, :api_client, false

# Print only warnings and errors during test
config :logger, level: :warning

# Initialize plugs at runtime for faster test compilation
config :phoenix, :plug_init_mode, :runtime

# Enable helpful, but potentially expensive runtime checks
config :phoenix_live_view,
  enable_expensive_runtime_checks: true

# Sort query params output of verified routes for robust url comparisons
config :phoenix,
  sort_verified_routes_query_params: true
