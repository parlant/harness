defmodule Mix.Tasks.Extension.Build do
  use Mix.Task

  @shortdoc "Builds the extension into a new directory (default: dist/greeting)"

  @impl true
  def run(args) do
    output =
      case args do
        [] -> Path.expand("dist/greeting")
        [dir] -> Path.expand(dir)
        _ -> Mix.raise("usage: mix extension.build [OUTPUT_DIR]")
      end

    Mix.Task.run("compile", ["--warnings-as-errors"])
    %{"module" => root} = "extension.json" |> File.read!() |> JSON.decode!()
    compile_path = Mix.Project.compile_path()
    entry = Path.join(compile_path, root <> ".beam")
    unless File.regular?(entry), do: Mix.raise("No compiled entry module for #{root}")
    beams = [entry | Path.wildcard(Path.join(compile_path, root <> ".*.beam"))]

    File.mkdir_p!(Path.dirname(output))
    # Do not replace a live install. Build to a new versioned directory.
    File.mkdir!(output)
    ebin = Path.join(output, "ebin")
    File.mkdir!(ebin)
    Enum.each(beams, &File.cp!(&1, Path.join(ebin, Path.basename(&1))))
    File.cp!("extension.json", Path.join(output, "extension.json"))
    Mix.shell().info("Built extension at #{output}")
  end
end
