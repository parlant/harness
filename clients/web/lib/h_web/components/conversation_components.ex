defmodule HWeb.ConversationComponents do
  @moduledoc "Stateless rendering for committed entries and in-flight conversation activity."
  use HWeb, :html

  attr(:entry, :map, required: true)

  def entry_body(assigns) do
    data = assigns.entry["data"] || %{}
    kind = assigns.entry["kind"]
    {thinking, text} = extract_parts(data)
    tool_calls = if is_list(data["tool_calls"]), do: data["tool_calls"], else: []

    assigns =
      assign(assigns,
        data: data,
        kind: kind,
        thinking: thinking,
        text: text,
        tool_calls: tool_calls
      )

    ~H"""
    <details :if={@thinking != ""} class="collapsible">
      <summary>Thinking</summary>
      <pre class="code-pre">{@thinking}</pre>
    </details>

    <div :if={@kind == "tool_result"}>
      <details class="collapsible">
        <summary>Tool Output</summary>
        <pre class="code-pre">{format_tool_output(@data, @text)}</pre>
      </details>
    </div>

    <div :if={@kind != "tool_result"}>
      <img
        :for={
          %{
            "type" => "image",
            "encoding" => "base64",
            "media_type" => "image/jpeg",
            "data" => encoded
          } <- List.wrap(@data["content"])
        }
        src={"data:image/jpeg;base64," <> encoded}
        class="feedback-image"
        alt="Attached screenshot"
        loading="lazy"
      />
      <p :if={@text != ""} class="entry-text">{@text}</p>

      <div :for={tc <- @tool_calls} class="tool-call-card">
        <div class="tool-call-head">
          <span class="badge mono">{tc["name"] || "tool"}</span>
          <span :if={tc["id"]} class="muted mono">{tc["id"]}</span>
        </div>
        <pre class="code-pre">{format_json(tc["arguments"] || tc["args"] || tc["input"] || %{})}</pre>
      </div>

      <pre :if={@text == "" and @thinking == "" and @tool_calls == []} class="code-pre">{format_json(@data)}</pre>
    </div>
    """
  end

  attr(:live, :map, required: true)
  attr(:inbox, :list, required: true)

  def live_region(assigns) do
    live = assigns.live || %{}
    gen = Map.get(live, "generation")
    run = Map.get(live, "run")
    msg = if is_map(gen), do: Map.get(gen, "message") || gen, else: %{}
    {thinking, text} = extract_parts(msg)
    tools = normalize_live_tools(Map.get(live, "tools"))

    {failure, failure_label} =
      case {live["run_failure"], live["compaction_failure"]} do
        {run_failure, _} when not is_nil(run_failure) ->
          {run_failure, "Run paused"}

        {nil, %{"automatic" => true} = failure} ->
          {failure, "Run paused during automatic compaction"}

        {nil, failure} ->
          {failure, "Compaction failed"}
      end

    inbox = assigns.inbox || []

    visible? =
      not is_nil(gen) or not is_nil(run) or tools != [] or inbox != [] or not is_nil(failure)

    assigns =
      assign(assigns,
        visible?: visible?,
        gen: gen,
        run: run,
        thinking: thinking,
        text: text,
        tools: tools,
        failure: failure,
        failure_label: failure_label,
        inbox: inbox
      )

    ~H"""
    <section :if={@visible?} id="live-region" class="live-region" aria-live="polite">
      <div :if={@gen || @run} id="live-generation" class="entry-card entry-live">
        <div class="entry-header-left">
          <span class="role-label">assistant (live)</span>
          <span :if={is_map(@run) and @run["turns"]} class="badge mono">
            turn {@run["turns"]}
          </span>
        </div>

        <details :if={@thinking != ""} class="collapsible" open>
          <summary>Thinking (streaming)</summary>
          <pre class="code-pre">{@thinking}</pre>
        </details>

        <p :if={@text != ""} class="entry-text">{@text}</p>
        <p :if={@text == "" and @thinking == ""} class="muted mono">Streaming…</p>
      </div>

      <div :if={@tools != []} id="live-tools" class="live-tools">
        <div class="role-label">Running Tools</div>
        <div :for={slot <- @tools} class="tool-call-card">
          <div class="tool-call-head">
            <span class="badge mono">{slot["name"] || "tool"}</span>
            <span :if={slot["status"]} class="badge">{slot["status"]}</span>
          </div>
          <pre :if={tool_slot_output(slot) != ""} class="code-pre">{tool_slot_output(slot)}</pre>
        </div>
      </div>

      <div :if={@inbox != []} id="live-inbox" class="live-inbox">
        <div class="role-label">Queued ({length(@inbox)})</div>
        <div :for={item <- @inbox} class="inbox-item">
          {format_inbox_item(item)}
        </div>
      </div>

      <div :if={@failure} id="run-failure-banner" class="run-failure-banner">
        <div>
          <strong>{@failure_label}:</strong>
          <span>{format_failure(@failure)}</span>
        </div>
        <p :if={@failure_label == "Compaction failed"}>
          History preserved. Retry with <code>/compact</code> in hi.
        </p>
        <button
          :if={@failure_label != "Compaction failed"}
          id="continue-run-btn"
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="continue_run"
        >
          Continue Run
        </button>
      </div>
    </section>
    """
  end

  defp extract_parts(data) when is_map(data) do
    thinking =
      [data["thinking"], data["reasoning"]]
      |> Enum.filter(&is_binary/1)

    {content_thinking, content_text} =
      case data["content"] do
        text when is_binary(text) ->
          {[], [text]}

        blocks when is_list(blocks) ->
          Enum.reduce(blocks, {[], []}, fn
            block, {th, tx} when is_binary(block) ->
              {th, tx ++ [block]}

            %{"type" => type} = block, {th, tx} when type in ["thinking", "reasoning"] ->
              t = block["thinking"] || block["text"]
              if is_binary(t) and t != "", do: {th ++ [t], tx}, else: {th, tx}

            %{"type" => "text"} = block, {th, tx} ->
              t = block["text"]
              if is_binary(t) and t != "", do: {th, tx ++ [t]}, else: {th, tx}

            _, acc ->
              acc
          end)

        _ ->
          {[], []}
      end

    text_fallback =
      if content_text == [] and is_binary(data["text"]) and data["text"] != "" do
        [data["text"]]
      else
        content_text
      end

    {
      Enum.join(thinking ++ content_thinking, "\n\n"),
      Enum.join(text_fallback, "\n")
    }
  end

  defp extract_parts(_), do: {"", ""}

  defp normalize_live_tools(tools) when is_list(tools), do: tools

  defp normalize_live_tools(tools) when is_map(tools) do
    Enum.map(tools, fn {id, slot} ->
      if is_map(slot), do: Map.put_new(slot, "id", id), else: %{"id" => id}
    end)
  end

  defp normalize_live_tools(_), do: []

  defp tool_slot_output(slot) do
    to_string(slot["output"] || slot["stdout"] || slot["text"] || "")
  end

  defp format_tool_output(data, text) do
    cond do
      text != "" -> text
      Map.has_key?(data, "output") -> format_json(data["output"])
      Map.has_key?(data, "result") -> format_json(data["result"])
      Map.has_key?(data, "error") -> format_json(data["error"])
      true -> format_json(data)
    end
  end

  defp format_inbox_item(item) when is_map(item) do
    {_th, text} = extract_parts(item)
    mode = if item["when_busy"], do: "[#{item["when_busy"]}] ", else: ""
    mode <> if(text != "", do: text, else: format_json(item))
  end

  defp format_inbox_item(other), do: format_json(other)

  defp format_failure(failure) when is_binary(failure), do: failure

  defp format_failure(failure) when is_map(failure) do
    failure["message"] || failure["detail"] || failure["reason"] || format_json(failure)
  end

  defp format_failure(other), do: inspect(other)

  defp format_json(value) when is_binary(value), do: value

  defp format_json(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value)
  end
end
