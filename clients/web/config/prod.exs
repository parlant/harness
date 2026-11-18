import Config

config :harness_web, HWeb.Endpoint,
  http: [ip: {127, 0, 0, 1}, port: 4000],
  check_origin: ["//127.0.0.1", "//localhost", "//[::1]"]

config :logger, level: :info
