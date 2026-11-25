defmodule H.Harness.Coding do
  @moduledoc """
  Default `Pi`-compatible coding harness profile (`id: "coding"`).

  Provides the standard coding tool suite (`read`, `write`, `edit`, `bash`,
  `search_history`) and hierarchical `AGENTS.md` discovery exclusively through
  `H.ExecutionEnv`.
  """

  @behaviour H.Harness

  alias H.ExecutionEnv
  alias H.Tools.{Bash, Edit, Read, SearchHistory, Subagent, WaitSignal, Write}

  @base_tools [Read, Write, Edit, Bash, SearchHistory, WaitSignal]
  @default_max_subagent_depth 1
  @max_parent_hops 25
  @max_agents_bytes 65_536

  @impl true
  def id, do: "coding"

  @impl true
  def descriptor do
    %{
      id: "coding",
      name: "Coding",
      description:
        "General-purpose coding harness with filesystem, shell, and history search tools."
    }
  end

  @impl true
  def tools(opts \\ []) do
    case Keyword.fetch(opts, :tools) do
      {:ok, explicit} ->
        explicit

      :error ->
        depth = Keyword.get(opts, :session_depth, 0) || 0
        max_depth = Keyword.get(opts, :max_subagent_depth, @default_max_subagent_depth)

        if depth < max_depth do
          @base_tools ++ [Subagent]
        else
          @base_tools
        end
    end
  end

  @impl true
  def bootstrap_agent(env, overrides \\ %{}, opts \\ [])
      when is_map(overrides) and is_list(opts) do
    merged =
      overrides
      |> maybe_put_tools(opts)
      |> maybe_put_instructions(env, opts)

    {:ok, merged}
  end

  defp maybe_put_tools(overrides, opts) do
    has_tools? =
      non_nil_override?(overrides, "tools", :tools)

    if has_tools? do
      overrides
    else
      overrides
      |> Map.delete(:tools)
      |> Map.put("tools", Enum.map(tools(opts), & &1.name()))
    end
  end

  defp maybe_put_instructions(overrides, env, opts) do
    if non_nil_override?(overrides, "instructions", :instructions) do
      overrides
    else
      case discover_instructions(env, opts) do
        nil ->
          overrides

        instructions ->
          overrides
          |> Map.delete(:instructions)
          |> Map.put("instructions", instructions)
      end
    end
  end

  defp non_nil_override?(overrides, str_key, atom_key) do
    not is_nil(Map.get(overrides, str_key)) or not is_nil(Map.get(overrides, atom_key))
  end

  defp discover_instructions(env, opts) do
    cwd = ExecutionEnv.cwd(env)
    stop_dir = resolve_stop_dir(env, Keyword.get(opts, :stop_dir))

    cwd
    |> walk_ancestors(stop_dir, env, 0, [])
    |> case do
      [] -> nil
      parts -> Enum.join(parts, "\n\n")
    end
  end

  defp resolve_stop_dir(_env, nil), do: "/"
  defp resolve_stop_dir(_env, ""), do: "/"

  defp resolve_stop_dir(env, stop_dir) when is_binary(stop_dir) do
    case ExecutionEnv.resolve_path(env, stop_dir) do
      {:ok, resolved} -> resolved
      {:error, _} -> "/"
    end
  end

  defp walk_ancestors(dir, stop_dir, env, hops, acc) do
    acc =
      case read_agents_file(env, Path.join(dir, "AGENTS.md")) do
        nil -> acc
        content -> [content | acc]
      end

    parent = Path.dirname(dir)

    if dir == stop_dir or parent == dir or hops >= @max_parent_hops do
      acc
    else
      walk_ancestors(parent, stop_dir, env, hops + 1, acc)
    end
  end

  defp read_agents_file(env, path) do
    case ExecutionEnv.read_file_bytes(env, path, max_bytes: @max_agents_bytes) do
      {:ok, bytes} when is_binary(bytes) ->
        trimmed =
          if String.valid?(bytes) do
            String.trim(bytes)
          else
            bytes |> String.replace_invalid() |> String.trim()
          end

        if trimmed == "", do: nil, else: trimmed

      {:error, _reason} ->
        nil
    end
  end
end
