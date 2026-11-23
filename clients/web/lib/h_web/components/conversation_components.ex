defmodule HWeb.ConversationComponents do
  @moduledoc "Stateless rendering for committed messages and in-flight conversation activity."
  use HWeb, :html

  alias HWeb.{Activity, CatalogState, Markdown}

  def message?(%{"kind" => "user"}), do: true

  def message?(%{"kind" => "assistant", "data" => data}) do
    String.trim(message_text(data)) != "" or images(data) != [] or subagent_tool_calls(data) != [] or
      filtered_assistant_notice(data) != nil
  end

  def message?(%{"kind" => "tool_result", "data" => data}) do
    (data["tool_name"] || data["name"]) == "subagent"
  end

  def message?(_), do: false

  attr(:id, :string, required: true)
  attr(:entry, :map, required: true)
  attr(:catalog_by_id, :map, default: %{})
  attr(:can_fork?, :boolean, default: false)

  def entry_card(assigns) do
    data = assigns.entry["data"] || %{}
    kind = assigns.entry["kind"]
    tool_name = data["tool_name"] || data["name"]
    text = message_text(data)
    status = entry_status(data)

    assigns =
      assign(assigns,
        data: data,
        kind: kind,
        tool_name: tool_name,
        text: text,
        copy_text: copyable_text(kind, tool_name, text),
        status: status
      )

    ~H"""
    <article
      id={@id}
      class={[
        "entry-card",
        "entry-#{@kind}",
        @status && "has-status"
      ]}
    >
      <div class="entry-body">
        <.entry_body entry={@entry} catalog_by_id={@catalog_by_id} />
      </div>

      <footer class="entry-toolbar">
        <span :if={@status == :aborted} class="entry-status is-warn">
          <svg class="toolbar-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M6 18 18 6M6 6l12 12" />
          </svg>
          <span>Aborted</span>
        </span>
        <span :if={@status == :failed} class="entry-status is-danger">
          <svg class="toolbar-icon" viewBox="0 0 24 24" aria-hidden="true">
            <path d="M12 9v4m0 4h.01M10.29 3.86 1.82 18a2 2 0 0 0 1.71 3h16.94a2 2 0 0 0 1.71-3L13.71 3.86a2 2 0 0 0-3.42 0Z" />
          </svg>
          <span>Failed</span>
        </span>

        <button
          :if={@copy_text}
          type="button"
          class="toolbar-btn copy-btn"
          data-copy-btn
          data-copy-text={@copy_text}
          aria-label="Copy message"
          title="Copy"
        >
          <svg class="toolbar-icon icon-copy" viewBox="0 0 24 24" aria-hidden="true">
            <rect x="8" y="8" width="12" height="12" rx="2" />
            <path d="M16 8V6a2 2 0 0 0-2-2H6a2 2 0 0 0-2 2v8a2 2 0 0 0 2 2h2" />
          </svg>
          <svg class="toolbar-icon icon-check" viewBox="0 0 24 24" aria-hidden="true">
            <path d="m5 13 4 4L19 7" />
          </svg>
          <span class="copy-feedback" aria-live="polite">Copied</span>
        </button>

        <button
          :if={@can_fork?}
          type="button"
          class="toolbar-btn fork-btn"
          phx-click="fork_entry"
          phx-value-entry_id={@entry["id"]}
          aria-label={"Fork from step ##{@entry["id"]}"}
          title="Branch from here"
        >
          <svg class="toolbar-icon" viewBox="0 0 24 24" aria-hidden="true">
            <circle cx="6" cy="6" r="2.5" />
            <circle cx="18" cy="6" r="2.5" />
            <circle cx="6" cy="18" r="2.5" />
            <path d="M6 8.5v7M18 8.5a6 6 0 0 1-6 6H6" />
          </svg>
          <span>Fork</span>
        </button>

        <span :if={@entry["id"]} class="entry-step-id mono">#{@entry["id"]}</span>
      </footer>
    </article>
    """
  end

  attr(:entry, :map, required: true)
  attr(:catalog_by_id, :map, default: %{})

  def entry_body(assigns) do
    data = assigns.entry["data"] || %{}
    kind = assigns.entry["kind"]
    tool_name = data["tool_name"] || data["name"]

    assigns =
      assign(assigns,
        data: data,
        kind: kind,
        tool_name: tool_name,
        text: message_text(data),
        filter_notice: filtered_assistant_notice(data),
        images: images(data),
        subagent_calls: subagent_tool_calls(data)
      )

    ~H"""
    <div :if={@kind == "tool_result" and @tool_name == "subagent"}>
      <.subagent_card
        source={:tool_result}
        data={@data}
        text={@text}
        catalog_by_id={@catalog_by_id}
      />
    </div>

    <div :if={@kind != "tool_result"}>
      <img
        :for={{media_type, encoded} <- @images}
        src={"data:" <> media_type <> ";base64," <> encoded}
        class="feedback-image"
        alt="Attached screenshot"
        loading="lazy"
      />
      <.assistant_text :if={@kind == "assistant" and @text != ""} text={@text} />
      <p :if={@kind == "assistant" and @text == "" and @filter_notice} class="muted">
        {@filter_notice}
      </p>
      <p :if={@kind == "user" and @text != ""} class="entry-text">{@text}</p>

      <div :for={tc <- @subagent_calls}>
        <.subagent_card
          source={:tool_call}
          data={tc}
          text=""
          catalog_by_id={@catalog_by_id}
        />
      </div>
    </div>
    """
  end

  attr(:text, :string, required: true)

  defp assistant_text(assigns) do
    ~H"""
    <div class="markdown">{Markdown.render(@text)}</div>
    """
  end

  attr(:id, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:status, :atom, required: true)

  def activity_line(assigns) do
    {label, spinning?} =
      case assigns.status do
        :working -> {"Working", true}
        :retrying -> {"Retrying", true}
        :waiting -> {"Waiting", false}
        :paused -> {"Paused", false}
        :failed -> {"Failed", false}
        :stopped -> {"Stopped", false}
        :interrupted -> {"Interrupted", false}
        :incomplete -> {"Incomplete", false}
        :complete -> {"Complete", false}
      end

    assigns = assign(assigns, label: label, spinning?: spinning?)

    ~H"""
    <div id={@id} class="activity-line" data-status={@status}>
      <span :if={@spinning?} class="activity-spinner" aria-hidden="true"></span>
      <span>{@count} {if @count == 1, do: "activity", else: "activities"}</span>
      <span class="activity-status">· {@label}</span>
    </div>
    """
  end

  attr(:live, :map, required: true)
  attr(:inbox, :list, required: true)
  attr(:tail_activity, :any, default: nil)
  attr(:catalog_by_id, :map, default: %{})

  def live_region(assigns) do
    live = assigns.live || %{}
    gen = live["generation"] || %{}
    msg = gen["message"] || gen
    text = message_text(msg)
    streaming_text? = String.trim(text) != ""
    activity = Activity.live_summary(assigns.tail_activity, live, msg, streaming_text?)
    subagent_slots = live_subagent_slots(live["tools"])

    {failure, failure_label} =
      case {live["run_failure"], live["compaction_failure"]} do
        {run_failure, _} when not is_nil(run_failure) ->
          {run_failure, "Run paused"}

        {nil, %{"automatic" => true} = failure} ->
          {failure, "Run paused during automatic compaction"}

        {nil, failure} ->
          {failure, "Compaction failed"}
      end

    retry = get_in(live, ["generation", "retry"]) || get_in(live, ["compaction", "retry"])
    wait = get_in(live, ["generation", "wait"]) || get_in(live, ["compaction", "wait"])

    assigns =
      assign(assigns,
        activity: activity,
        streaming_text?: streaming_text?,
        subagent_slots: subagent_slots,
        text: text,
        failure: failure,
        failure_label: failure_label,
        retry: retry,
        wait: wait
      )

    ~H"""
    <section
      :if={
        @streaming_text? || @activity || @subagent_slots != [] || @inbox != [] || @failure ||
          @retry || @wait
      }
      id="live-region"
      class="live-region"
      aria-live="polite"
    >
      <.activity_line
        :if={@activity}
        id="live-activity"
        count={@activity.count}
        status={@activity.status}
      />
      <div :if={@wait} id="wait-banner" class="retry-banner" role="status">
        <strong>{@wait["title"] || "Waiting to continue"}</strong>
        <p>{@wait["code"]}: {@wait["message"]}</p>
        <p :if={@wait["status"] == "waiting"}>
          <span :if={@wait["detail"]}>{@wait["detail"]}</span>
          <time
            :if={@wait["resumes_at"]}
            datetime={DateTime.from_unix!(@wait["resumes_at"], :millisecond) |> DateTime.to_iso8601()}
          >
            Estimated ready: {DateTime.from_unix!(@wait["resumes_at"], :millisecond)
            |> Calendar.strftime("%H:%M:%S UTC")}.
          </time>
          Stop remains available.
        </p>
        <p :if={@wait["status"] != "waiting"}>Rechecking availability…</p>
      </div>
      <div :if={@retry} id="retry-banner" class="retry-banner" role="status">
        <strong>Retrying after provider error · {@retry["attempt"]}/{@retry["max_attempts"]}</strong>
        <p>{@retry["code"]}: {@retry["message"]}</p>
        <p :if={@retry["status"] == "waiting"}>
          Waiting {ceil((@retry["delay_ms"] || 0) / 1_000)}s before retry.
          <time
            :if={@retry["until"]}
            datetime={DateTime.from_unix!(@retry["until"], :millisecond) |> DateTime.to_iso8601()}
          >
            Next attempt: {DateTime.from_unix!(@retry["until"], :millisecond)
            |> Calendar.strftime("%H:%M:%S UTC")}
          </time>
          Stop remains available.
        </p>
        <p :if={@retry["status"] != "waiting"}>Retry request in progress.</p>
      </div>
      <article
        :if={@streaming_text?}
        id="live-generation"
        class="entry-card entry-assistant entry-live"
      >
        <div class="entry-body">
          <.assistant_text text={@text} />
        </div>
        <footer class="entry-toolbar entry-live-status" role="status">
          <span class="live-pulse-dot" aria-hidden="true"></span>
          <span>Streaming…</span>
        </footer>
      </article>

      <div :if={@subagent_slots != []} id="live-subagents" class="live-tools">
        <div :for={slot <- @subagent_slots}>
          <.subagent_card
            source={:live_slot}
            data={slot}
            text={tool_slot_output(slot)}
            catalog_by_id={@catalog_by_id}
          />
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

  attr(:source, :atom, required: true)
  attr(:data, :map, required: true)
  attr(:text, :string, default: "")
  attr(:catalog_by_id, :map, default: %{})

  defp subagent_card(assigns) do
    data = assigns.data || %{}
    details = if is_map(data["details"]), do: data["details"], else: %{}
    args = extract_tool_args(data)
    catalog_by_id = if is_map(assigns.catalog_by_id), do: assigns.catalog_by_id, else: %{}

    child_sid =
      non_empty_string(details["child_session_id"]) ||
        non_empty_string(data["child_session_id"]) ||
        non_empty_string(args["session_id"])

    child_session = if child_sid, do: Map.get(catalog_by_id, child_sid), else: nil

    mode =
      non_empty_string(args["mode"]) ||
        non_empty_string(details["mode"]) ||
        if(assigns.source == :tool_call, do: "wait", else: nil)

    read_only? = args["read_only"] == true or details["read_only"] == true

    title =
      non_empty_string(args["title"]) ||
        non_empty_string(details["title"]) ||
        if(child_session, do: non_empty_string(child_session.title), else: nil)

    prompt_preview = preview_text(args["prompt"] || data["prompt"])

    live_status =
      cond do
        not is_nil(child_session) ->
          format_child_status(child_session)

        is_binary(details["status"]) and details["status"] != "" ->
          details["status"]

        is_binary(data["status"]) and data["status"] != "" ->
          data["status"]

        true ->
          nil
      end

    live_status_class =
      cond do
        child_session && child_session.attention in ["error", "quarantined"] ->
          "badge-danger"

        child_session && CatalogState.processing?(child_session) ->
          "badge-active"

        data["is_error"] == true or not is_nil(data["error"]) ->
          "badge-danger"

        true ->
          nil
      end

    output =
      case assigns.source do
        :tool_result -> format_tool_output(data, assigns.text)
        :live_slot -> assigns.text
        _ -> ""
      end

    assigns =
      assign(assigns,
        child_sid: child_sid,
        child_session: child_session,
        mode: mode,
        read_only?: read_only?,
        title: title,
        prompt_preview: prompt_preview,
        live_status: live_status,
        live_status_class: live_status_class,
        output: output
      )

    ~H"""
    <div
      class="tool-call-card subagent-card"
      data-subagent-card="true"
      data-child-session-id={@child_sid}
    >
      <div class="subagent-card-head">
        <div class="tool-call-head">
          <span class="badge mono">subagent</span>
          <span :if={@mode} class="badge mono">{@mode}</span>
          <span :if={@read_only?} class="badge mono">read-only</span>
          <span :if={@live_status} class={["badge mono subagent-status-pill", @live_status_class]}>
            {@live_status}
          </span>
          <span :if={@child_sid} class="muted mono">{@child_sid}</span>
        </div>

        <.link
          :if={@child_sid}
          navigate={~p"/sessions/#{@child_sid}"}
          class="btn btn-sm btn-ghost subagent-open-link"
        >
          Open subsession →
        </.link>
      </div>

      <div :if={@title} class="subagent-card-title">{@title}</div>
      <p :if={@prompt_preview} class="subagent-card-preview muted">{@prompt_preview}</p>

      <details :if={@source == :tool_result && @output != ""} class="collapsible">
        <summary>Subagent Output</summary>
        <pre class="code-pre">{@output}</pre>
      </details>

      <pre :if={@source == :live_slot && @output != ""} class="code-pre">{@output}</pre>
    </div>
    """
  end

  defp copyable_text("user", _tool_name, text), do: non_empty_copy(text)
  defp copyable_text("assistant", _tool_name, text), do: non_empty_copy(text)
  defp copyable_text("tool_result", "subagent", text), do: non_empty_copy(text)
  defp copyable_text(_, _, _), do: nil

  defp non_empty_copy(text) when is_binary(text) do
    if String.trim(text) == "", do: nil, else: text
  end

  defp non_empty_copy(_), do: nil

  defp entry_status(data) when is_map(data) do
    cond do
      data["aborted"] == true or data["stop_reason"] == "aborted" -> :aborted
      data["is_error"] == true or not is_nil(data["error"]) -> :failed
      true -> nil
    end
  end

  defp entry_status(_), do: nil

  defp subagent_tool_calls(data) when is_map(data) do
    for %{"name" => "subagent"} = tc <- List.wrap(data["tool_calls"]), do: tc
  end

  defp subagent_tool_calls(_), do: []

  defp live_subagent_slots(tools) when is_map(tools) do
    tools
    |> Enum.sort_by(fn {id, _} -> to_string(id) end)
    |> Enum.flat_map(fn {id, slot} ->
      if is_map(slot) and slot["name"] == "subagent" and slot["status"] != "done" do
        [Map.put_new(slot, "id", to_string(id))]
      else
        []
      end
    end)
  end

  defp live_subagent_slots(tools) when is_list(tools) do
    for %{"name" => "subagent"} = slot <- tools, slot["status"] != "done", do: slot
  end

  defp live_subagent_slots(_), do: []

  defp tool_slot_output(slot) when is_map(slot) do
    out = slot["output"] || slot["text"] || ""
    if is_binary(out), do: out, else: format_json(out)
  end

  defp format_tool_output(data, text) do
    if text != "" do
      text
    else
      case data["output"] || data["result"] do
        out when is_binary(out) -> out
        nil -> format_json(data)
        other -> format_json(other)
      end
    end
  end

  defp extract_tool_args(data) when is_map(data) do
    case data["arguments"] || data["args"] || data["input"] do
      args when is_map(args) -> args
      _ -> %{}
    end
  end

  defp extract_tool_args(_), do: %{}

  defp format_child_status(child_session) do
    detail = CatalogState.status_detail(child_session)

    case {child_session.attention, detail} do
      {att, d} when is_binary(d) and d != "" and d != att -> "#{att} · #{d}"
      {att, _} -> att
    end
  end

  defp preview_text(val) when is_binary(val) do
    cleaned =
      val
      |> String.replace(~r/\s+/, " ")
      |> String.trim()

    cond do
      cleaned == "" -> nil
      String.length(cleaned) > 160 -> String.slice(cleaned, 0, 159) <> "…"
      true -> cleaned
    end
  end

  defp preview_text(_), do: nil

  defp non_empty_string(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty_string(_), do: nil

  defp images(data) do
    for %{
          "type" => "image",
          "media_type" => media_type,
          "data" => encoded
        } = image <- List.wrap(data["content"]),
        Map.get(image, "encoding", "base64") == "base64",
        media_type in ["image/jpeg", "image/png", "image/webp"],
        is_binary(encoded),
        do: {media_type, encoded}
  end

  defp message_text(data) do
    text =
      data["content"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        text when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")

    if text == "" and is_binary(data["text"]), do: data["text"], else: text
  end

  defp format_inbox_item(item) when is_map(item) do
    text = message_text(item)
    mode = if item["when_busy"], do: "[#{item["when_busy"]}] ", else: ""
    mode <> if(text != "", do: text, else: format_json(item))
  end

  defp format_inbox_item(other), do: format_json(other)

  defp format_failure(failure) when is_binary(failure), do: failure

  defp format_failure(failure) when is_map(failure) do
    failure["message"] || failure["detail"] || failure["reason"] || format_json(failure)
  end

  defp format_failure(other), do: inspect(other)

  defp filtered_assistant_notice(%{"finish_reason" => "content_filter"} = data) do
    meta = if is_map(data["provider_meta"]), do: data["provider_meta"], else: %{}
    raw = non_empty_string(meta["finish_reason_raw"])
    msg = non_empty_string(meta["finish_message"])

    cond do
      raw != nil and msg != nil -> "Output blocked by provider content filter (#{raw}): #{msg}"
      msg != nil -> "Output blocked by provider content filter: #{msg}"
      raw != nil -> "Output blocked by provider content filter (#{raw})."
      true -> "Output blocked by provider content filter."
    end
  end

  defp filtered_assistant_notice(_), do: nil

  defp format_json(value) when is_binary(value), do: value

  defp format_json(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value)
  end
end
