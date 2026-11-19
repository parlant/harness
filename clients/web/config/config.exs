import Config

config :harness_web,
  backend: HWeb.Backend.InVM,
  daemon_opts: []

config :harness_web, HWeb.Endpoint,
  url: [host: "localhost"],
  adapter: Bandit.PhoenixAdapter,
  render_errors: [
    formats: [html: HWeb.ErrorHTML, json: HWeb.ErrorJSON],
    layout: false
  ],
  pubsub_server: HWeb.PubSub,
  check_origin: ["//127.0.0.1", "//localhost", "//[::1]"],
  live_view: [signing_salt: "hweb_lv_salt_9f2a4c"]

config :phoenix, :json_library, Jason

config :logger, :default_formatter,
  format: "$time $metadata[$level] $message\n",
  metadata: [:request_id]

import_config "#{config_env()}.exs"
