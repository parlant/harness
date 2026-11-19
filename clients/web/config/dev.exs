import Config

config :harness_web, HWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: true,
  code_reloader: true,
  live_reload: [
    patterns: [~r{lib/.*\.(ex|heex)$}, ~r{priv/static/.*\.(js|css)$}]
  ],
  check_origin: ["//127.0.0.1", "//localhost", "//[::1]"],
  secret_key_base:
    "dev_only_secret_key_base_hweb_0123456789abcdef0123456789abcdef0123456789abcdef"

config :phoenix_live_reload, dirs: ["lib", "priv/static"]

# The client cannot choose the workspace in which inspector feedback is recorded.
config :harness_web, :inspector_workspace, Path.expand("..", __DIR__)

config :logger, level: :info
