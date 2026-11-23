defmodule H.Session.Compaction do
  @moduledoc """
  Manual `/compact` policy, safe provider-visible prefix projection, boundary
  selection, and single-call summarization for `H` sessions.

  Compaction is append-only: previous entries are never mutated or deleted.
  `prepare/2` selects a real committed `kept_from_id` boundary preserving
  user/tool pairing and excluding `!!`/hidden entries, then reuses `H.Context`
  to project the already provider-visible prefix (including any prior compaction
  summary). `summarize/5` runs one `H.Provider` call and validates the output
  before returning `"compaction"` entry data for `H.Context`.
  """

  alias H.{Context, Schema}

  @default_keep_recent_chars 20_000
  @default_max_summary_tokens 16_384
  @tool_result_max_chars 2_000

  @summarization_system_prompt """
  You are a context summarization assistant. Read the conversation history and produce a concise structured checkpoint summary so another assistant can continue the work.

  Do NOT continue the conversation, answer open questions in the transcript, or call tools. Output ONLY the summary. Aim for at most 2,000 words; prioritize facts needed to continue.\
  """

  @summarization_prompt """
  Summarize the conversation above into a concise checkpoint using these sections:

  ## Goal
  ## Constraints & Preferences
  ## Progress (Done / In Progress / Blocked)
  ## Key Decisions
  ## Next Steps
  ## Critical Context

  Preserve exact file paths, function names, and error messages.\
  """

  @update_summarization_prompt """
  Incorporate the new conversation messages above into the existing summary in <previous-summary> tags.
  Preserve still-relevant facts, update completed/in-progress work, decisions, and next steps, and keep exact file paths, function names, and error messages.\
  """

  @type preparation :: %{
          kept_from_id: pos_integer(),
          previous_summary: String.t() | nil,
          projected_messages: [map()],
          kept_entries: [map()],
          max_tokens: pos_integer()
        }

  @type compaction_result :: %{
          summary: String.t(),
          kept_from_id: pos_integer(),
          instructions: String.t() | nil,
          usage: map()
        }

  @doc "Validates the daemon's scoped token budgets before accepting work."
  def validate_limits!(limits) when is_map(limits) do
    Enum.each(limits, fn {scope, limit} ->
      valid_scope =
        case scope do
          :default -> true
          {key, value} when key in [:cwd, :model, :provider] -> is_binary(value) and value != ""
          {:cwd, cwd, model} -> is_binary(cwd) and cwd != "" and is_binary(model) and model != ""
          _ -> false
        end

      unless valid_scope and (limit == :off or (is_integer(limit) and limit > 0)),
        do: raise(ArgumentError, "invalid auto_compaction scope or threshold: #{inspect(scope)}")
    end)

    limits
  end

  def validate_limits!(_),
    do: raise(ArgumentError, "auto_compaction must be a map of scoped thresholds")

  @doc "Returns a safe cut when the projected request exceeds its scoped token budget."
  def auto_boundary(entries, request, cwd, limits, keep_chars, adapter, config \\ %{})

  def auto_boundary(entries, %{model: model} = request, cwd, limits, keep_chars, adapter, config)
      when is_binary(model) do
    [provider | _] = String.split(model, ":", parts: 2)

    limit =
      Enum.find_value(
        [{:cwd, cwd, model}, {:cwd, cwd}, {:model, model}, {:provider, provider}, :default],
        &Map.get(limits, &1)
      ) || model_threshold(adapter, model, config)

    # Estimate a single provider-visible request, not cumulative usage or raw history.
    if is_integer(limit) and limit > 0 and
         IO.iodata_length(JSON.encode_to_iodata!(Map.take(request, [:messages, :tools]))) >
           4 * limit do
      case prepare(entries, keep_recent_chars: min(keep_chars, 2 * limit)) do
        {:ok, prep} -> prep.kept_from_id
        {:error, _no_cut} -> nil
      end
    end
  end

  def auto_boundary(_, _, _, _, _, _, _), do: nil

  defp model_threshold(H.Provider.ReqLLM, model, config) do
    case H.Provider.ReqLLM.context_window(model, config) do
      window when is_integer(window) and window > 0 ->
        window - min(16_384, div(window, 2))

      _ ->
        96_000
    end
  end

  defp model_threshold(_, _, _), do: 96_000

  @doc "Validates external `compact` command arguments."
  @spec validate_args(term()) :: {:ok, map()} | {:error, String.t()}
  def validate_args(raw_args) do
    with {:ok, args} <-
           Schema.validate_map(raw_args, [
             {:expected_seq, {:int, min: 0}, required: true},
             {:instructions, :string, required: false, nullable: true}
           ]) do
      instructions = non_empty_string(Map.get(args, :instructions))
      {:ok, %{expected_seq: args.expected_seq, instructions: instructions}}
    end
  end

  @doc """
  Prepares a manual compaction plan from ordered transcript `entries` without
  mutating any entry.

  Options:
    * `:keep_recent_chars` - character budget kept verbatim at the tail (default #{@default_keep_recent_chars})
    * `:kept_from_id` - explicit entry ID boundary (must be a visible `"user"` or `"assistant"` entry)
    * `:max_tokens` - output token cap for the summarization call (default #{@default_max_summary_tokens})
  """
  @spec prepare([map()], keyword()) ::
          {:ok, preparation()}
          | {:error, :already_compacted | :nothing_to_compact | :invalid_boundary}
  def prepare(entries, opts \\ []) when is_list(entries) and is_list(opts) do
    case List.last(entries) do
      nil ->
        {:error, :nothing_to_compact}

      last ->
        if entry_kind(last) in ["compaction", "reset"] do
          {:error, :already_compacted}
        else
          do_prepare(entries, opts)
        end
    end
  end

  @doc """
  Serializes projected provider-visible messages into plain text for summarization.
  Omits thinking blocks, provider metadata, and raw image binaries, and
  truncates long tool results at #{@tool_result_max_chars} characters.
  """
  @spec serialize_messages([map()]) :: String.t()
  def serialize_messages(messages) when is_list(messages) do
    messages
    |> Enum.flat_map(&serialize_message/1)
    |> Enum.join("\n\n")
  end

  @doc """
  Builds the single provider-neutral request map for summarizing `preparation`.
  """
  @spec build_request(preparation(), map(), keyword()) :: map()
  def build_request(preparation, agent, opts \\ [])
      when is_map(preparation) and is_map(agent) and is_list(opts) do
    previous_summary = non_empty_string(preparation.previous_summary)
    instructions = normalize_instructions(opts)

    conversation_messages =
      if is_binary(previous_summary) and preparation.projected_messages != [] do
        tl(preparation.projected_messages)
      else
        preparation.projected_messages
      end

    conversation_text = serialize_messages(conversation_messages)

    base_prompt =
      if previous_summary, do: @update_summarization_prompt, else: @summarization_prompt

    prompt =
      if instructions do
        "#{base_prompt}\n\nUser instructions: #{instructions}"
      else
        base_prompt
      end

    prompt_text =
      ["<conversation>\n#{conversation_text}\n</conversation>"]
      |> then(fn parts ->
        if previous_summary do
          parts ++ ["<previous-summary>\n#{previous_summary}\n</previous-summary>"]
        else
          parts
        end
      end)
      |> Kernel.++([prompt])
      |> Enum.join("\n\n")

    %{
      model: Keyword.get(opts, :model) || fetch(agent, :model),
      thinking: summarization_thinking(agent),
      max_tokens: Keyword.get(opts, :max_tokens, preparation.max_tokens),
      messages: [
        %{role: "system", content: [%{type: "text", text: @summarization_system_prompt}]},
        %{role: "user", content: [%{type: "text", text: prompt_text}]}
      ],
      tools: []
    }
  end

  @doc """
  Runs the single `provider_mod.stream_turn/3` summarization call for `preparation`
  and rejects incomplete, truncated, tool-calling, or empty responses.
  """
  @spec summarize(preparation(), map(), module(), map(), keyword()) ::
          {:ok, compaction_result()} | {:error, map()}
  def summarize(preparation, agent, provider_mod, provider_config \\ %{}, opts \\ [])
      when is_map(preparation) and is_map(agent) and is_atom(provider_mod) and
             is_map(provider_config) and is_list(opts) do
    model = Keyword.get(opts, :model) || fetch(agent, :model)

    if not (is_binary(model) and model != "") do
      {:error,
       %{code: "missing_model", message: "No model configured for compaction", retryable: false}}
    else
      emit = Keyword.get(opts, :emit, fn _ev -> :ok end)
      request = build_request(preparation, agent, Keyword.put(opts, :model, model))

      case provider_mod.stream_turn(provider_config, request, emit) do
        {:ok, resp} ->
          with {:ok, summary, usage} <- validate_response(resp) do
            {:ok,
             %{
               summary: summary,
               kept_from_id: preparation.kept_from_id,
               instructions: normalize_instructions(opts),
               usage: usage
             }}
          end

        {:cancelled, _partial} ->
          {:error, %{code: "cancelled", message: "Summarization was cancelled", retryable: false}}

        {:error, reason} when is_map(reason) ->
          {:error, reason}

        {:error, reason} ->
          {:error, %{code: "provider_error", message: inspect(reason), retryable: false}}
      end
    end
  end

  @doc """
  Prepares and executes manual compaction in one call.
  """
  @spec compact([map()], map(), module(), map(), keyword()) ::
          {:ok, compaction_result()}
          | {:error, :already_compacted | :nothing_to_compact | :invalid_boundary | map()}
  def compact(entries, agent, provider_mod, provider_config \\ %{}, opts \\ [])
      when is_list(entries) and is_map(agent) and is_atom(provider_mod) and
             is_map(provider_config) and is_list(opts) do
    with {:ok, preparation} <- prepare(entries, opts) do
      summarize(preparation, agent, provider_mod, provider_config, opts)
    end
  end

  @doc """
  Formats a `compaction_result` into plain JSON-compatible `"compaction"` entry
  `data` consumed by `H.Context`.
  """
  @spec entry_data(compaction_result()) :: map()
  def entry_data(result) when is_map(result) do
    %{
      "summary" => result.summary,
      "kept_from_id" => result.kept_from_id
    }
    |> then(fn map ->
      case result[:instructions] do
        text when is_binary(text) and text != "" -> Map.put(map, "instructions", text)
        _ -> map
      end
    end)
    |> then(fn map ->
      usage = stringify_json(result[:usage] || %{})
      if map_size(usage) > 0, do: Map.put(map, "usage", usage), else: map
    end)
  end

  @doc """
  Returns `true` when `entry` is part of the provider-visible conversation
  (never aborted assistant turns, system entries, or `!!`/excluded entries).
  """
  @spec provider_visible_entry?(map()) :: boolean()
  def provider_visible_entry?(entry) when is_map(entry) do
    data = entry_data_map(entry)

    not excluded_entry?(data) and
      case entry_kind(entry) do
        "user" -> true
        "user_shell" -> fetch(data, :include_in_context) == true
        "assistant" -> not Context.aborted_assistant?(entry)
        "tool_result" -> true
        _ -> false
      end
  end

  def provider_visible_entry?(_), do: false

  # Preparation & boundary selection

  defp do_prepare(entries, opts) do
    {previous_summary, active_entries} = active_visible_window(entries)

    case select_cut_index(active_entries, opts) do
      {:error, reason} ->
        {:error, reason}

      {:ok, 0} ->
        {:error, :nothing_to_compact}

      {:ok, cut_index} ->
        kept_entries = Enum.drop(active_entries, cut_index)
        kept_from_id = entry_id(hd(kept_entries))

        prefix_entries =
          Enum.filter(entries, fn entry ->
            kind = entry_kind(entry)
            id = entry_id(entry)

            cond do
              kind in ["compaction", "reset"] -> true
              is_integer(id) and id < kept_from_id -> provider_visible_entry?(entry)
              true -> false
            end
          end)

        %{messages: projected_messages} = Context.build_request(prefix_entries, %{}, [])

        {:ok,
         %{
           kept_from_id: kept_from_id,
           previous_summary: previous_summary,
           projected_messages: projected_messages,
           kept_entries: kept_entries,
           max_tokens: positive_opt(opts, :max_tokens, @default_max_summary_tokens)
         }}
    end
  end

  defp active_visible_window(entries) do
    case find_last_head_marker(entries) do
      nil ->
        {nil, Enum.filter(entries, &provider_visible_entry?/1)}

      {marker, marker_idx} ->
        data = entry_data_map(marker)

        {summary, raw_active} =
          case entry_kind(marker) do
            "compaction" ->
              kept_from_id = fetch(data, :kept_from_id)

              active =
                entries
                |> Enum.with_index()
                |> Enum.filter(fn {entry, idx} ->
                  entry_kind(entry) not in ["compaction", "reset"] and
                    (idx > marker_idx or
                       (is_integer(kept_from_id) and entry_id(entry) >= kept_from_id))
                end)
                |> Enum.map(&elem(&1, 0))

              {extract_summary_text(fetch_any(data, [:summary, :text])), active}

            "reset" ->
              active =
                entries
                |> Enum.drop(marker_idx + 1)
                |> Enum.reject(&(entry_kind(&1) in ["compaction", "reset"]))

              {extract_summary_text(fetch_any(data, [:handoff, :note, :text, :summary])), active}
          end

        {summary, Enum.filter(raw_active, &provider_visible_entry?/1)}
    end
  end

  defp select_cut_index(active_entries, opts) do
    case Keyword.fetch(opts, :kept_from_id) do
      {:ok, kept_from_id} when is_integer(kept_from_id) and kept_from_id > 0 ->
        case Enum.find_index(active_entries, &(entry_id(&1) == kept_from_id)) do
          nil ->
            {:error, :invalid_boundary}

          idx ->
            if entry_kind(Enum.at(active_entries, idx)) in ["user", "user_shell", "assistant"] do
              {:ok, idx}
            else
              {:error, :invalid_boundary}
            end
        end

      {:ok, _invalid} ->
        {:error, :invalid_boundary}

      :error ->
        cut_points =
          active_entries
          |> Enum.with_index()
          |> Enum.flat_map(fn {entry, idx} ->
            if entry_kind(entry) in ["user", "user_shell", "assistant"] and
                 is_integer(entry_id(entry)),
               do: [idx],
               else: []
          end)

        case cut_points do
          [] ->
            {:error, :nothing_to_compact}

          [first_cut | _] ->
            budget = non_neg_opt(opts, :keep_recent_chars, @default_keep_recent_chars)
            {:ok, walk_backwards(active_entries, cut_points, first_cut, budget)}
        end
    end
  end

  defp walk_backwards(active_entries, cut_points, default_cut, budget) do
    active_entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.reduce_while(0, fn {entry, idx}, acc ->
      next = acc + entry_chars(entry)

      if next >= budget do
        chosen = Enum.find(cut_points, &(&1 >= idx)) || List.last(cut_points)
        {:halt, {:found, chosen}}
      else
        {:cont, next}
      end
    end)
    |> case do
      {:found, idx} -> idx
      _total -> default_cut
    end
  end

  # Response validation

  defp validate_response(resp) when is_map(resp) do
    finish_reason = to_string(fetch_any(resp, [:finish_reason, :stop_reason]) || "stop")
    tool_calls = fetch(resp, :tool_calls, []) |> List.wrap()
    content = fetch(resp, :content, []) |> List.wrap()

    has_tool_block? =
      Enum.any?(content, fn
        block when is_map(block) ->
          fetch(block, :type) in ["tool_call", :tool_call, "toolCall", :toolCall]

        _ ->
          false
      end)

    cond do
      finish_reason == "error" ->
        {:error,
         %{code: "summarization_error", message: "Summarization failed", retryable: false}}

      finish_reason in ["length", "max_tokens"] ->
        {:error,
         %{
           code: "truncated_summary",
           message: "Summarization hit the token cap and is incomplete",
           retryable: false
         }}

      tool_calls != [] or has_tool_block? ->
        {:error,
         %{
           code: "tool_call_rejected",
           message: "Summarization attempted to call a tool",
           retryable: false
         }}

      true ->
        text = extract_visible_text(content)

        if String.trim(text) == "" do
          {:error,
           %{
             code: "empty_summary",
             message: "Summarization returned an empty summary",
             retryable: false
           }}
        else
          {:ok, text, fetch(resp, :usage, %{}) || %{}}
        end
    end
  end

  # Serialization of H.Context projected messages

  defp serialize_message(%{role: "user", content: blocks}) do
    text = extract_visible_text(blocks)
    if text == "", do: [], else: ["[User]: #{text}"]
  end

  defp serialize_message(%{role: "assistant"} = msg) do
    text = extract_visible_text(Map.get(msg, :content, []))

    tool_calls =
      msg
      |> Map.get(:tool_calls, [])
      |> List.wrap()
      |> Enum.map(&format_tool_call/1)

    []
    |> then(fn acc -> if text == "", do: acc, else: acc ++ ["[Assistant]: #{text}"] end)
    |> then(fn acc ->
      if tool_calls == [] do
        acc
      else
        acc ++ ["[Assistant tool calls]: #{Enum.join(tool_calls, "; ")}"]
      end
    end)
  end

  defp serialize_message(%{role: "tool", content: blocks}) do
    text = extract_visible_text(blocks)
    if text == "", do: [], else: ["[Tool result]: #{truncate_tool_result(text)}"]
  end

  defp serialize_message(_), do: []

  defp format_tool_call(tc) when is_map(tc) do
    name = fetch(tc, :name, "") |> to_string()
    args = fetch(tc, :arguments, %{})

    args_str =
      if is_map(args) do
        args
        |> Enum.map(fn {k, v} -> {to_string(k), v} end)
        |> Enum.sort_by(&elem(&1, 0))
        |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{JSON.encode!(v)}" end)
      else
        ""
      end

    "#{name}(#{args_str})"
  end

  defp truncate_tool_result(text) do
    len = String.length(text)

    if len <= @tool_result_max_chars do
      text
    else
      "#{String.slice(text, 0, @tool_result_max_chars)}\n\n[... #{len - @tool_result_max_chars} more characters truncated]"
    end
  end

  # Helpers

  defp find_last_head_marker(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find(fn {entry, _idx} -> entry_kind(entry) in ["compaction", "reset"] end)
  end

  defp excluded_entry?(data) when is_map(data) do
    fetch(data, :exclude_from_context) == true or
      fetch(data, :excluded_from_context) == true or
      fetch(data, :include_in_context) == false or
      fetch(data, :mode) == "!!" or
      fetch(data, :prefix) == "!!"
  end

  defp entry_chars(entry) do
    data = entry_data_map(entry)

    content_chars =
      if entry_kind(entry) == "user_shell" do
        cmd = fetch(data, :command) || ""
        out = fetch(data, :output) || ""
        byte_size_or_len(cmd) + byte_size_or_len(out)
      else
        case fetch(data, :content) do
          blocks when is_list(blocks) ->
            Enum.reduce(blocks, 0, fn
              t, acc when is_binary(t) -> acc + String.length(t)
              %{type: "text", text: t}, acc when is_binary(t) -> acc + String.length(t)
              %{"type" => "text", "text" => t}, acc when is_binary(t) -> acc + String.length(t)
              _, acc -> acc
            end)

          t when is_binary(t) ->
            String.length(t)

          _ ->
            case fetch_any(data, [:text, :output]) do
              t when is_binary(t) -> String.length(t)
              _ -> 0
            end
        end
      end

    max(1, content_chars)
  end

  defp byte_size_or_len(val) when is_binary(val), do: String.length(val)
  defp byte_size_or_len(_), do: 0

  defp extract_visible_text(blocks) when is_list(blocks) do
    blocks
    |> Enum.flat_map(fn
      t when is_binary(t) ->
        if t == "", do: [], else: [t]

      block when is_map(block) ->
        if fetch(block, :type) in ["text", :text] do
          case fetch(block, :text) do
            t when is_binary(t) and t != "" -> [t]
            _ -> []
          end
        else
          []
        end

      _ ->
        []
    end)
    |> Enum.join("")
  end

  defp extract_visible_text(_), do: ""

  defp summarization_thinking(agent) do
    case fetch(agent, :thinking) do
      val when val in [nil, "", "off", :off, "none", :none] -> nil
      _ -> "low"
    end
  end

  defp extract_summary_text(val) when is_binary(val), do: non_empty_string(val)

  defp extract_summary_text(val) when is_list(val),
    do: val |> extract_visible_text() |> non_empty_string()

  defp extract_summary_text(_), do: nil

  defp normalize_instructions(opts) do
    opts
    |> Keyword.get(:instructions, Keyword.get(opts, :custom_instructions))
    |> non_empty_string()
  end

  defp non_empty_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp positive_opt(opts, key, default) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n > 0 -> n
      _ -> default
    end
  end

  defp non_neg_opt(opts, key, default) do
    case Keyword.get(opts, key) do
      n when is_integer(n) and n >= 0 -> n
      _ -> default
    end
  end

  defp entry_id(%{id: id}), do: id
  defp entry_id(%{"id" => id}), do: id
  defp entry_id(_), do: nil

  defp entry_kind(%{kind: kind}), do: kind
  defp entry_kind(%{"kind" => kind}), do: kind
  defp entry_kind(_), do: nil

  defp entry_data_map(%{data: data}) when is_map(data), do: data
  defp entry_data_map(%{"data" => data}) when is_map(data), do: data
  defp entry_data_map(_), do: %{}

  defp fetch(map, key, default \\ nil)

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp fetch(_other, _key, default), do: default

  defp fetch_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> fetch(map, key) end)
  end

  defp stringify_json(val) when is_struct(val), do: val |> Map.from_struct() |> stringify_json()

  defp stringify_json(val) when is_map(val) do
    Map.new(val, fn {k, v} -> {to_string(k), stringify_json(v)} end)
  end

  defp stringify_json(val) when is_list(val), do: Enum.map(val, &stringify_json/1)

  defp stringify_json(val) when is_atom(val) and val not in [nil, true, false],
    do: Atom.to_string(val)

  defp stringify_json(val), do: val
end
