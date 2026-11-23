defmodule H.Session.Tree do
  @moduledoc """
  Read-only session-wide entry tree builder for live, cold native, and imported
  archived sessions.

  Projects raw session entries into bounded, single-line sanitized summary nodes
  with explicit `parent_id` links and per-conversation `leaf_entry_id` pointers
  without ever leaking raw base64 payloads or unbounded tool outputs.
  """

  @max_nodes 5_000
  @max_preview_graphemes 200
  @max_tool_arg_graphemes 80

  @doc "Maximum number of entry nodes included in a single tree response."
  @spec max_nodes() :: pos_integer()
  def max_nodes, do: @max_nodes

  @doc """
  Builds `{conversations_wire, nodes_wire, truncated?}` from a native
  `conversations` map (`%{cid => %{id, parent, owner, entry_ids}}`) and a list
  of entries (in any order).
  """
  @spec build_native(map(), [map()], keyword()) :: {[map()], [map()], boolean()}
  def build_native(conversations, entries, opts \\ [])
      when is_map(conversations) and is_list(entries) and is_list(opts) do
    max_nodes = Keyword.get(opts, :max_nodes, @max_nodes)

    parent_map = compute_native_parent_map(conversations)

    sorted_entries = Enum.sort_by(entries, &entry_id_int/1)
    {kept_entries, truncated?} = take_latest(sorted_entries, max_nodes)

    tool_calls_index = build_tool_calls_index(sorted_entries)

    nodes =
      Enum.map(kept_entries, fn entry ->
        id = entry_id_int(entry)
        parent_id = Map.get(parent_map, id)
        build_node(entry, parent_id, tool_calls_index)
      end)

    wired_convs =
      conversations
      |> Map.values()
      |> Enum.sort_by(& &1.id)
      |> Enum.map(&wire_native_conversation/1)

    {wired_convs, nodes, truncated?}
  end

  @doc """
  Builds `{conversations_wire, nodes_wire, truncated?}` from an imported
  `H.Archive` (`conversations` map `%{cid => %{parent: nil | {pcid, at}, head: id | nil}}`,
  `entries_index` map `%{id => {cid, parent_id, offset, size}}`, and decoded
  selected entries in ascending ID order).
  """
  @spec build_archive(map(), map(), [map()], boolean()) :: {[map()], [map()], boolean()}
  def build_archive(conversations, entries_index, decoded_entries, truncated?)
      when is_map(conversations) and is_map(entries_index) and is_list(decoded_entries) and
             is_boolean(truncated?) do
    tool_calls_index = build_tool_calls_index(decoded_entries)

    nodes =
      Enum.map(decoded_entries, fn entry ->
        id = entry_id_int(entry)

        parent_id =
          case Map.get(entries_index, id) do
            {_cid, pid, _offset, _size} -> pid
            _ -> nil
          end

        build_node(entry, parent_id, tool_calls_index)
      end)

    wired_convs =
      conversations
      |> Enum.sort()
      |> Enum.map(fn {cid, branch} ->
        parent =
          case branch.parent do
            nil -> nil
            {pcid, at} -> %{conversation_id: to_string(pcid), at: to_string(at)}
          end

        leaf =
          cond do
            is_integer(branch.head) ->
              to_string(branch.head)

            match?({_pcid, at} when is_integer(at), branch.parent) ->
              to_string(elem(branch.parent, 1))

            true ->
              nil
          end

        %{
          id: to_string(cid),
          parent: parent,
          owner: "ownerless",
          leaf_entry_id: leaf
        }
      end)

    {wired_convs, nodes, truncated?}
  end

  @doc """
  Selects up to `max_nodes` latest IDs from an ascending list of IDs, returning
  `{selected_ids_asc, truncated?}`.
  """
  @spec take_latest([term()], pos_integer()) :: {[term()], boolean()}
  def take_latest(list, max_nodes \\ @max_nodes)
      when is_list(list) and is_integer(max_nodes) and max_nodes > 0 do
    total = length(list)

    if total > max_nodes do
      {Enum.drop(list, total - max_nodes), true}
    else
      {list, false}
    end
  end

  # Conversation ancestry and parent pointers

  defp compute_native_parent_map(conversations) do
    Enum.reduce(conversations, %{}, fn {_cid, conv}, acc ->
      own_ids_asc =
        conv
        |> Map.get(:entry_ids, [])
        |> Enum.sort()

      initial_parent =
        case Map.get(conv, :parent) do
          %{at: at} when is_integer(at) -> at
          _ -> nil
        end

      {next_acc, _prev} =
        Enum.reduce(own_ids_asc, {acc, initial_parent}, fn id, {map_acc, prev_id} ->
          {Map.put(map_acc, id, prev_id), id}
        end)

      next_acc
    end)
  end

  defp wire_native_conversation(conv) do
    parent =
      case Map.get(conv, :parent) do
        nil ->
          nil

        %{conversation_id: pid, at: at} ->
          %{conversation_id: to_string(pid), at: to_string(at)}
      end

    owner =
      case Map.get(conv, :owner, :ownerless) do
        :ownerless -> "ownerless"
        {:conversation, cid} -> "conversation:#{cid}"
        {:task, tid} -> "task:#{tid}"
        other when is_binary(other) -> other
      end

    leaf_entry_id =
      case Map.get(conv, :entry_ids, []) do
        [] ->
          case Map.get(conv, :parent) do
            %{at: at} when is_integer(at) -> to_string(at)
            _ -> nil
          end

        ids when is_list(ids) ->
          ids |> Enum.max() |> to_string()
      end

    %{
      id: to_string(conv.id),
      parent: parent,
      owner: owner,
      leaf_entry_id: leaf_entry_id
    }
  end

  # Tool call index (call_id => %{name, arguments})

  defp build_tool_calls_index(entries) do
    Enum.reduce(entries, %{}, fn entry, acc ->
      if entry_kind(entry) == "assistant" do
        data = entry_data(entry)
        tool_calls = fetch(data, :tool_calls)

        if is_list(tool_calls) do
          Enum.reduce(tool_calls, acc, fn tc, tc_acc ->
            if is_map(tc) do
              call_id = fetch_string(tc, :id)
              name = fetch_string(tc, :name)
              args = fetch(tc, :arguments) || %{}

              if is_binary(call_id) and call_id != "" do
                Map.put(tc_acc, call_id, %{
                  name: name,
                  arguments: if(is_map(args), do: args, else: %{})
                })
              else
                tc_acc
              end
            else
              tc_acc
            end
          end)
        else
          acc
        end
      else
        acc
      end
    end)
  end

  # Node projection per kind

  defp build_node(entry, parent_id, tool_calls_index) do
    id = entry_id_int(entry)
    cid = entry_cid_str(entry)
    kind = entry_kind(entry) || "unknown"
    data = entry_data(entry)
    created_at = normalize_created_at(fetch(entry, :created_at))

    summary = summarize_entry(kind, data, tool_calls_index)

    %{
      id: to_string(id),
      parent_id: if(is_integer(parent_id), do: to_string(parent_id), else: nil),
      conversation_id: cid,
      kind: kind,
      preview: summary.preview,
      has_text: summary.has_text,
      tool_name: summary.tool_name,
      aborted: summary.aborted,
      is_error: summary.is_error,
      error: summary.is_error,
      created_at: created_at
    }
  end

  defp summarize_entry("user", data, _tool_calls_index) do
    {text, has_non_text?} = extract_text_and_attachment(data)
    clean_text = sanitize_preview(text)

    cond do
      clean_text != "" ->
        %{preview: clean_text, has_text: true, tool_name: nil, aborted: false, is_error: false}

      has_non_text? ->
        %{
          preview: "[attachment]",
          has_text: false,
          tool_name: nil,
          aborted: false,
          is_error: false
        }

      true ->
        %{preview: "", has_text: false, tool_name: nil, aborted: false, is_error: false}
    end
  end

  defp summarize_entry("assistant", data, _tool_calls_index) do
    {text, _has_non_text?} = extract_text_and_attachment(data)
    clean_text = sanitize_preview(text)
    has_text? = clean_text != ""

    finish_reason = fetch_string(data, :finish_reason) || fetch_string(data, :stop_reason)
    aborted? = fetch(data, :aborted) == true or finish_reason == "aborted"

    err_msg = extract_error_message(data)
    is_error? = is_binary(err_msg) or finish_reason == "error" or fetch(data, :is_error) == true

    tool_calls =
      case fetch(data, :tool_calls) do
        list when is_list(list) -> Enum.filter(list, &is_map/1)
        _ -> []
      end

    preview =
      cond do
        has_text? ->
          clean_text

        tool_calls != [] ->
          format_assistant_tool_calls(tool_calls)

        aborted? ->
          "(aborted)"

        is_binary(err_msg) ->
          sanitize_preview(err_msg)

        is_error? ->
          "(error)"

        true ->
          "(no content)"
      end

    %{
      preview: preview,
      has_text: has_text?,
      tool_name: nil,
      aborted: aborted?,
      is_error: is_error?
    }
  end

  defp summarize_entry("tool_result", data, tool_calls_index) do
    call_id = fetch_string(data, :tool_call_id)
    matched_call = if is_binary(call_id), do: Map.get(tool_calls_index, call_id), else: nil

    tool_name =
      fetch_string(data, :tool_name) ||
        fetch_string(data, :name) ||
        (matched_call && matched_call.name)

    args = (matched_call && matched_call.arguments) || %{}
    is_error? = fetch(data, :is_error) == true

    preview = format_tool_result_preview(tool_name, args, data)

    %{
      preview: preview,
      has_text: false,
      tool_name: tool_name,
      aborted: false,
      is_error: is_error?
    }
  end

  defp summarize_entry("user_shell", data, _tool_calls_index) do
    include_in_context =
      case fetch(data, :include_in_context) do
        false -> false
        _ -> true
      end

    prefix = if include_in_context, do: "!", else: "!!"
    cmd = fetch_string(data, :command) || ""
    preview = sanitize_preview("#{prefix}#{cmd}")
    aborted? = fetch(data, :cancelled) == true
    is_error? = fetch(data, :is_error) == true

    %{
      preview: preview,
      has_text: cmd != "",
      tool_name: nil,
      aborted: aborted?,
      is_error: is_error?
    }
  end

  defp summarize_entry("compaction", data, _tool_calls_index) do
    summary_text =
      fetch_string(data, :summary) ||
        elem(extract_text_and_attachment(data), 0)

    clean = sanitize_preview(summary_text)
    preview = if clean != "", do: clean, else: "[compaction]"

    %{
      preview: preview,
      has_text: clean != "",
      tool_name: nil,
      aborted: false,
      is_error: false
    }
  end

  defp summarize_entry(kind, data, _tool_calls_index) do
    {text, _} = extract_text_and_attachment(data)
    clean = sanitize_preview(text)
    preview = if clean != "", do: clean, else: "[#{kind}]"

    %{
      preview: preview,
      has_text: clean != "",
      tool_name: nil,
      aborted: false,
      is_error: false
    }
  end

  # Formatting helpers

  defp format_assistant_tool_calls([tc]) do
    name = fetch_string(tc, :name) || "tool"
    args = fetch(tc, :arguments)
    arg_summary = tool_arg_hint(name, if(is_map(args), do: args, else: %{}))

    if is_binary(arg_summary) and arg_summary != "" do
      sanitize_preview("[tool: #{name} #{arg_summary}]")
    else
      sanitize_preview("[tool: #{name}]")
    end
  end

  defp format_assistant_tool_calls(tool_calls) when is_list(tool_calls) do
    names =
      tool_calls
      |> Enum.map(fn tc -> fetch_string(tc, :name) || "tool" end)
      |> Enum.take(6)

    suffix = if length(tool_calls) > 6, do: ", ...", else: ""
    sanitize_preview("[tools: #{Enum.join(names, ", ")}#{suffix}]")
  end

  defp format_tool_result_preview(tool_name, args, data) do
    label = tool_name || "tool"
    hint = tool_arg_hint(label, args) || tool_result_details_hint(label, data)

    if is_binary(hint) and hint != "" do
      sanitize_preview("[#{label}: #{hint}]")
    else
      sanitize_preview("[#{label}]")
    end
  end

  defp tool_arg_hint(name, args) when is_map(args) do
    case name do
      n when n in ["read", "write", "edit"] ->
        fetch_string(args, :path) |> truncate_arg()

      "bash" ->
        fetch_string(args, :command) |> truncate_arg()

      "subagent" ->
        (fetch_string(args, :title) ||
           fetch_string(args, :mode) ||
           fetch_string(args, :session_id) ||
           fetch_string(args, :prompt))
        |> truncate_arg()

      "search_history" ->
        fetch_string(args, :query) |> truncate_arg()

      _ ->
        (fetch_string(args, :path) ||
           fetch_string(args, :command) ||
           fetch_string(args, :query) ||
           fetch_string(args, :title))
        |> truncate_arg()
    end
  end

  defp tool_arg_hint(_name, _args), do: nil

  defp tool_result_details_hint(name, data) when is_map(data) do
    details = fetch(data, :details)

    if is_map(details) do
      case name do
        n when n in ["read", "write", "edit"] ->
          fetch_string(details, :path) |> truncate_arg()

        "subagent" ->
          (fetch_string(details, :title) ||
             fetch_string(details, :mode) ||
             fetch_string(details, :child_session_id))
          |> truncate_arg()

        _ ->
          nil
      end
    else
      nil
    end
  end

  defp tool_result_details_hint(_name, _data), do: nil

  defp truncate_arg(nil), do: nil

  defp truncate_arg(text) when is_binary(text) do
    clean = collapse_and_strip(text)

    if clean == "" do
      nil
    else
      truncate_graphemes(clean, @max_tool_arg_graphemes)
    end
  end

  defp extract_text_and_attachment(data) when is_map(data) do
    case fetch(data, :content) do
      blocks when is_list(blocks) ->
        {texts_rev, has_non_text?} =
          Enum.reduce(blocks, {[], false}, fn block, {texts, non_text} ->
            cond do
              is_binary(block) and block != "" ->
                {[block | texts], non_text}

              is_map(block) ->
                type = fetch_string(block, :type)

                case type do
                  "text" ->
                    case fetch_string(block, :text) do
                      t when is_binary(t) and t != "" -> {[t | texts], non_text}
                      _ -> {texts, non_text}
                    end

                  "thinking" ->
                    {texts, non_text}

                  "tool_use" ->
                    {texts, non_text}

                  "toolCall" ->
                    {texts, non_text}

                  nil ->
                    case fetch_string(block, :text) do
                      t when is_binary(t) and t != "" -> {[t | texts], non_text}
                      _ -> {texts, non_text}
                    end

                  _other ->
                    {texts, true}
                end

              true ->
                {texts, non_text}
            end
          end)

        text = texts_rev |> Enum.reverse() |> Enum.join(" ")
        {text, has_non_text?}

      text when is_binary(text) ->
        {text, false}

      _ ->
        case fetch_string(data, :text) do
          text when is_binary(text) -> {text, false}
          _ -> {"", false}
        end
    end
  end

  defp extract_text_and_attachment(_), do: {"", false}

  defp extract_error_message(data) when is_map(data) do
    cond do
      is_binary(fetch(data, :error_message)) and fetch(data, :error_message) != "" ->
        fetch(data, :error_message)

      is_binary(fetch(data, :errorMessage)) and fetch(data, :errorMessage) != "" ->
        fetch(data, :errorMessage)

      is_binary(fetch(data, :error)) and fetch(data, :error) != "" ->
        fetch(data, :error)

      is_map(fetch(data, :error)) ->
        err = fetch(data, :error)
        fetch_string(err, :message) || fetch_string(err, :code) || "(error)"

      true ->
        nil
    end
  end

  defp extract_error_message(_), do: nil

  defp sanitize_preview(nil), do: ""

  defp sanitize_preview(text) when is_binary(text) do
    text
    |> strip_inline_data_uris()
    |> collapse_and_strip()
    |> truncate_graphemes(@max_preview_graphemes)
  end

  defp sanitize_preview(_), do: ""

  defp strip_inline_data_uris(text) do
    # Avoid leaking huge inline base64 data URIs if embedded in text
    String.replace(text, ~r/data:[^;\s]+;base64,[A-Za-z0-9+\/=]{32,}/, "[attachment]")
  end

  defp collapse_and_strip(text) do
    text
    |> String.replace(~r/[\r\n\t]+/, " ")
    |> String.replace(~r/[\x00-\x1F\x7F]/u, "")
    |> String.replace(~r/\s{2,}/u, " ")
    |> String.trim()
  end

  defp truncate_graphemes(text, max_len) do
    if String.length(text) > max_len do
      String.slice(text, 0, max_len - 1) <> "…"
    else
      text
    end
  end

  # Entry field extraction (handles both atom-keyed native entries and string-keyed archive entries)

  defp entry_id_int(entry) do
    case fetch(entry, :id) do
      id when is_integer(id) -> id
      id when is_binary(id) -> String.to_integer(id)
    end
  end

  defp entry_cid_str(entry) do
    case fetch(entry, :conversation_id) do
      cid when is_integer(cid) -> Integer.to_string(cid)
      cid when is_binary(cid) -> cid
      _ -> "1"
    end
  end

  defp entry_kind(entry), do: fetch_string(entry, :kind)

  defp entry_data(entry) do
    case fetch(entry, :data) do
      d when is_map(d) -> d
      _ -> %{}
    end
  end

  defp normalize_created_at(ts) when is_integer(ts), do: ts
  defp normalize_created_at(_), do: nil

  defp fetch(map, key) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, val} -> val
      :error -> Map.get(map, Atom.to_string(key))
    end
  end

  defp fetch(_map, _key), do: nil

  defp fetch_string(map, key) do
    case fetch(map, key) do
      val when is_binary(val) -> val
      _ -> nil
    end
  end
end
