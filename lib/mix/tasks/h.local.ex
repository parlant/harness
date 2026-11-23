defmodule Mix.Tasks.H.Local do
  use Mix.Task

  @moduledoc false
  @shortdoc "Builds, smoke-tests, and installs the local release"
  @switches [service: :boolean, data_dir: :string, bin_dir: :string]

  @impl true
  def run(args) do
    case OptionParser.parse(args, strict: @switches) do
      {opts, [], []} ->
        :ok = Mix.Tasks.H.Bundle.run([])

        Mix.Tasks.H.Install.run(
          OptionParser.to_argv(Enum.reject(opts, fn {_, value} -> value == false end))
        )

      _ ->
        Mix.raise("usage: mix h.local [--service] [--data-dir DIR] [--bin-dir DIR]")
    end
  end
end
