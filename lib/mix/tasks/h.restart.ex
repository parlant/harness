defmodule Mix.Tasks.H.Restart do
  use Mix.Task

  @moduledoc false
  @shortdoc "Starts a built candidate after cooperative daemon shutdown"

  @impl true
  def run(args) do
    case OptionParser.parse(args,
           strict: [
             bundle: :string,
             data_dir: :string,
             port: :integer,
             no_extensions: :boolean,
             idle_only: :boolean,
             timeout: :integer
           ]
         ) do
      {opts, [], []} ->
        bundle = Path.expand(opts[:bundle] || "dist/harness")
        hi = Path.join(bundle, "bin/hi")

        unless File.regular?(hi),
          do: Mix.raise("No candidate at #{hi}; build one with mix h.bundle first")

        command =
          ["daemon", "restart"] ++
            if(opts[:data_dir], do: ["--data-dir", opts[:data_dir]], else: []) ++
            if(opts[:port], do: ["--port", to_string(opts[:port])], else: []) ++
            if(opts[:no_extensions], do: ["--no-extensions"], else: []) ++
            if(opts[:idle_only], do: ["--idle-only"], else: []) ++
            if opts[:timeout], do: ["--timeout", to_string(opts[:timeout])], else: []

        # A foreground process in the caller's terminal; no daemon PID or live
        # store is ever read by the task itself. Keep SIGINT/stdio with the port.
        case System.cmd(hi, command,
               into: IO.stream(:stdio, :line),
               stderr_to_stdout: true
             ) do
          {_, 0} -> :ok
          {_, status} -> Mix.raise("guarded restart exited with status #{status}")
        end

      _ ->
        Mix.raise(
          "usage: mix h.restart [--bundle DIR] [--data-dir DIR] [--port PORT] [--no-extensions] [--idle-only] [--timeout SECS]"
        )
    end
  end
end
