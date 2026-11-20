defmodule Mix.Tasks.H.Bundle do
  use Mix.Task

  @shortdoc "Builds and smoke-tests a native bundle (default: dist/harness)"

  @impl true
  def run(args) do
    python =
      System.find_executable("python3") || Mix.raise("python3 is required for bundle validation")

    case args do
      [] -> build_default(python)
      [dir] -> build(Path.expand(dir), python)
      _ -> Mix.raise("usage: mix h.bundle [NEW_OUTPUT_DIR]")
    end
  end

  defp build_default(python) do
    output = Path.expand("dist/harness")
    check_default_link!(output)

    # Keep running bundles and the last tested link intact while building and testing.
    id = :crypto.strong_rand_bytes(12) |> Base.encode16(case: :lower)
    relative = Path.join([".harness-builds", id, "bundle"])
    candidate = Path.join(Path.dirname(output), relative)
    build_dir = Path.dirname(candidate)
    link = Path.join(build_dir, "publish")

    File.mkdir_p!(Path.dirname(build_dir))
    File.mkdir!(build_dir)

    try do
      build(candidate, python)
      check_default_link!(output)
      File.ln_s!(relative, link)
      File.rename!(link, output)
    rescue
      error ->
        File.rm_rf(build_dir)
        reraise error, __STACKTRACE__
    end

    Mix.shell().info("Updated #{output}. Install it with mix h.install.")
  end

  defp check_default_link!(output) do
    case File.read_link(output) do
      {:error, :enoent} ->
        :ok

      {:ok, target} ->
        unless Regex.match?(~r/\A\.harness-builds\/[a-f0-9]{24}\/bundle\z/, target) do
          Mix.raise("Refusing to replace unrelated symlink #{output}")
        end

      _ ->
        Mix.raise(
          "Refusing to replace #{output}; move the old bundle when it is no longer in use"
        )
    end
  end

  defp build(output, python) do
    File.mkdir_p!(Path.dirname(output))

    Enum.each(
      [
        {"Bundle build", Path.expand("scripts/build-bundle.sh"), [output]},
        {"Bundle smoke test", python, ["-B", "scripts/smoke-bundle.py", output]}
      ],
      fn {stage, program, args} ->
        case System.cmd(program, args, into: IO.stream(:stdio, :line), stderr_to_stdout: true) do
          {_, 0} -> :ok
          {_, status} -> Mix.raise("#{stage} failed (exit #{status})")
        end
      end
    )
  end
end
