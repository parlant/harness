defmodule Mix.Tasks.H.Build do
  use Mix.Task

  @moduledoc false
  @shortdoc "Builds all clients; --release publishes a tested installable bundle"

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: [release: :boolean, output: :string]) do
      {opts, [], []} ->
        if opts[:release] do
          Mix.Tasks.H.Bundle.run(if opts[:output], do: [opts[:output]], else: [])
        else
          build_dev(opts)
        end

      _ ->
        Mix.raise("usage: mix h.build [--release] [--output DIR]")
    end
  end

  defp build_dev(opts) do
    daemon_build = Mix.Project.build_path()
    web_env = "dev"
    root = File.cwd!()
    mix = System.find_executable("mix") || Mix.raise("mix is not on PATH")
    cargo = System.find_executable("cargo") || Mix.raise("cargo is not on PATH")

    run!(mix, ["deps.get", "--check-locked"], root, [])
    run!(mix, ["compile", "--warnings-as-errors"], root, [])

    web = Path.join(root, "clients/web")
    web_build = Path.join([daemon_build, "h-web", web_env])

    web_env_vars = [
      {"MIX_ENV", web_env},
      {"MIX_BUILD_PATH", web_build},
      {"MIX_DEPS_PATH", nil}
    ]

    run!(mix, ["deps.get", "--check-locked"], web, web_env_vars)
    run!(mix, ["compile", "--warnings-as-errors"], web, web_env_vars)

    target =
      Path.expand(opts[:output] || System.get_env("CARGO_TARGET_DIR") || "clients/tui/target")

    for {project, bin} <- [{"tui", "hi"}, {"import", "hi-import"}] do
      run!(cargo, ["build", "--locked", "--bin", bin], Path.join([root, "clients", project]), [
        {"CARGO_TARGET_DIR", target}
      ])
    end

    Mix.shell().info("Run Phoenix against the same store (stop standalone first):
  cd clients/web && MIX_BUILD_PATH=#{inspect(web_build)} mix phx.server")

    Mix.shell().info(
      "Daemon BEAMs: #{daemon_build}\nPhoenix BEAMs: #{web_build}\nClient binaries: #{Path.join(target, "debug")} (hi and hi-import)"
    )
  end

  defp run!(program, args, cwd, env) do
    case System.cmd(program, args,
           cd: cwd,
           env: env,
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} ->
        :ok

      {_, status} ->
        Mix.raise("#{Path.basename(program)} #{Enum.join(args, " ")} failed (exit #{status})")
    end
  end
end
