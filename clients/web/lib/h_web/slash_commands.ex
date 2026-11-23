defmodule HWeb.SlashCommands do
  @moduledoc """
  Slash command registry, parser, argument completion, and path/directory
  completion helpers for `HWeb`.

  Keeps command metadata, parsing, and path resolution pure and reusable across
  `SessionLive`, `WorkspaceLive`, and client-side completion scripts.
  """

  alias HWeb.Backend

  @thinking_levels ~w(off minimal low medium high xhigh)
  @attention_args ~w(on off)
  @archive_args ~w(force off)

  @commands [
    %{
      name: "/help",
      usage: "/help",
      arg_hint: nil,
      takes_arg: false,
      description: "Show available slash commands"
    },
    %{
      name: "/tree",
      usage: "/tree",
      arg_hint: nil,
      takes_arg: false,
      description: "Browse turn-step session tree"
    },
    %{
      name: "/branches",
      usage: "/branches",
      arg_hint: nil,
      takes_arg: false,
      description: "Browse conversation branches (alias for /tree)"
    },
    %{
      name: "/conv",
      usage: "/conv <id>",
      arg_hint: "<id>",
      takes_arg: true,
      description: "Switch to conversation by ID"
    },
    %{
      name: "/branch",
      usage: "/branch [<entry_id>]",
      arg_hint: "[<entry_id>]",
      takes_arg: true,
      description: "Fork conversation after an entry"
    },
    %{
      name: "/fork",
      usage: "/fork [<user_entry_id> | cancel]",
      arg_hint: "[<entry_id> | cancel]",
      takes_arg: true,
      description: "Edit an earlier user prompt on a new branch"
    },
    %{
      name: "/cwd",
      usage: "/cwd [<dir>]",
      arg_hint: "[<dir>]",
      takes_arg: true,
      description: "Show workspace directory or fork session into <dir>"
    },
    %{
      name: "/new",
      usage: "/new",
      arg_hint: nil,
      takes_arg: false,
      description: "Create a new session in this workspace"
    },
    %{
      name: "/inbox",
      usage: "/inbox",
      arg_hint: nil,
      takes_arg: false,
      description: "Navigate to Inbox"
    },
    %{
      name: "/workspaces",
      usage: "/workspaces",
      arg_hint: nil,
      takes_arg: false,
      description: "Navigate to Workspaces"
    },
    %{
      name: "/resume",
      usage: "/resume",
      arg_hint: nil,
      takes_arg: false,
      description: "Open session switcher"
    },
    %{
      name: "/sessions",
      usage: "/sessions",
      arg_hint: nil,
      takes_arg: false,
      description: "Open session switcher (alias for /resume)"
    },
    %{
      name: "/parent",
      usage: "/parent",
      arg_hint: nil,
      takes_arg: false,
      description: "Navigate to parent session"
    },
    %{
      name: "/review",
      usage: "/review",
      arg_hint: nil,
      takes_arg: false,
      description: "Open workspace file review"
    },
    %{
      name: "/files",
      usage: "/files",
      arg_hint: nil,
      takes_arg: false,
      description: "Open workspace file review (alias for /review)"
    },
    %{
      name: "/model",
      usage: "/model [<model_id>]",
      arg_hint: "[<model_id>]",
      takes_arg: true,
      description: "Switch model or open Agent settings"
    },
    %{
      name: "/thinking",
      usage: "/thinking [<level>]",
      arg_hint: "[off|minimal|low|medium|high|xhigh]",
      takes_arg: true,
      description: "Set reasoning effort or open Agent settings"
    },
    %{
      name: "/compact",
      usage: "/compact [<instructions>]",
      arg_hint: "[<instructions>]",
      takes_arg: true,
      description: "Compact conversation history"
    },
    %{
      name: "/continue",
      usage: "/continue",
      arg_hint: nil,
      takes_arg: false,
      description: "Continue conversation"
    },
    %{
      name: "/abort",
      usage: "/abort",
      arg_hint: nil,
      takes_arg: false,
      description: "Abort active work in this conversation"
    },
    %{
      name: "/stop",
      usage: "/stop",
      arg_hint: nil,
      takes_arg: false,
      description: "Stop active work across all conversations"
    },
    %{
      name: "/dequeue",
      usage: "/dequeue",
      arg_hint: nil,
      takes_arg: false,
      description: "Withdraw queued prompts back into draft"
    },
    %{
      name: "/name",
      usage: "/name [<title>]",
      arg_hint: "[<title>]",
      takes_arg: true,
      description: "Show or rename session title"
    },
    %{
      name: "/attention",
      usage: "/attention [on|off]",
      arg_hint: "[on|off]",
      takes_arg: true,
      description: "Toggle or set needs_attention flag"
    },
    %{
      name: "/archive",
      usage: "/archive [force|off]",
      arg_hint: "[force|off]",
      takes_arg: true,
      description: "Archive (or unarchive) this session"
    },
    %{
      name: "/steer",
      usage: "/steer <message>",
      arg_hint: "<message>",
      takes_arg: true,
      description: "Steer the active run"
    },
    %{
      name: "/follow-up",
      usage: "/follow-up <message>",
      arg_hint: "<message>",
      takes_arg: true,
      description: "Queue follow-up message"
    }
  ]

  @command_names MapSet.new(Enum.map(@commands, & &1.name))

  @doc "Returns all supported web slash command specs."
  @spec all() :: [map()]
  def all, do: @commands

  @doc "Returns the supported reasoning/thinking levels."
  @spec thinking_levels() :: [String.t()]
  def thinking_levels, do: @thinking_levels

  @doc """
  Builds JSON-serializable client completion metadata for the composer hook.
  """
  @spec client_metadata(map()) :: map()
  def client_metadata(model_groups) when is_map(model_groups) do
    models =
      model_groups
      |> Map.values()
      |> List.flatten()
      |> Enum.map(fn m ->
        %{
          id: m.id,
          label: m[:name] || m.id,
          provider: m[:provider] || ""
        }
      end)
      |> Enum.uniq_by(& &1.id)
      |> Enum.sort_by(& &1.id)

    %{
      commands: @commands,
      thinking_levels: @thinking_levels,
      attention_args: @attention_args,
      archive_args: @archive_args,
      models: models
    }
  end

  def client_metadata(_), do: client_metadata(%{})

  @doc """
  Parses raw composer text into a slash command, user shell command, escaped
  slash prompt, or regular message.

  Returns:
  - `{:command, cmd_name, arg}` for known commands (including `"/"` -> `"/help"`)
  - `{:unknown_command, cmd_name}` for single-line unknown `/...` commands
  - `{:user_shell, command, include_in_context?}` for single-line `!cmd` / `!!cmd`
  - `{:message, text}` for normal prompts (with `//...` unescaped to `/...`)
  """
  @spec parse_input(String.t()) ::
          {:command, String.t(), String.t()}
          | {:unknown_command, String.t()}
          | {:user_shell, String.t(), boolean()}
          | {:message, String.t()}
  def parse_input(raw) when is_binary(raw) do
    trimmed = String.trim(raw)

    cond do
      trimmed == "" ->
        {:message, ""}

      String.starts_with?(trimmed, "//") ->
        {:message, String.replace_prefix(trimmed, "/", "")}

      String.starts_with?(trimmed, "/") and not String.contains?(trimmed, "\n") ->
        parse_slash_line(trimmed)

      String.starts_with?(trimmed, "!") and not String.contains?(trimmed, "\n") ->
        parse_shell_line(trimmed)

      true ->
        {:message, trimmed}
    end
  end

  def parse_input(_), do: {:message, ""}

  defp parse_slash_line("/") do
    {:command, "/help", ""}
  end

  defp parse_slash_line(line) do
    {cmd, arg} =
      case String.split(line, ~r/\s+/, parts: 2) do
        [c] -> {c, ""}
        [c, rest] -> {c, String.trim(rest)}
      end

    cmd_down = String.downcase(cmd)

    if MapSet.member?(@command_names, cmd_down) do
      {:command, cmd_down, arg}
    else
      {:unknown_command, cmd}
    end
  end

  defp parse_shell_line("!!" <> rest) do
    cmd = String.trim(rest)

    if cmd == "" do
      {:message, "!!"}
    else
      {:user_shell, cmd, false}
    end
  end

  defp parse_shell_line("!" <> rest) do
    cmd = String.trim(rest)

    if cmd == "" do
      {:message, "!"}
    else
      {:user_shell, cmd, true}
    end
  end

  @doc """
  Returns matching slash commands for a prefix like `"/"` or `"/tr"` or fuzzy
  substring matches, prioritizing exact prefix matches.
  """
  @spec match_commands(String.t()) :: [map()]
  def match_commands(prefix) when is_binary(prefix) do
    q = String.downcase(String.trim(prefix))

    cond do
      q == "" or q == "/" ->
        @commands

      String.starts_with?(q, "/") ->
        {prefix_matches, other_matches} =
          @commands
          |> Enum.filter(fn cmd ->
            String.starts_with?(cmd.name, q) or
              String.contains?(cmd.name, String.trim_leading(q, "/"))
          end)
          |> Enum.split_with(&String.starts_with?(&1.name, q))

        prefix_matches ++ other_matches

      true ->
        []
    end
  end

  @doc """
  Computes static argument completions for commands with known finite/catalog
  arguments (`/thinking`, `/model`, `/attention`, `/archive`, `/fork`).
  """
  @spec complete_command_args(String.t(), String.t(), keyword()) :: [map()]
  def complete_command_args(cmd, arg_prefix, opts \\ [])
      when is_binary(cmd) and is_binary(arg_prefix) do
    q = String.downcase(arg_prefix)

    case String.downcase(cmd) do
      "/thinking" ->
        @thinking_levels
        |> Enum.filter(&String.starts_with?(&1, q))
        |> Enum.map(&%{value: &1, label: &1, description: "Reasoning effort"})

      "/attention" ->
        @attention_args
        |> Enum.filter(&String.starts_with?(&1, q))
        |> Enum.map(fn val ->
          desc = if val == "on", do: "Mark for attention", else: "Mark as read"
          %{value: val, label: val, description: desc}
        end)

      "/archive" ->
        @archive_args
        |> Enum.filter(&String.starts_with?(&1, q))
        |> Enum.map(fn val ->
          desc = if val == "force", do: "Stop work and archive", else: "Restore from archive"
          %{value: val, label: val, description: desc}
        end)

      "/fork" ->
        if String.starts_with?("cancel", q) do
          [%{value: "cancel", label: "cancel", description: "Cancel active fork-edit"}]
        else
          []
        end

      "/model" ->
        models = Keyword.get(opts, :models, [])

        {pref, contains} =
          models
          |> Enum.filter(fn m ->
            id = String.downcase(m.id || "")
            label = String.downcase(m[:label] || m[:name] || "")

            q == "" or String.starts_with?(id, q) or String.contains?(id, q) or
              String.contains?(label, q)
          end)
          |> Enum.split_with(&String.starts_with?(String.downcase(&1.id || ""), q))

        (pref ++ contains)
        |> Enum.take(30)
        |> Enum.map(fn m ->
          %{
            value: m.id,
            label: m.id,
            description: m[:label] || m[:name] || m[:provider] || ""
          }
        end)

      _ ->
        []
    end
  end

  @doc """
  Computes inline ghost suffix text for a typed input prefix against a top
  completion value. Returns `""` when the value does not extend `typed`.
  """
  @spec ghost_suffix(String.t(), String.t()) :: String.t()
  def ghost_suffix(typed, completion)
      when is_binary(typed) and is_binary(completion) do
    if typed != "" and String.starts_with?(String.downcase(completion), String.downcase(typed)) and
         String.length(completion) > String.length(typed) do
      String.slice(completion, String.length(typed)..-1//1)
    else
      ""
    end
  end

  def ghost_suffix(_, _), do: ""

  @doc """
  Resolves a user-entered directory path for `/cwd <dir>` against `env_id` and
  `base_cwd`, supporting absolute `/...`, `~` / `~/...` on `"host"`, and
  relative paths.
  """
  @spec resolve_cwd_input(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, String.t()} | {:error, String.t()}
  def resolve_cwd_input(raw, env_id, base_cwd, opts \\ [])
      when is_binary(raw) and is_binary(env_id) and is_binary(base_cwd) do
    input = String.trim(raw)
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)

    cond do
      input == "" ->
        {:error, "Enter a directory path."}

      input == "~" or String.starts_with?(input, "~/") ->
        cond do
          env_id != "host" ->
            {:error, "Use an absolute path for non-host environment #{env_id}."}

          not is_binary(home) or home == "" ->
            {:error, "Unable to expand ~: home directory is unavailable."}

          input == "~" ->
            {:ok, normalize_posix_path(home)}

          true ->
            rest = String.trim_leading(input, "~/")
            {:ok, normalize_posix_path(Path.join(home, rest))}
        end

      String.starts_with?(input, "/") ->
        {:ok, normalize_posix_path(input)}

      String.starts_with?(base_cwd, "/") ->
        {:ok, normalize_posix_path(Path.join(base_cwd, input))}

      true ->
        {:error, "Enter an absolute directory path (session has no absolute working directory)."}
    end
  end

  @doc """
  Lists matching directories for `/cwd <prefix>` and directory path inputs,
  matching `hi`'s `completion::directories` semantics.

  Options:
  - `:backend` — module implementing `list_files/2` (default `HWeb.Backend`)
  - `:home` — override home directory for `~` expansion in tests
  - `:limit` — max returned items (default `50`)
  """
  @spec complete_directories(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def complete_directories(env_id, fallback_cwd, prefix, opts \\ [])
      when is_binary(env_id) and is_binary(fallback_cwd) and is_binary(prefix) do
    backend = Keyword.get(opts, :backend, Backend)
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, parent, display_dir, basename} <-
           resolve_lookup_target(env_id, fallback_cwd, prefix, home, expand_tilde?: true) do
      include_hidden? = String.starts_with?(basename, ".")

      params = %{
        "env_id" => env_id,
        "cwd" => parent,
        "max_depth" => 1,
        "limit" => 200,
        "include_dirs" => true,
        "include_hidden" => include_hidden?
      }

      params = if basename == "", do: params, else: Map.put(params, "query", basename)

      case backend.list_files(params) do
        {:ok, %{entries: entries}} ->
          base_down = String.downcase(basename)

          items =
            entries
            |> Enum.filter(fn entry ->
              entry_type(entry) == "dir" and valid_child_name?(entry_path(entry), base_down)
            end)
            |> Enum.map(fn entry ->
              name = entry_path(entry)

              %{
                value: display_dir <> name <> "/",
                label: name <> "/",
                kind: "dir"
              }
            end)
            |> Enum.sort_by(& &1.value)
            |> Enum.uniq_by(& &1.value)
            |> Enum.take(limit)

          {:ok, items}

        {:error, :not_found} ->
          {:ok, []}

        {:error, {:bad_request, _}} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Lists matching directories and files for inline composer path completion
  (e.g. `./foo`, `../bar`, `lib/h`, `/etc/`), matching `hi`'s `completion::paths`.
  Directories sort first (with trailing `/`), followed by files.
  """
  @spec complete_paths(String.t(), String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def complete_paths(env_id, cwd, prefix, opts \\ [])
      when is_binary(env_id) and is_binary(cwd) and is_binary(prefix) do
    backend = Keyword.get(opts, :backend, Backend)
    home = Keyword.get_lazy(opts, :home, &System.user_home/0)
    shell? = Keyword.get(opts, :shell?, false)
    limit = Keyword.get(opts, :limit, 50)

    with {:ok, parent, display_dir, basename} <-
           resolve_lookup_target(env_id, cwd, prefix, home, expand_tilde?: true) do
      include_hidden? = String.starts_with?(basename, ".")

      params = %{
        "env_id" => env_id,
        "cwd" => parent,
        "max_depth" => 1,
        "limit" => 200,
        "include_dirs" => true,
        "include_hidden" => include_hidden?
      }

      params = if basename == "", do: params, else: Map.put(params, "query", basename)

      case backend.list_files(params) do
        {:ok, %{entries: entries}} ->
          base_down = String.downcase(basename)

          items =
            entries
            |> Enum.reduce([], fn entry, acc ->
              name = entry_path(entry)
              kind = entry_type(entry)

              cond do
                not valid_child_name?(name, base_down) ->
                  acc

                shell? and not shell_safe_name?(name) ->
                  acc

                kind == "dir" ->
                  [%{value: display_dir <> name <> "/", label: name <> "/", kind: "dir"} | acc]

                kind == "file" ->
                  [%{value: display_dir <> name, label: name, kind: "file"} | acc]

                true ->
                  acc
              end
            end)
            |> Enum.sort_by(fn item -> {if(item.kind == "dir", do: 0, else: 1), item.value} end)
            |> Enum.uniq_by(& &1.value)
            |> Enum.take(limit)

          {:ok, items}

        {:error, :not_found} ->
          {:ok, []}

        {:error, {:bad_request, _}} ->
          {:ok, []}

        {:error, reason} ->
          {:error, reason}
      end
    end
  end

  @doc """
  Lists matching workspace files and directories for `@<query>` completion in a
  session via `Backend.list_session_files/2`.
  """
  @spec complete_session_files(String.t(), String.t(), keyword()) ::
          {:ok, [map()]} | {:error, term()}
  def complete_session_files(session_id, query, opts \\ [])
      when is_binary(session_id) and is_binary(query) do
    backend = Keyword.get(opts, :backend, Backend)
    limit = Keyword.get(opts, :limit, 50)
    clean_query = String.trim(query)

    # A bare @ browses the root. With a directory prefix, browse just its
    # children instead of filling the menu with every descendant of that path.
    segments = String.split(clean_query, "/")
    parent = segments |> Enum.drop(-1) |> Enum.join("/")
    parent_prefix = if parent == "", do: "", else: String.downcase(parent) <> "/"

    params = %{
      "limit" => limit,
      "include_dirs" => true,
      "include_hidden" => Enum.any?(segments, &String.starts_with?(&1, "."))
    }

    params =
      cond do
        clean_query == "" ->
          Map.put(params, "max_depth", 1)

        parent_prefix != "" ->
          Map.merge(params, %{"query" => clean_query, "max_depth" => min(length(segments), 32)})

        true ->
          Map.put(params, "query", clean_query)
      end

    case backend.list_session_files(session_id, params) do
      {:ok, %{entries: entries}} ->
        q_down = String.downcase(clean_query)

        candidates =
          entries
          |> Enum.reduce([], fn entry, acc ->
            rel = entry_path(entry)
            kind = entry_type(entry)

            cond do
              not is_binary(rel) or rel == "" or has_control_chars?(rel) ->
                acc

              parent_prefix != "" and not String.starts_with?(String.downcase(rel), q_down) ->
                acc

              parent_prefix != "" and
                  String.contains?(
                    String.replace_prefix(String.downcase(rel), parent_prefix, ""),
                    "/"
                  ) ->
                acc

              kind == "dir" ->
                [%{value: rel <> "/", label: rel <> "/", kind: "dir"} | acc]

              kind == "file" ->
                [%{value: rel, label: rel, kind: "file"} | acc]

              true ->
                acc
            end
          end)
          |> Enum.sort_by(fn item ->
            val_down = String.downcase(item.value)

            prefix_rank =
              if(q_down != "" and String.starts_with?(val_down, q_down), do: 0, else: 1)

            {prefix_rank, if(item.kind == "dir", do: 0, else: 1), item.value}
          end)
          |> Enum.uniq_by(& &1.value)
          |> Enum.take(limit)

        # A matching folder already offers a way to reach its descendants.
        # Keep recursive search hits from elsewhere, but don't repeat that subtree.
        matching_dirs =
          for %{kind: "dir", value: path} <- candidates,
              String.starts_with?(String.downcase(path), q_down),
              do: path

        items =
          Enum.reject(candidates, fn %{value: path} ->
            Enum.any?(matching_dirs, &(&1 != path and String.starts_with?(path, &1)))
          end)

        {:ok, items}

      {:error, :not_found} ->
        {:ok, []}

      {:error, reason} ->
        {:error, reason}
    end
  end

  # Internal path lookup helpers

  defp resolve_lookup_target(env_id, fallback_cwd, prefix, home, opts) do
    expand_tilde? = Keyword.get(opts, :expand_tilde?, true)

    {display_prefix, lookup_prefix} =
      if expand_tilde? and env_id == "host" and
           (prefix == "~" or String.starts_with?(prefix, "~/")) and
           is_binary(home) and home != "" do
        trimmed_home = String.trim_trailing(home, "/")
        rest = String.replace_prefix(prefix, "~", "")

        if rest == "" do
          {"~/", trimmed_home <> "/"}
        else
          {prefix, trimmed_home <> rest}
        end
      else
        {prefix, prefix}
      end

    {dir, basename} = split_dir_and_basename(lookup_prefix)
    {display_dir, _} = split_dir_and_basename(display_prefix)

    parent =
      cond do
        String.starts_with?(dir, "/") ->
          normalize_posix_path(dir)

        not String.starts_with?(fallback_cwd, "/") ->
          nil

        dir == "" ->
          normalize_posix_path(fallback_cwd)

        true ->
          normalize_posix_path(Path.join(fallback_cwd, dir))
      end

    if is_binary(parent) and parent != "" do
      {:ok, parent, display_dir, basename}
    else
      {:error, {:bad_request, "no absolute base directory for path completion"}}
    end
  end

  defp split_dir_and_basename(str) do
    case :binary.matches(str, "/") do
      [] ->
        {"", str}

      matches ->
        {last_pos, 1} = List.last(matches)
        dir_len = last_pos + 1
        <<dir::binary-size(^dir_len), base::binary>> = str
        {dir, base}
    end
  end

  defp normalize_posix_path(path) do
    expanded = Path.expand(path, "/")
    if expanded == "", do: "/", else: expanded
  end

  defp entry_type(entry) when is_map(entry) do
    Map.get(entry, :type) || Map.get(entry, "type") || Map.get(entry, :kind) ||
      Map.get(entry, "kind")
  end

  defp entry_path(entry) when is_map(entry) do
    Map.get(entry, :path) || Map.get(entry, "path") || ""
  end

  defp valid_child_name?(name, base_down) when is_binary(name) do
    name not in ["", ".", ".."] and
      not String.contains?(name, "/") and
      not has_control_chars?(name) and
      String.starts_with?(String.downcase(name), base_down)
  end

  defp valid_child_name?(_, _), do: false

  defp has_control_chars?(str) do
    Regex.match?(~r/[\x00-\x1F\x7F]/u, str)
  end

  defp shell_safe_name?(name) do
    Regex.match?(~r/\A[A-Za-z0-9_\-.+]+\z/, name)
  end
end
