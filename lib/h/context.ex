defmodule H.Context do
  @moduledoc """
  Pure context reducer projecting visible transcript entries, agent settings,
  and tool descriptors into a provider-neutral request map and `ReqLLM` structs.
  """

  alias ReqLLM.Message
  alias ReqLLM.Message.{ContentPart, ReasoningDetails}
  alias ReqLLM.ToolCall

  @interrupted_tool_text "Tool call interrupted by conversation fork."

  @type tool_descriptor :: %{
          required(:name) => String.t(),
          optional(:description) => String.t(),
          optional(:parameters_schema) => map() | keyword()
        }

  @type request_map :: %{
          model: term(),
          thinking: term(),
          max_tokens: pos_integer() | nil,
          messages: [map()],
          tools: [map()]
        }

  @doc """
  Builds a provider-neutral request map from visible entries, `agent` config,
  and offered `tool_specs`.
  """
  @spec build_request([map()], map(), [map()]) :: request_map()
  def build_request(entries, agent, tool_specs \\ [])
      when is_list(entries) and is_map(agent) and is_list(tool_specs) do
    {seed_messages, active_entries} = apply_head_cut(entries)

    transcript_messages =
      active_entries
      |> Enum.reject(&aborted_assistant?/1)
      |> project_entries()
      |> inject_missing_tool_results()

    messages =
      leading_system_messages(agent) ++
        seed_messages ++
        transcript_messages

    %{
      model: fetch(agent, :model),
      thinking: fetch(agent, :thinking),
      max_tokens: fetch(agent, :max_tokens),
      messages: messages,
      tools: select_tools(agent, tool_specs)
    }
  end

  @doc """
  Converts a provider-neutral `request_map` into `{%ReqLLM.Context{}, [%ReqLLM.Tool{}]}`.
  """
  @spec to_req_llm(map()) :: {ReqLLM.Context.t(), [ReqLLM.Tool.t()]}
  def to_req_llm(request_map) when is_map(request_map) do
    req_tools =
      request_map
      |> fetch(:tools, [])
      |> Enum.map(&to_req_llm_tool/1)

    req_messages =
      request_map
      |> fetch(:messages, [])
      |> Enum.map(&to_req_llm_message/1)

    req_context = %ReqLLM.Context{
      messages: req_messages,
      tools: req_tools
    }

    {req_context, req_tools}
  end

  # Head cut: compaction / reset

  defp apply_head_cut(entries) do
    case find_last_head_marker(entries) do
      nil ->
        {[], entries}

      {marker, marker_idx} ->
        kind = entry_kind(marker)
        data = entry_data(marker)

        case kind do
          "compaction" ->
            seed = seed_message(fetch_any(data, [:summary, :text]))
            kept_from_id = fetch(data, :kept_from_id)

            kept =
              entries
              |> Enum.with_index()
              |> Enum.filter(fn {entry, idx} ->
                entry_kind(entry) not in ["compaction", "reset"] and
                  (idx > marker_idx or
                     (is_integer(kept_from_id) and entry_id(entry) >= kept_from_id))
              end)
              |> Enum.map(&elem(&1, 0))

            {seed, kept}

          "reset" ->
            seed = seed_message(fetch_any(data, [:handoff, :note, :text, :summary]))
            rest = Enum.drop(entries, marker_idx + 1)
            {seed, rest}
        end
    end
  end

  defp find_last_head_marker(entries) do
    entries
    |> Enum.with_index()
    |> Enum.reverse()
    |> Enum.find(fn {entry, _idx} -> entry_kind(entry) in ["compaction", "reset"] end)
  end

  defp seed_message(nil), do: []
  defp seed_message(""), do: []

  defp seed_message(text) when is_binary(text) do
    [%{role: "user", content: [%{type: "text", text: text}]}]
  end

  defp seed_message(blocks) when is_list(blocks) do
    case normalize_blocks(blocks) do
      [] -> []
      normalized -> [%{role: "user", content: normalized}]
    end
  end

  defp seed_message(_other), do: []

  # Leading system baseline

  defp leading_system_messages(agent) do
    system_prompt = fetch(agent, :system_prompt)
    instructions = fetch(agent, :instructions)

    parts =
      [system_prompt, instructions]
      |> Enum.filter(&(is_binary(&1) and &1 != ""))

    case parts do
      [] -> []
      _ -> [%{role: "system", content: [%{type: "text", text: Enum.join(parts, "\n\n")}]}]
    end
  end

  # Entry projection

  defp aborted_assistant?(entry) do
    entry_kind(entry) == "assistant" and fetch(entry_data(entry), :aborted) == true
  end

  defp project_entries(entries) do
    Enum.flat_map(entries, &project_entry/1)
  end

  defp project_entry(entry) do
    kind = entry_kind(entry)
    data = entry_data(entry)

    case kind do
      "user" ->
        [%{role: "user", content: extract_content_blocks(data)} |> maybe_put_meta(data)]

      "system" ->
        [%{role: "system", content: extract_content_blocks(data)} |> maybe_put_meta(data)]

      "assistant" ->
        tool_calls = normalize_tool_calls(fetch(data, :tool_calls, []))

        msg =
          %{
            role: "assistant",
            content: extract_content_blocks(data),
            tool_calls: tool_calls
          }
          |> maybe_put_field(:provider_meta, fetch(data, :provider_meta))
          |> maybe_put_field(:reasoning_details, fetch(data, :reasoning_details))
          |> maybe_put_meta(data)

        [msg]

      "tool_result" ->
        call_id = fetch(data, :tool_call_id)
        name = fetch(data, :name)
        is_error = fetch(data, :is_error, false) == true

        msg =
          %{
            role: "tool",
            tool_call_id: call_id,
            name: name,
            is_error: is_error,
            content: extract_tool_result_blocks(data)
          }
          |> maybe_put_meta(data)

        [msg]

      _other ->
        []
    end
  end

  defp extract_content_blocks(data) do
    case fetch(data, :content) do
      blocks when is_list(blocks) ->
        normalize_blocks(blocks)

      text when is_binary(text) and text != "" ->
        [%{type: "text", text: text}]

      _ ->
        case fetch(data, :text) do
          text when is_binary(text) and text != "" -> [%{type: "text", text: text}]
          _ -> []
        end
    end
  end

  defp extract_tool_result_blocks(data) do
    case fetch(data, :content) do
      blocks when is_list(blocks) ->
        normalize_blocks(blocks)

      text when is_binary(text) ->
        [%{type: "text", text: text}]

      _ ->
        case fetch_any(data, [:text, :output]) do
          text when is_binary(text) -> [%{type: "text", text: text}]
          other when not is_nil(other) -> [%{type: "text", text: JSON.encode!(other)}]
          nil -> []
        end
    end
  end

  defp normalize_blocks(blocks) do
    Enum.flat_map(blocks, fn
      block when is_binary(block) ->
        if block == "", do: [], else: [%{type: "text", text: block}]

      block when is_map(block) ->
        case normalize_block(block) do
          nil -> []
          normalized -> [normalized]
        end

      _ ->
        []
    end)
  end

  defp normalize_block(block) do
    type =
      case fetch(block, :type) do
        t when is_atom(t) -> Atom.to_string(t)
        t when is_binary(t) -> t
        _ -> nil
      end

    case type do
      "text" ->
        text = fetch(block, :text, "")

        %{type: "text", text: text}
        |> maybe_put_field(:metadata, fetch(block, :metadata))
        |> maybe_put_field(:provider_meta, fetch(block, :provider_meta))

      "thinking" ->
        text = fetch_any(block, [:text, :thinking]) || ""

        %{type: "thinking", text: text}
        |> maybe_put_field(:signature, fetch(block, :signature))
        |> maybe_put_field(:encrypted?, fetch(block, :encrypted?))
        |> maybe_put_field(:provider, fetch(block, :provider))
        |> maybe_put_field(:format, fetch(block, :format))
        |> maybe_put_field(:index, fetch(block, :index))
        |> maybe_put_field(:provider_meta, fetch(block, :provider_meta))
        |> maybe_put_field(:metadata, fetch(block, :metadata))

      "image" ->
        %{type: "image"}
        |> maybe_put_field(:data, fetch(block, :data))
        |> maybe_put_field(:url, fetch(block, :url))
        |> maybe_put_field(:media_type, fetch(block, :media_type))
        |> maybe_put_field(:metadata, fetch(block, :metadata))

      "image_url" ->
        %{type: "image_url", url: fetch(block, :url)}
        |> maybe_put_field(:media_type, fetch(block, :media_type))
        |> maybe_put_field(:metadata, fetch(block, :metadata))

      "provider_block" ->
        %{type: "provider_block", data: fetch(block, :data)}
        |> maybe_put_field(:provider, fetch(block, :provider))
        |> maybe_put_field(:metadata, fetch(block, :metadata))

      nil ->
        nil

      other ->
        Map.put(block, :type, other)
    end
  end

  defp normalize_tool_calls(nil), do: []

  defp normalize_tool_calls(tool_calls) when is_list(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      arguments =
        case fetch(tc, :arguments, %{}) do
          json when is_binary(json) ->
            case JSON.decode(json) do
              {:ok, decoded} when is_map(decoded) -> decoded
              _ -> %{}
            end

          args when is_map(args) ->
            args

          _ ->
            %{}
        end

      %{
        id: fetch(tc, :id),
        name: fetch(tc, :name),
        arguments: arguments
      }
      |> maybe_put_field(:metadata, fetch(tc, :metadata))
    end)
  end

  # Fork tool-call pairing

  defp inject_missing_tool_results(messages) do
    do_inject_tool_results(messages, [])
  end

  defp do_inject_tool_results([], acc), do: Enum.reverse(acc)

  defp do_inject_tool_results([%{role: "assistant", tool_calls: tool_calls} = msg | rest], acc)
       when is_list(tool_calls) and tool_calls != [] do
    {tool_window, remaining} = split_until_next_turn(rest)

    present_ids =
      tool_window
      |> Enum.filter(&(&1.role == "tool"))
      |> MapSet.new(& &1.tool_call_id)

    synthetic =
      tool_calls
      |> Enum.reject(fn tc -> MapSet.member?(present_ids, tc.id) end)
      |> Enum.map(fn tc ->
        %{
          role: "tool",
          tool_call_id: tc.id,
          name: tc.name,
          is_error: true,
          content: [%{type: "text", text: @interrupted_tool_text}]
        }
      end)

    # Keep real tool results and inject missing synthetic ones right after the assistant turn
    acc =
      [msg | tool_window ++ synthetic]
      |> Enum.reduce(acc, fn item, inner_acc -> [item | inner_acc] end)

    do_inject_tool_results(remaining, acc)
  end

  defp do_inject_tool_results([msg | rest], acc) do
    do_inject_tool_results(rest, [msg | acc])
  end

  defp split_until_next_turn(messages) do
    Enum.split_while(messages, fn
      %{role: "tool"} -> true
      _ -> false
    end)
  end

  # Tool selection & normalization

  defp select_tools(agent, tool_specs) do
    selected = fetch(agent, :tools)

    raw_tools =
      cond do
        tool_specs != [] and is_list(selected) and selected != [] and
            Enum.all?(selected, &is_binary/1) ->
          allowed = MapSet.new(selected)
          Enum.filter(tool_specs, fn spec -> MapSet.member?(allowed, fetch(spec, :name)) end)

        tool_specs != [] ->
          tool_specs

        is_list(selected) and Enum.all?(selected, &is_map/1) ->
          selected

        true ->
          []
      end

    Enum.map(raw_tools, fn spec ->
      schema =
        fetch_any(spec, [:parameters_schema, :parameter_schema]) ||
          %{"type" => "object", "properties" => %{}}

      %{
        name: fetch(spec, :name),
        description: fetch(spec, :description, ""),
        parameters_schema: schema
      }
    end)
  end

  # ReqLLM conversion

  defp to_req_llm_tool(tool) do
    schema = fetch_any(tool, [:parameters_schema, :parameter_schema]) || []

    ReqLLM.Tool.new!(
      name: fetch(tool, :name),
      description: fetch(tool, :description, ""),
      parameter_schema: schema,
      callback: fn _ -> {:error, :managed_by_harness} end
    )
  end

  defp to_req_llm_message(%{role: "system"} = msg) do
    %Message{
      role: :system,
      content: to_req_llm_parts(fetch(msg, :content, [])),
      metadata: fetch(msg, :metadata, %{})
    }
  end

  defp to_req_llm_message(%{role: "user"} = msg) do
    %Message{
      role: :user,
      content: to_req_llm_parts(fetch(msg, :content, [])),
      metadata: fetch(msg, :metadata, %{})
    }
  end

  defp to_req_llm_message(%{role: "assistant"} = msg) do
    blocks = fetch(msg, :content, [])
    tool_calls = to_req_llm_tool_calls(fetch(msg, :tool_calls, []))
    reasoning_details = build_reasoning_details(msg, blocks)

    %Message{
      role: :assistant,
      content: to_req_llm_parts(blocks),
      tool_calls: if(tool_calls == [], do: nil, else: tool_calls),
      metadata: fetch(msg, :metadata, %{}),
      reasoning_details: reasoning_details
    }
  end

  defp to_req_llm_message(%{role: "tool"} = msg) do
    metadata = fetch(msg, :metadata, %{})

    metadata =
      if fetch(msg, :is_error, false) == true do
        Map.put(metadata, :is_error, true)
      else
        metadata
      end

    %Message{
      role: :tool,
      name: fetch(msg, :name),
      tool_call_id: fetch(msg, :tool_call_id),
      content: to_req_llm_parts(fetch(msg, :content, [])),
      metadata: metadata
    }
  end

  defp to_req_llm_parts(blocks) when is_list(blocks) do
    Enum.flat_map(blocks, fn block ->
      case to_req_llm_part(block) do
        nil -> []
        part -> [part]
      end
    end)
  end

  defp to_req_llm_part(%{type: "text"} = block) do
    meta = merge_part_metadata(block)
    ContentPart.text(fetch(block, :text, ""), meta)
  end

  defp to_req_llm_part(%{type: "thinking"} = block) do
    meta =
      block
      |> merge_part_metadata()
      |> maybe_put_atom_key(:signature, fetch(block, :signature))

    ContentPart.thinking(fetch(block, :text, ""), meta)
  end

  defp to_req_llm_part(%{type: "image"} = block) do
    meta = merge_part_metadata(block)
    data = fetch(block, :data)
    url = fetch(block, :url)
    media_type = fetch(block, :media_type) || "image/png"

    cond do
      is_binary(data) ->
        ContentPart.image(data, media_type, meta)

      is_binary(url) and url != "" ->
        part = ContentPart.image_url(url, meta)
        if media_type != "", do: %{part | media_type: media_type}, else: part

      true ->
        nil
    end
  end

  defp to_req_llm_part(%{type: "image_url", url: url} = block) when is_binary(url) do
    meta = merge_part_metadata(block)
    part = ContentPart.image_url(url, meta)

    case fetch(block, :media_type) do
      mt when is_binary(mt) and mt != "" -> %{part | media_type: mt}
      _ -> part
    end
  end

  defp to_req_llm_part(%{type: "provider_block", data: data} = block) when is_map(data) do
    provider = normalize_provider_atom(fetch(block, :provider)) || :unknown
    ContentPart.provider_block(provider, data, fetch(block, :metadata, %{}))
  end

  defp to_req_llm_part(_other), do: nil

  defp merge_part_metadata(block) do
    meta = fetch(block, :metadata, %{})

    case fetch(block, :provider_meta) do
      %{} = pmeta when map_size(pmeta) > 0 -> Map.merge(meta, atomize_known_meta(pmeta))
      _ -> meta
    end
  end

  defp atomize_known_meta(pmeta) do
    Enum.reduce(pmeta, %{}, fn
      {k, v}, acc when k in [:thought_signature, "thought_signature"] ->
        Map.put(acc, :thought_signature, v)

      {k, v}, acc when k in [:signature, "signature"] ->
        Map.put(acc, :signature, v)

      {k, v}, acc ->
        Map.put(acc, k, v)
    end)
  end

  defp to_req_llm_tool_calls(tool_calls) do
    Enum.map(tool_calls, fn tc ->
      args_json =
        case fetch(tc, :arguments, %{}) do
          json when is_binary(json) -> json
          args -> JSON.encode!(args)
        end

      call = ToolCall.new(fetch(tc, :id), fetch(tc, :name), args_json)

      case fetch(tc, :metadata) do
        %{} = meta when map_size(meta) > 0 -> ToolCall.put_metadata(call, meta)
        _ -> call
      end
    end)
  end

  defp build_reasoning_details(msg, blocks) do
    case fetch(msg, :reasoning_details) do
      details when is_list(details) and details != [] ->
        Enum.map(details, &to_reasoning_detail_struct/1)

      _ ->
        msg_provider =
          msg
          |> fetch(:provider_meta, %{})
          |> fetch(:provider)
          |> normalize_provider_atom()

        blocks
        |> Enum.filter(&(&1.type == "thinking"))
        |> Enum.with_index()
        |> Enum.flat_map(fn {block, idx} ->
          pmeta = fetch(block, :provider_meta, %{})
          signature = fetch(block, :signature) || fetch(pmeta, :signature)

          if is_binary(signature) or (is_map(pmeta) and map_size(pmeta) > 0) do
            [
              %ReasoningDetails{
                text: fetch(block, :text, ""),
                signature: signature,
                encrypted?: fetch(block, :encrypted?, false) == true,
                provider: normalize_provider_atom(fetch(block, :provider)) || msg_provider,
                format: fetch(block, :format) || fetch(pmeta, :format),
                index: fetch(block, :index, idx),
                provider_data: if(is_map(pmeta), do: pmeta, else: %{})
              }
            ]
          else
            []
          end
        end)
        |> case do
          [] -> nil
          list -> list
        end
    end
  end

  defp to_reasoning_detail_struct(%ReasoningDetails{} = detail), do: detail

  defp to_reasoning_detail_struct(detail) when is_map(detail) do
    %ReasoningDetails{
      text: fetch(detail, :text),
      signature: fetch(detail, :signature),
      encrypted?: fetch(detail, :encrypted?, false) == true,
      provider: normalize_provider_atom(fetch(detail, :provider)),
      format: fetch(detail, :format),
      index: fetch(detail, :index, 0),
      provider_data: fetch(detail, :provider_data, %{})
    }
  end

  defp normalize_provider_atom(atom) when is_atom(atom) and not is_nil(atom), do: atom
  defp normalize_provider_atom("anthropic"), do: :anthropic
  defp normalize_provider_atom("google"), do: :google
  defp normalize_provider_atom("google_vertex"), do: :google_vertex
  defp normalize_provider_atom("openai"), do: :openai
  defp normalize_provider_atom("openrouter"), do: :openrouter
  defp normalize_provider_atom("deepseek"), do: :deepseek
  defp normalize_provider_atom("ollama"), do: :ollama
  defp normalize_provider_atom(_), do: nil

  # Field helpers (atom or string keys without dynamic atom creation)

  defp entry_id(%{id: id}), do: id
  defp entry_id(%{"id" => id}), do: id
  defp entry_id(_), do: nil

  defp entry_kind(%{kind: kind}), do: kind
  defp entry_kind(%{"kind" => kind}), do: kind
  defp entry_kind(_), do: nil

  defp entry_data(%{data: data}) when is_map(data), do: data
  defp entry_data(%{"data" => data}) when is_map(data), do: data
  defp entry_data(_), do: %{}

  defp fetch(map, key, default \\ nil)

  defp fetch(map, key, default) when is_map(map) and is_atom(key) do
    case Map.fetch(map, key) do
      {:ok, value} -> value
      :error -> Map.get(map, Atom.to_string(key), default)
    end
  end

  defp fetch_any(map, keys) when is_map(map) do
    Enum.find_value(keys, fn key -> fetch(map, key) end)
  end

  defp maybe_put_field(map, _key, nil), do: map
  defp maybe_put_field(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_atom_key(map, _key, nil), do: map
  defp maybe_put_atom_key(map, key, value), do: Map.put(map, key, value)

  defp maybe_put_meta(msg, data) do
    case fetch(data, :metadata) do
      %{} = meta when map_size(meta) > 0 -> Map.put(msg, :metadata, meta)
      _ -> msg
    end
  end
end
