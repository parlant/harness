import Config

# The combined release is booted explicitly by H.Daemon.CLI. Do not start a
# second embedded daemon or require deployment secrets for its eval commands.
standalone? = System.get_env("RELEASE_NAME") == "harness"

if not standalone? and config_env() != :test and System.get_env("PHX_SERVER") do
  config :harness_web, HWeb.Endpoint, server: true
end

if not standalone? and config_env() != :test do
  data_dir =
    (System.get_env("H_DATA_DIR") || "~/.local/share/h")
    |> Path.expand()

  config :harness,
    data_dir: data_dir,
    start_daemon: true,
    api_socket: true,
    no_extensions: System.get_env("H_NO_EXTENSIONS") == "1"
end

if not standalone? and config_env() == :dev do
  config :harness_web, HWeb.Endpoint,
    http: [ip: {127, 0, 0, 1}, port: String.to_integer(System.get_env("PORT", "4000"))]
end

if not standalone? and config_env() == :prod do
  secret_key_base =
    System.get_env("SECRET_KEY_BASE") ||
      raise """
      environment variable SECRET_KEY_BASE is missing.
      You can generate one by calling: mix phx.gen.secret
      """

  host = System.get_env("PHX_HOST") || "localhost"
  port = String.to_integer(System.get_env("PORT") || "4000")

  allowed_origins =
    case host do
      h when h in ["localhost", "127.0.0.1", "::1"] ->
        ["//127.0.0.1", "//localhost", "//[::1]"]

      h ->
        ["//#{h}", "//127.0.0.1", "//localhost", "//[::1]"]
    end

  config :harness_web, HWeb.Endpoint,
    url: [host: host, port: port],
    http: [ip: {127, 0, 0, 1}, port: port],
    check_origin: allowed_origins,
    secret_key_base: secret_key_base
end
