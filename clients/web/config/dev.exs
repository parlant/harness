import Config

config :harness_web, HWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  debug_errors: true,
  code_reloader: false,
  check_origin: ["//127.0.0.1", "//localhost", "//[::1]"],
  secret_key_base:
    "dev_only_secret_key_base_hweb_0123456789abcdef0123456789abcdef0123456789abcdef"

config :logger, level: :info
