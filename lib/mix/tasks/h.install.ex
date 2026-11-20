defmodule Mix.Tasks.H.Install do
  use Mix.Task

  @shortdoc "Installs and activates a prebuilt bundle for the current user"

  @impl true
  def run(args) do
    python =
      System.find_executable("python3") || Mix.raise("python3 is required for local installation")

    case System.cmd(python, ["-B", "scripts/install-bundle.py" | args],
           into: IO.stream(:stdio, :line),
           stderr_to_stdout: true
         ) do
      {_, 0} -> :ok
      {_, code} -> Mix.raise("Bundle installation exited with status #{code}")
    end
  end
end
