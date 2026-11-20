defmodule H.Tools.Bash do
  @moduledoc """
  Core `bash` tool for executing shell commands via `H.ExecutionEnv.exec/3`.
  """

  @behaviour H.Tool

  @default_timeout_ms 120_000
  @min_timeout_ms 100
  @max_timeout_ms 600_000

  @impl true
  def name, do: "bash"

  @impl true
  def description do
    "Execute a shell command with bounded output and process-group cleanup. Use cwd to run in another Git worktree and take its workspace lease; shell cd does not change the lease."
  end

  @impl true
  def parameters_schema do
    %{
      "type" => "object",
      "properties" => %{
        "cwd" => H.Tool.cwd_schema(),
        "command" => %{
          "type" => "string",
          "minLength" => 1,
          "description" => "Shell command to execute"
        },
        "timeout_ms" => %{
          "type" => "integer",
          "minimum" => @min_timeout_ms,
          "maximum" => @max_timeout_ms,
          "description" => "Optional timeout in milliseconds (100..600000)"
        }
      },
      "required" => ["command"],
      "additionalProperties" => false
    }
  end

  @impl true
  def replay, do: :unsafe

  @impl true
  def mutating?, do: true

  @impl true
  def execute(args, context) when is_map(args) and is_map(context) do
    command = fetch_arg(args, "command", :command)

    timeout_ms =
      fetch_arg(args, "timeout_ms", :timeout_ms) || Map.get(context, :timeout_ms) ||
        @default_timeout_ms

    abort_ref = Map.get(context, :abort_ref)

    exec_opts =
      [timeout_ms: timeout_ms]
      |> maybe_put_opt(:abort_ref, abort_ref)
      |> maybe_put_on_output(Map.get(context, :on_output))

    case H.ExecutionEnv.exec(context.env, {:shell, command}, exec_opts) do
      {:ok, result} ->
        details = %{
          exit_code: result.exit_code,
          truncated: result.truncated,
          skipped_bytes: result.skipped_bytes,
          full_output_path: result.full_output_path
        }

        text = format_exec_output(result, nil)

        if result.exit_code == 0 do
          {:ok,
           %{
             content: [%{"type" => "text", "text" => text}],
             details: details,
             is_error: false,
             diagnostic: nil
           }}
        else
          {:ok,
           %{
             content: [%{"type" => "text", "text" => text}],
             details: details,
             is_error: true,
             diagnostic: "exit_code"
           }}
        end

      {:error, %{reason: reason} = err} ->
        details = %{
          reason: to_string(reason),
          truncated: err.truncated,
          skipped_bytes: err.skipped_bytes,
          full_output_path: err.full_output_path
        }

        reason_msg =
          case reason do
            :timeout -> "Command timed out after #{timeout_ms} ms"
            :aborted -> "Command aborted"
            other -> "Command failed: #{inspect(other)}"
          end

        text = format_exec_output(err, reason_msg)

        {:error,
         %{
           content: [%{"type" => "text", "text" => text}],
           details: details,
           is_error: true,
           diagnostic: to_string(reason)
         }}

      {:error, reason} ->
        {:error,
         %{
           content: [
             %{"type" => "text", "text" => "Command failed to start: #{inspect(reason)}"}
           ],
           details: %{reason: inspect(reason)},
           is_error: true,
           diagnostic: "exec_failed"
         }}
    end
  end

  defp maybe_put_opt(opts, _key, nil), do: opts
  defp maybe_put_opt(opts, key, val), do: Keyword.put(opts, key, val)

  defp maybe_put_on_output(opts, cb) when is_function(cb, 2) do
    counter = :atomics.new(1, signed: false)

    forwarder = fn chunk ->
      total = :atomics.add_get(counter, 1, byte_size(chunk))
      cb.(chunk, total)
    end

    Keyword.put(opts, :on_output, forwarder)
  end

  defp maybe_put_on_output(opts, cb) when is_function(cb, 1) do
    Keyword.put(opts, :on_output, cb)
  end

  defp maybe_put_on_output(opts, _), do: opts

  defp format_exec_output(result, error_note) do
    base =
      case result.output do
        "" ->
          if(is_nil(error_note) and Map.get(result, :exit_code) == 0, do: "(no output)", else: "")

        out ->
          out
      end

    trunc_note =
      if result.truncated do
        "\n\n[Output truncated: #{result.skipped_bytes} bytes omitted. Full output: #{result.full_output_path}]"
      else
        ""
      end

    exit_note =
      cond do
        is_binary(error_note) ->
          if(base == "", do: error_note, else: "\n\n" <> error_note)

        Map.get(result, :exit_code, 0) != 0 ->
          msg = "Command exited with status #{result.exit_code}"
          if(base == "", do: msg, else: "\n\n" <> msg)

        true ->
          ""
      end

    base <> trunc_note <> exit_note
  end

  defp fetch_arg(args, str_key, atom_key) do
    case Map.fetch(args, str_key) do
      {:ok, val} -> val
      :error -> Map.get(args, atom_key)
    end
  end
end
