# Exercise Hex's registry, resolver and compiler against the actual tarball.
# Run from the source checkout with `elixir scripts/ci/smoke-hex.exs`.
root = File.cwd!()
tmp = if match?({:unix, :darwin}, :os.type()), do: "/private/tmp", else: System.tmp_dir!()
scratch = Path.join(tmp, "hiness-hex-#{Base.url_encode64(:crypto.strong_rand_bytes(9))}")
File.mkdir!(scratch)

try do
  registry = Path.join(scratch, "registry")
  tarballs = Path.join(registry, "tarballs")
  consumer = Path.join(scratch, "consumer")
  File.mkdir_p!(tarballs)
  File.mkdir_p!(Path.join(consumer, "config"))

  env = [
    {"MIX_ENV", "prod"},
    {"MIX_BUILD_PATH", Path.join(scratch, "build")},
    {"MIX_DEPS_PATH", nil},
    {"HEX_HOME", Path.join(scratch, "hex")},
    {"HEX_API_KEY", nil}
  ]

  mix = fn cwd, args ->
    {_, status} =
      System.cmd("mix", args,
        cd: cwd,
        env: env,
        into: IO.stream(:stdio, :line),
        stderr_to_stdout: true
      )

    if status != 0, do: raise("mix #{Enum.join(args, " ")} failed (exit #{status})")
  end

  read_version = fn cwd ->
    {version, 0} =
      System.cmd(
        "mix",
        [
          "run",
          "--no-start",
          "--no-compile",
          "--no-deps-check",
          "-e",
          "IO.write(Mix.Project.config()[:version])"
        ],
        cd: cwd,
        env: env
      )

    version
  end

  version = read_version.(root)

  case System.get_env("CI_COMMIT_TAG") do
    tag when tag not in [nil, ""] ->
      web_version = read_version.(Path.join(root, "clients/web"))
      installer_version = read_version.(Path.join(root, "installer"))

      unless Enum.all?([version, web_version, installer_version], &(tag == "v#{&1}")) do
        raise "Release tag #{tag} must match hiness #{version}, harness_web #{web_version}, " <>
                "and h_setup #{installer_version}"
      end

    _ ->
      :ok
  end

  mix.(root, ["hex.build", "--output", Path.join(tarballs, "hiness-#{version}.tar")])

  key_file = Path.join(scratch, "registry.pem")
  key = :public_key.generate_key({:rsa, 2048, 65_537})

  File.write!(
    key_file,
    :public_key.pem_encode([:public_key.pem_entry_encode(:RSAPrivateKey, key)])
  )

  mix.(consumer, [
    "hex.registry",
    "build",
    registry,
    "--name=hiness-smoke",
    "--private-key=#{key_file}"
  ])

  {:ok, _} = Application.ensure_all_started(:inets)

  {:ok, server} =
    :inets.start(:httpd,
      port: 0,
      bind_address: {127, 0, 0, 1},
      server_name: ~c"localhost",
      server_root: String.to_charlist(registry),
      document_root: String.to_charlist(registry)
    )

  try do
    [port: port] = :httpd.info(server, [:port])

    mix.(consumer, [
      "hex.repo",
      "add",
      "hiness-smoke",
      "http://127.0.0.1:#{port}",
      "--public-key=#{Path.join(registry, "public_key")}"
    ])

    File.write!(Path.join(consumer, "mix.exs"), """
    defmodule HinessSmoke.MixProject do
      use Mix.Project

      def project do
        [app: :hiness_smoke, version: "0.0.0",
         deps: [{:harness, "== #{version}", hex: :hiness, repo: "hiness-smoke"}]]
      end
    end
    """)

    File.write!(Path.join(consumer, "config/runtime.exs"), """
    import Config
    config :harness, data_dir: Path.expand("store"), no_extensions: true
    config :req_llm, load_dotenv: false
    """)

    mix.(consumer, ["deps.get"])
    mix.(consumer, ["hex.audit"])
    mix.(consumer, ["compile", "--warnings-as-errors"])

    mix.(consumer, [
      "run",
      "--no-compile",
      "-e",
      """
      [] = H.Daemon.list_sessions()
      %{"http_urls" => [], "api_socket" => nil} = File.read!("store/daemon.json") |> JSON.decode!()
      false = Code.ensure_loaded?(Mix.Tasks.H.Build)
      :ok = Application.stop(:harness)
      IO.puts("hiness installed and :harness booted without API listeners")
      """
    ])
  after
    :inets.stop(:httpd, server)
  end
after
  File.rm_rf!(scratch)
end
