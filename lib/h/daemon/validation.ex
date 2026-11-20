defmodule H.Daemon.Validation do
  @moduledoc """
  Boundary parameter, query, and command envelope validation for `H.Daemon`.
  """

  alias H.Schema

  @default_discovery_limit 200
  @max_discovery_limit 500
  @default_discovery_depth 32
  @max_discovery_depth 32
  @max_discovery_query_bytes 512

  @default_read_file_limit 200
  @max_read_file_limit 2_000
  @default_read_file_bytes 51_200
  @max_read_file_bytes 65_536

  def param_get(map, str_key, atom_key) do
    case Map.fetch(map, str_key) do
      {:ok, val} -> val
      :error -> Map.get(map, atom_key)
    end
  end

  def parse_bool_param(true, _default), do: true
  def parse_bool_param("true", _default), do: true
  def parse_bool_param("1", _default), do: true
  def parse_bool_param(false, _default), do: false
  def parse_bool_param("false", _default), do: false
  def parse_bool_param("0", _default), do: false
  def parse_bool_param(_, default), do: default

  def drop_blank_optional(map, keys) do
    Enum.reduce(keys, map, fn k, acc ->
      if Map.get(acc, k) in [nil, ""], do: Map.delete(acc, k), else: acc
    end)
  end

  def validate_sid_or_not_found(session_id) do
    case Schema.validate_session_id(session_id) do
      {:ok, sid} -> {:ok, sid}
      {:error, _} -> {:error, :not_found}
    end
  end

  def ensure_not_quarantined(%{status: "quarantined"} = entry) do
    {:error, {:quarantined, entry.quarantine_reason || "quarantined"}}
  end

  def ensure_not_quarantined(_entry), do: :ok

  def parse_cid(cid) do
    case Schema.parse_pos_int(cid) do
      {:ok, id} -> {:ok, id}
      {:error, reason} -> {:error, {:bad_request, "conversation_id: #{reason}"}}
    end
  end

  def parse_last_event_id(nil), do: {:ok, nil}
  def parse_last_event_id(""), do: {:ok, nil}
  def parse_last_event_id(val) when is_integer(val) and val >= 0, do: {:ok, val}

  def parse_last_event_id(val) when is_binary(val) do
    if Regex.match?(~r/^\d+$/, val) do
      {:ok, String.to_integer(val)}
    else
      {:error, {:bad_request, "last_event_id must be a non-negative integer"}}
    end
  end

  def parse_last_event_id(_),
    do: {:error, {:bad_request, "last_event_id must be a non-negative integer"}}

  def parse_scan_query(params) do
    with {:ok, order} <- parse_order(param_get(params, "order", :order)),
         {:ok, cursor} <- parse_optional_pos_int(param_get(params, "cursor", :cursor), "cursor"),
         {:ok, limit} <- parse_limit(param_get(params, "limit", :limit)) do
      query =
        %{order: order, limit: limit}
        |> then(fn q -> if is_nil(cursor), do: q, else: Map.put(q, :cursor, cursor) end)

      {:ok, query}
    end
  end

  def validate_create_session_params(params) do
    normalized_params = drop_blank_optional(params, ["session_id", :session_id])

    with {:ok, validated} <-
           Schema.validate_map(normalized_params, [
             {:session_id, :session_id, required: false},
             {:env_id, :non_empty_string, required: false},
             {:harness_id, :non_empty_string, required: false},
             {:cwd, :abs_path, required: true},
             {:title, :string, required: false, nullable: true},
             {:parent,
              {:map,
               [
                 {:session_id, :session_id, required: true},
                 {:conversation_id, :pos_int, required: false},
                 {:at_entry_id, :pos_int, required: false, nullable: true},
                 {:task_id, :pos_int, required: false, nullable: true}
               ]}, required: false, nullable: true},
             {:role, :string, required: false, nullable: true},
             {:agent, :map, required: false},
             {:request_id, :non_empty_string, required: false}
           ]),
         {:ok, agent_opts} <- validate_optional_agent(Map.get(validated, :agent)),
         {:ok, validated} <- normalize_optional_title(validated),
         {:ok, validated} <- normalize_optional_role(validated) do
      {:ok, validated, agent_opts}
    else
      {:error, reason} when is_binary(reason) -> {:error, {:bad_request, reason}}
      {:error, _} = err -> err
    end
  end

  def validate_optional_agent(nil), do: {:ok, nil}

  def validate_optional_agent(agent) when is_map(agent) do
    Schema.validate_map(agent, [
      {:model, :string, required: false, nullable: true},
      {:thinking, :string, required: false, nullable: true},
      {:system_prompt, :string, required: false, nullable: true},
      {:instructions, :string, required: false, nullable: true},
      {:tools, {:list, :string}, required: false}
    ])
  end

  def validate_envelope(raw) do
    with {:ok, env} <-
           Schema.validate_map(raw, [
             {:version, {:literal, 1}, required: true},
             {:request_id, :non_empty_string, required: true},
             {:command,
              {:enum,
               [
                 "submit",
                 "fork",
                 "fork_and_submit",
                 "configure",
                 "abort",
                 "withdraw",
                 "rename",
                 "user_shell",
                 "compact"
               ]}, required: true},
             {:conversation_id, :pos_int, required: true},
             {:args, :map, default: %{}}
           ]),
         {:ok, validated_args} <- validate_command_args(env.command, env.args) do
      {:ok, %{env | args: validated_args}}
    else
      {:error, reason} when is_binary(reason) -> {:error, {:bad_request, reason}}
    end
  end

  def parse_list_files_params(params) do
    with {:ok, env_id} <- parse_required_env_id(param_get(params, "env_id", :env_id)),
         {:ok, cwd} <- parse_required_abs_cwd(param_get(params, "cwd", :cwd)),
         {:ok, query} <- parse_optional_query(param_get(params, "query", :query)),
         {:ok, include_hidden} <-
           parse_strict_bool(
             param_get(params, "include_hidden", :include_hidden),
             false,
             "include_hidden"
           ),
         {:ok, include_dirs} <-
           parse_strict_bool(
             param_get(params, "include_dirs", :include_dirs),
             true,
             "include_dirs"
           ),
         {:ok, exclude} <- parse_exclude_list(param_get(params, "exclude", :exclude)),
         {:ok, limit} <-
           parse_bounded_int(
             param_get(params, "limit", :limit),
             @default_discovery_limit,
             1,
             @max_discovery_limit,
             "limit"
           ),
         {:ok, max_depth} <-
           parse_bounded_int(
             param_get(params, "max_depth", :max_depth),
             @default_discovery_depth,
             1,
             @max_discovery_depth,
             "max_depth"
           ) do
      {:ok,
       %{
         env_id: env_id,
         cwd: cwd,
         query: query,
         include_hidden: include_hidden,
         include_dirs: include_dirs,
         exclude: exclude,
         limit: limit,
         max_depth: max_depth
       }}
    end
  end

  def parse_read_file_params(params) do
    with {:ok, env_id} <- parse_required_env_id(param_get(params, "env_id", :env_id)),
         {:ok, cwd} <- parse_required_abs_cwd(param_get(params, "cwd", :cwd)),
         {:ok, path} <- parse_required_file_path(param_get(params, "path", :path)),
         {:ok, offset} <-
           parse_bounded_int(param_get(params, "offset", :offset), 1, 1, 10_000_000, "offset"),
         {:ok, limit} <-
           parse_bounded_int(
             param_get(params, "limit", :limit),
             @default_read_file_limit,
             1,
             @max_read_file_limit,
             "limit"
           ),
         {:ok, max_bytes} <-
           parse_bounded_int(
             param_get(params, "max_bytes", :max_bytes),
             @default_read_file_bytes,
             1,
             @max_read_file_bytes,
             "max_bytes"
           ) do
      {:ok,
       %{
         env_id: env_id,
         cwd: cwd,
         path: path,
         offset: offset,
         limit: limit,
         max_bytes: max_bytes
       }}
    end
  end

  # Internal command & query validators

  defp parse_order(nil), do: {:ok, :desc}
  defp parse_order("desc"), do: {:ok, :desc}
  defp parse_order(:desc), do: {:ok, :desc}
  defp parse_order("asc"), do: {:ok, :asc}
  defp parse_order(:asc), do: {:ok, :asc}
  defp parse_order(_), do: {:error, {:bad_request, "order must be \"asc\" or \"desc\""}}

  defp parse_optional_pos_int(nil, _field), do: {:ok, nil}
  defp parse_optional_pos_int("", _field), do: {:ok, nil}

  defp parse_optional_pos_int(val, field) do
    case Schema.parse_pos_int(val) do
      {:ok, n} -> {:ok, n}
      {:error, reason} -> {:error, {:bad_request, "#{field}: #{reason}"}}
    end
  end

  defp parse_limit(nil), do: {:ok, 50}
  defp parse_limit(""), do: {:ok, 50}

  defp parse_limit(val) do
    case Schema.parse_pos_int(val) do
      {:ok, n} when n >= 1 and n <= 200 -> {:ok, n}
      {:ok, _} -> {:error, {:bad_request, "limit must be between 1 and 200"}}
      {:error, reason} -> {:error, {:bad_request, "limit: #{reason}"}}
    end
  end

  defp validate_command_args("submit", raw_args) do
    with {:ok, base} <-
           Schema.validate_map(raw_args, [
             {:type, {:enum, ["input", "continue", "write"]}, required: true}
           ]) do
      case base.type do
        "input" ->
          with {:ok, args} <-
                 Schema.validate_map(raw_args, [
                   {:type, {:literal, "input"}, required: true},
                   {:content, :any, required: true},
                   {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"},
                   {:when_idle, {:enum, ["start", "reject"]}, default: "start"}
                 ]),
               :ok <- validate_content(args.content) do
            {:ok, args}
          end

        "continue" ->
          {:ok, %{type: "continue"}}

        "write" ->
          Schema.validate_map(raw_args, [
            {:type, {:literal, "write"}, required: true},
            {:kind, :non_empty_string, default: "user"},
            {:content, :any, required: false},
            {:data, :map, required: false}
          ])
      end
    end
  end

  defp validate_command_args("fork", raw_args) do
    Schema.validate_map(raw_args, [
      {:at_entry_id, :pos_int, required: true}
    ])
  end

  defp validate_command_args("fork_and_submit", raw_args) do
    with {:ok, args} <-
           Schema.validate_map(raw_args, [
             {:at_entry_id, :pos_int, required: true},
             {:content, :any, required: true},
             {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"},
             {:when_idle, {:enum, ["start", "reject"]}, default: "start"}
           ]),
         :ok <- validate_content(args.content) do
      {:ok, args}
    end
  end

  defp validate_command_args("configure", raw_args) do
    Schema.validate_map(raw_args, [
      {:model, :string, required: false, nullable: true},
      {:thinking, :string, required: false, nullable: true},
      {:system_prompt, :string, required: false, nullable: true},
      {:instructions, :string, required: false, nullable: true},
      {:tools, {:list, :string}, required: false},
      {:expected_seq, {:int, min: 0}, required: false, nullable: true}
    ])
  end

  defp validate_command_args("abort", raw_args) do
    Schema.validate_map(raw_args, [
      {:task_id, :pos_int, required: false, nullable: true},
      {:reason, :string, required: false, nullable: true}
    ])
  end

  defp validate_command_args("withdraw", raw_args) do
    with {:ok, args} <-
           Schema.validate_map(raw_args, [
             {:submission_ids, {:list, :pos_int}, required: true}
           ]),
         :ok <- validate_non_empty_list(args.submission_ids, "submission_ids") do
      {:ok, %{args | submission_ids: Enum.uniq(args.submission_ids)}}
    end
  end

  defp validate_command_args("rename", raw_args) do
    with {:ok, args} <-
           Schema.validate_map(raw_args, [
             {:title, :string, required: true, nullable: true},
             {:expected_seq, {:int, min: 0}, required: false, nullable: true}
           ]),
         {:ok, normalized_title} <- normalize_title_arg(args.title) do
      {:ok, %{args | title: normalized_title}}
    end
  end

  defp validate_command_args("user_shell", raw_args) do
    H.Session.UserShell.validate_args(raw_args)
  end

  defp validate_command_args("compact", raw_args) do
    H.Session.Compaction.validate_args(raw_args)
  end

  defp normalize_optional_role(%{role: nil} = validated), do: {:ok, validated}

  defp normalize_optional_role(%{role: role} = validated) when is_binary(role) do
    trimmed = String.trim(role)

    cond do
      trimmed == "" ->
        {:ok, %{validated | role: nil}}

      String.contains?(role, <<0>>) or Regex.match?(~r/[\x00-\x1F\x7F]/u, role) ->
        {:error, "role: must not contain control characters"}

      String.length(trimmed) > 64 ->
        {:error, "role: must be at most 64 characters"}

      true ->
        {:ok, %{validated | role: trimmed}}
    end
  end

  defp normalize_optional_role(validated), do: {:ok, validated}

  defp normalize_optional_title(%{title: title} = validated) do
    case normalize_title_arg(title) do
      {:ok, normalized} -> {:ok, %{validated | title: normalized}}
      {:error, _} = err -> err
    end
  end

  defp normalize_optional_title(validated), do: {:ok, validated}

  defp normalize_title_arg(title) do
    case Schema.normalize_title(title) do
      {:ok, normalized} -> {:ok, normalized}
      {:error, reason} -> {:error, "title: #{reason}"}
    end
  end

  defp validate_non_empty_list([_ | _], _field), do: :ok
  defp validate_non_empty_list([], field), do: {:error, "#{field} must be a non-empty list"}

  defp validate_content(text) when is_binary(text) and byte_size(text) > 0, do: :ok

  defp validate_content(blocks) when is_list(blocks) and blocks != [] do
    if Enum.all?(blocks, &(is_map(&1) or is_binary(&1))) do
      :ok
    else
      {:error, "content items must be maps or strings"}
    end
  end

  defp validate_content(_), do: {:error, "content must be a non-empty string or block list"}

  defp parse_required_env_id(val) when is_binary(val) do
    if String.trim(val) == "" or String.contains?(val, <<0>>) do
      {:error, {:bad_request, "env_id is required"}}
    else
      {:ok, val}
    end
  end

  defp parse_required_env_id(_), do: {:error, {:bad_request, "env_id is required"}}

  defp parse_required_abs_cwd(val) when is_binary(val) do
    if val != "" and String.starts_with?(val, "/") and not String.contains?(val, <<0>>) do
      {:ok, val}
    else
      {:error, {:bad_request, "cwd must be an absolute path"}}
    end
  end

  defp parse_required_abs_cwd(_), do: {:error, {:bad_request, "cwd must be an absolute path"}}

  defp parse_required_file_path(val) when is_binary(val) do
    cond do
      String.trim(val) == "" ->
        {:error, {:bad_request, "path is required"}}

      String.contains?(val, <<0>>) ->
        {:error, {:bad_request, "invalid path"}}

      val == "~" or String.starts_with?(val, "~/") ->
        {:error, {:forbidden, "path outside workspace"}}

      true ->
        {:ok, val}
    end
  end

  defp parse_required_file_path(_), do: {:error, {:bad_request, "path is required"}}

  defp parse_optional_query(nil), do: {:ok, nil}
  defp parse_optional_query(""), do: {:ok, nil}

  defp parse_optional_query(val) when is_binary(val) do
    cond do
      String.contains?(val, <<0>>) ->
        {:error, {:bad_request, "query contains invalid bytes"}}

      byte_size(val) > @max_discovery_query_bytes ->
        {:error, {:bad_request, "query exceeds #{@max_discovery_query_bytes} bytes"}}

      true ->
        {:ok, val}
    end
  end

  defp parse_optional_query(_), do: {:error, {:bad_request, "query must be a string"}}

  defp parse_strict_bool(nil, default, _field), do: {:ok, default}
  defp parse_strict_bool("", default, _field), do: {:ok, default}
  defp parse_strict_bool(true, _default, _field), do: {:ok, true}
  defp parse_strict_bool("true", _default, _field), do: {:ok, true}
  defp parse_strict_bool("1", _default, _field), do: {:ok, true}
  defp parse_strict_bool(false, _default, _field), do: {:ok, false}
  defp parse_strict_bool("false", _default, _field), do: {:ok, false}
  defp parse_strict_bool("0", _default, _field), do: {:ok, false}
  defp parse_strict_bool(_, _default, field), do: {:error, {:bad_request, "invalid #{field}"}}

  defp parse_exclude_list(nil), do: {:ok, []}
  defp parse_exclude_list(""), do: {:ok, []}

  defp parse_exclude_list(val) when is_binary(val) do
    val
    |> String.split(",", trim: true)
    |> Enum.map(&String.trim/1)
    |> Enum.reject(&(&1 == ""))
    |> parse_exclude_list()
  end

  defp parse_exclude_list(items) when is_list(items) do
    if Enum.all?(items, fn item ->
         is_binary(item) and item != "" and not String.contains?(item, ["/", <<0>>])
       end) do
      {:ok, items}
    else
      {:error, {:bad_request, "invalid exclude"}}
    end
  end

  defp parse_exclude_list(_), do: {:error, {:bad_request, "invalid exclude"}}

  defp parse_bounded_int(nil, default, _min, _max, _field), do: {:ok, default}
  defp parse_bounded_int("", default, _min, _max, _field), do: {:ok, default}

  defp parse_bounded_int(val, _default, min, max, field) do
    case Schema.parse_pos_int(val) do
      {:ok, n} when n >= min and n <= max -> {:ok, n}
      {:ok, _} -> {:error, {:bad_request, "#{field} must be between #{min} and #{max}"}}
      {:error, reason} -> {:error, {:bad_request, "#{field}: #{reason}"}}
    end
  end
end
