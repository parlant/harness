defmodule Mix.Tasks.H.Install do
  use Mix.Task

  @moduledoc false
  @shortdoc "Installs and activates a prebuilt bundle (default: dist/harness)"

  @impl true
  def run(args) do
    python =
      System.find_executable("python3") || Mix.raise("python3 is required for local installation")

    {output, code} =
      System.cmd(python, ["-u", "-B", "scripts/install-bundle.py" | args], stderr_to_stdout: true)

    case {code, String.trim_trailing(output)} do
      {0, ""} -> :ok
      {0, details} -> Mix.shell().info(details)
      {code, ""} -> Mix.raise("Bundle installation exited with status #{code}")
      {code, details} -> Mix.raise("Bundle installation exited with status #{code}:\n#{details}")
    end
  end
end
