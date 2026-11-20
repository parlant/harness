defmodule Mix.Tasks.H.Bundle do
  use Mix.Task

  @shortdoc "Builds a distributable native bundle and smoke-tests a relocated copy"

  @impl true
  def run(args) do
    output =
      case args do
        [] -> Path.expand("dist/harness")
        [dir] -> Path.expand(dir)
        _ -> Mix.raise("usage: mix h.bundle [NEW_OUTPUT_DIR]")
      end

    File.mkdir_p!(Path.dirname(output))

    python =
      System.find_executable("python3") || Mix.raise("python3 is required for bundle validation")

    for {program, args} <- [
          {Path.expand("scripts/build-bundle.sh"), [output]},
          {python, ["-B", "scripts/smoke-bundle.py", output]}
        ] do
      case System.cmd(program, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
        {_, 0} -> :ok
        {_, status} -> Mix.raise("#{program} failed (exit #{status})")
      end
    end
  end
end
