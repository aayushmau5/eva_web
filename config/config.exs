# This file is responsible for configuring your application
# and its dependencies with the aid of the Config module.
#
# This configuration file is loaded before any dependency and
# is restricted to this project.

# General application configuration
import Config

config :eva_web,
  generators: [timestamp_type: :utc_datetime]

# Syntax highlighting for fenced code blocks in assistant messages. This is read when
# :mdex_native compiles, so changing it needs `mix deps.clean mdex_native --build`.
config :mdex_native, syntax_highlighter: :syntect

# Defaults the new-session picker starts on. `provider` must name one of `EvaWeb.Providers.all/0`;
# `base_url` only moves the local LM Studio endpoint, hosted providers bring their own.
config :eva_web, :eva,
  provider: "lmstudio",
  model: "nvidia/nemotron-3-nano-4b",
  base_url: "http://localhost:1234/v1"

# Configure the endpoint
config :eva_web, EvaWebWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: EvaWebWeb.ErrorHTML, json: EvaWebWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: EvaWeb.PubSub,
  live_view: [signing_salt: "gQXSS0Kh"]

# Configure LiveView
config :phoenix_live_view,
  # the attribute set on all root tags. Used for Phoenix.LiveView.ColocatedCSS.
  root_tag_attribute: "phx-r"

# Configure the mailer
#
# By default it uses the "Local" adapter which stores the emails
# locally. You can see the emails in your browser, at "/dev/mailbox".
#
# For production it's recommended to configure a different adapter
# at the `config/runtime.exs`.
config :eva_web, EvaWeb.Mailer, adapter: Swoosh.Adapters.Local

# Configure esbuild (the version is required)
config :esbuild,
  version: "0.25.4",
  eva_web: [
    args:
      ~w(js/app.js --bundle --target=es2022 --outdir=../priv/static/assets/js --external:/fonts/* --external:/images/* --alias:@=.),
    cd: Path.expand("../assets", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure tailwind (the version is required)
config :tailwind,
  version: "4.3.0",
  eva_web: [
    args: ~w(
      --input=assets/css/app.css
      --output=priv/static/assets/css/app.css
    ),
    cd: Path.expand("..", __DIR__),
    env: %{"NODE_PATH" => [Path.expand("../deps", __DIR__), Mix.Project.build_path()]}
  ]

# Configure Elixir's Logger
config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

# Use Jason for JSON parsing in Phoenix
config :phoenix, :json_library, Jason

# Import environment specific config. This must remain at the bottom
# of this file so it overrides the configuration defined above.
import_config "#{config_env()}.exs"
