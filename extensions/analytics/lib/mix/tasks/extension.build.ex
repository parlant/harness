defmodule Mix.Tasks.Extension.Build do
  use Mix.Task

  @shortdoc "Builds the extension into a new directory (default: dist/analytics)"

  @impl true
  def run(args) do
    output =
      case args do
        [] -> Path.expand("dist/analytics")
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
    copy_static_assets!("priv/static", Path.join([output, "priv", "static"]))
    Mix.shell().info("Built extension at #{output}")
  end

  defp copy_static_assets!(src_dir, dest_dir) do
    case File.lstat(src_dir) do
      {:ok, %File.Stat{type: :directory}} ->
        File.mkdir_p!(dest_dir)
        copy_dir_entries!(src_dir, dest_dir)

      {:ok, %File.Stat{}} ->
        Mix.raise("Refusing non-directory static asset root #{src_dir}")

      {:error, :enoent} ->
        :ok

      {:error, reason} ->
        Mix.raise("Failed to inspect #{src_dir}: #{inspect(reason)}")
    end
  end

  defp copy_dir_entries!(src_dir, dest_dir) do
    for entry <- Enum.sort(File.ls!(src_dir)) do
      src = Path.join(src_dir, entry)
      dest = Path.join(dest_dir, entry)

      case File.lstat!(src) do
        %File.Stat{type: :directory} ->
          File.mkdir_p!(dest)
          copy_dir_entries!(src, dest)

        %File.Stat{type: :regular} ->
          File.cp!(src, dest)

        %File.Stat{type: type} ->
          Mix.raise("Refusing unsupported static asset #{src} (#{type})")
      end
    end
  end
end
