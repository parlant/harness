defmodule HWeb.ConversationComponents do
  @moduledoc "Stateless rendering for committed messages and in-flight conversation activity."
  use HWeb, :html

  alias HWeb.{Activity, Markdown}

  def message?(%{"kind" => "user"}), do: true

  def message?(%{"kind" => "assistant", "data" => data}) do
    String.trim(message_text(data)) != "" or images(data) != [] or
      filtered_assistant_notice(data) != nil
  end

  def message?(_), do: false

  attr(:id, :string, required: true)
  attr(:compact, :boolean, default: false)

  def stop_button(assigns) do
    ~H"""
    <button
      id={@id}
      type="button"
      class={["stop-run", if(@compact, do: "stop-run-compact", else: "btn")]}
      phx-click="abort"
      aria-label="Stop current run"
      title="Stop current run"
    >
      <svg viewBox="0 0 16 16" aria-hidden="true">
        <rect x="3" y="3" width="10" height="10" rx="1" fill="currentColor" />
      </svg>
    </button>
    """
  end

  attr(:id, :string, required: true)
  attr(:entry, :map, required: true)
  attr(:session_id, :string, default: nil)
  attr(:can_fork?, :boolean, default: false)

  def entry_card(assigns) do
    data = assigns.entry["data"] || %{}
    text = message_text(data)

    assigns =
      assign(assigns,
        kind: assigns.entry["kind"],
        copy_text: if(String.trim(text) != "", do: text),
        status: entry_status(data)
      )

    ~H"""
    <article
      id={@id}
      class={["entry-card", "entry-#{@kind}", @status && "has-status"]}
    >
      <div class="entry-body">
        <.entry_body entry={@entry} session_id={@session_id} />
      </div>
      <.entry_toolbar
        entry_id={@entry["id"]}
        copy_text={@copy_text}
        status={@status}
        can_fork?={@can_fork?}
        edit?={@kind == "user"}
      />
    </article>
    """
  end

  attr(:entry_id, :any, required: true)
  attr(:copy_text, :string, default: nil)
  attr(:status, :atom, default: nil)
  attr(:can_fork?, :boolean, required: true)
  attr(:edit?, :boolean, default: false)
  attr(:child_sid, :string, default: nil)
  attr(:copy_label, :string, default: "Copy message")

  defp entry_toolbar(assigns) do
    ~H"""
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
        aria-label={@copy_label}
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
        :if={@can_fork? && @edit?}
        type="button"
        class="toolbar-btn edit-btn"
        phx-click="edit_entry"
        phx-value-entry_id={@entry_id}
        aria-label={"Edit prompt at step ##{@entry_id}"}
        title="Edit on a new branch"
      >
        <svg class="toolbar-icon" viewBox="0 0 24 24" aria-hidden="true">
          <path d="m15 5 4 4M4 20l4.5-1 12-12a2.8 2.8 0 0 0-4-4l-12 12L4 20Z" />
        </svg>
        <span>Edit</span>
      </button>
      <button
        :if={@can_fork? && !@edit?}
        type="button"
        class="toolbar-btn fork-btn"
        phx-click="fork_entry"
        phx-value-entry_id={@entry_id}
        aria-label={"Fork from step ##{@entry_id}"}
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
      <.link
        :if={@child_sid}
        navigate={~p"/sessions/#{@child_sid}"}
        class="toolbar-btn subagent-open-link"
      >
        Open subsession
      </.link>

      <span :if={@entry_id} class="entry-step-id mono">#{@entry_id}</span>
    </footer>
    """
  end

  attr(:entry, :map, required: true)
  attr(:session_id, :string, default: nil)

  def entry_body(assigns) do
    data = assigns.entry["data"] || %{}

    assigns =
      assign(assigns,
        kind: assigns.entry["kind"],
        text: message_text(data),
        filter_notice: filtered_assistant_notice(data),
        images: images(data)
      )

    ~H"""
    <div>
      <img
        :for={{media_type, encoded} <- @images}
        src={"data:" <> media_type <> ";base64," <> encoded}
        class="feedback-image"
        alt="Attached screenshot"
        loading="lazy"
      />
      <.assistant_text
        :if={@kind == "assistant" and @text != ""}
        text={@text}
        session_id={@session_id}
      />
      <p :if={@kind == "assistant" and @text == "" and @filter_notice} class="muted">
        {@filter_notice}
      </p>
      <p :if={@kind == "user" and @text != ""} class="entry-text">{@text}</p>
    </div>
    """
  end

  attr(:text, :string, required: true)
  attr(:session_id, :string, default: nil)

  defp assistant_text(assigns) do
    ~H"""
    <div class="markdown">{Markdown.render(@text, @session_id)}</div>
    """
  end

  attr(:id, :string, required: true)
  attr(:activity, :map, required: true)

  def activity_line(assigns) do
    %{count: count, tools: tools} = assigns.activity
    status = Map.get(assigns.activity, :status)

    label =
      case {count, tools, status} do
        {1, [], _} -> "1 activity"
        {count, [], _} when count > 0 -> "#{count} activities"
        {1, _, _} -> "1 tool call"
        {count, [_ | _], _} -> "#{count} tool calls"
        {0, _, :retrying} -> "Retrying…"
        {0, _, :waiting} -> "Waiting…"
        {0, _, _} -> "Working…"
      end

    assigns = assign(assigns, tools: tools, status: status, label: label)

    ~H"""
    <div id={@id} class="activity-line" data-activity-key={@activity[:id]} data-status={@status}>
      <details :if={@tools != []} id={@id <> "-details"} phx-mounted={JS.ignore_attributes("open")}>
        <summary class="activity-caption">
          <.activity_spinner status={@status} />
          {@label}
          <svg class="activity-chevron toolbar-icon" viewBox="0 0 16 16" aria-hidden="true">
            <path d="m6 4 4 4-4 4" />
          </svg>
        </summary>
        <ol class="activity-tools" aria-label="Tool calls">
          <li :for={tool <- @tools}>
            <button
              type="button"
              class="btn btn-sm mono"
              phx-click="inspect_tool"
              phx-value-call_entry={tool.call_entry}
              phx-value-call_index={tool.call_index}
              phx-value-result_entry={tool.result_entry}
              phx-value-live_id={tool.live_id}
            >
              {tool.name || "Tool call"}
            </button>
          </li>
        </ol>
      </details>
      <div :if={@tools == []} class="activity-caption">
        <.activity_spinner status={@status} />
        {@label}
      </div>
    </div>
    """
  end

  attr(:status, :atom, required: true)

  defp activity_spinner(assigns) do
    ~H"""
    <svg
      :if={@status in [:working, :retrying]}
      class="activity-spinner"
      viewBox="0 0 16 16"
      role="img"
      aria-label={if @status == :retrying, do: "Retrying", else: "Working"}
      fill="none"
      stroke-width="2"
    >
      <circle cx="8" cy="8" r="6" />
      <path d="M8 2a6 6 0 0 1 6 6" stroke-linecap="round" />
    </svg>
    """
  end

  attr(:inspection, :map, required: true)

  def tool_inspection(assigns) do
    inspection = assigns.inspection
    result = inspection.result || %{}
    output = message_text(result)

    images =
      for %{"type" => "image", "data" => encoded} = image <- List.wrap(result["content"]),
          mime = image["media_type"] || image["mime_type"],
          mime in ["image/jpeg", "image/png", "image/webp", "image/gif"],
          is_binary(encoded),
          do: {mime, encoded}

    output =
      cond do
        is_nil(inspection.result) -> inspection.output
        output != "" -> output
        images != [] -> nil
        value = result["output"] || result["error"] || result["diagnostic"] -> format_json(value)
        true -> nil
      end

    arguments =
      case inspection.arguments do
        nil -> nil
        args when is_binary(args) -> args
        args -> Jason.encode!(args, pretty: true)
      end

    assigns = assign(assigns, output: output, images: images, arguments: arguments)

    ~H"""
    <div class="tool-inspection">
      <h3>Arguments</h3>
      <pre :if={@arguments not in [nil, ""]}>{@arguments}</pre>
      <p :if={@arguments in [nil, ""]} class="muted">No arguments available in this view.</p>
      <h3>Output</h3>
      <pre :if={@output not in [nil, ""]}>{@output}</pre>
      <img
        :for={{mime, encoded} <- @images}
        src={"data:" <> mime <> ";base64," <> encoded}
        alt="Tool output image"
      />
      <p :if={@output in [nil, ""] and @images == []} class="muted">No output available.</p>
      <p :if={@inspection.live? and is_nil(@inspection.result)} class="muted">
        Live snapshot. Reopen this call to see newer output.
      </p>
    </div>
    """
  end

  attr(:live, :map, required: true)
  attr(:inbox, :list, required: true)
  attr(:tail_activity, :any, default: nil)
  attr(:tasks, :list, default: [])

  def live_region(assigns) do
    live = assigns.live || %{}
    gen = live["generation"] || %{}
    msg = gen["message"] || gen
    text = message_text(msg)
    streaming_text? = String.trim(text) != ""
    activity = Activity.live_summary(assigns.tail_activity, live, msg, streaming_text?)

    {failure, failure_label} =
      case {live["run_failure"], live["compaction_failure"]} do
        {%{"reason" => "budget_exceeded"} = run_failure, _} ->
          {run_failure, "Budget reached"}

        {run_failure, _} when not is_nil(run_failure) ->
          {run_failure, "Run paused"}

        {nil, %{"automatic" => true} = failure} ->
          {failure, "Run paused during automatic compaction"}

        {nil, failure} ->
          {failure, "Compaction failed"}
      end

    retry = get_in(live, ["generation", "retry"]) || get_in(live, ["compaction", "retry"])
    wait = get_in(live, ["generation", "wait"]) || get_in(live, ["compaction", "wait"])
    approvals = pending_approvals(live)
    active_tools = active_tool_slots(live)

    waiting_signals =
      Enum.filter(active_tools, fn slot ->
        slot["name"] == "wait_signal" and slot["status"] == "waiting"
      end)

    subagent_waits =
      for slot <- active_tools,
          slot["name"] == "subagent",
          slot["status"] == "waiting",
          sid = non_empty_string(slot["child_session_id"]) do
        view = get_in(live, ["subagent_waits", slot["id"]]) || %{}
        %{id: slot["id"], sid: sid, cid: view["conversation_id"], detail: view["detail"]}
      end

    assigns =
      assign(assigns,
        activity: activity,
        streaming_text?: streaming_text?,
        text: text,
        failure: failure,
        failure_label: failure_label,
        budget_exceeded?: match?(%{"reason" => "budget_exceeded"}, failure),
        retry: retry,
        wait: wait,
        approvals: approvals,
        active_tools: active_tools,
        waiting_signals: waiting_signals,
        subagent_waits: subagent_waits
      )

    ~H"""
    <section
      :if={
        @streaming_text? || @activity || @inbox != [] || @failure || @retry || @wait ||
          @approvals != [] || @active_tools != [] || @subagent_waits != []
      }
      id="live-region"
      class="live-region"
      aria-live="polite"
    >
      <.activity_line
        :if={@activity}
        id="live-activity"
        activity={@activity}
      />
      <div :if={@waiting_signals != []} id="wait-signal-badges" class="wait-signal-badges">
        <span :for={slot <- @waiting_signals} class="badge badge-active mono">
          wait_signal · waiting
        </span>
      </div>
      <div :if={@approvals != []} id="pending-approvals" class="approval-list">
        <article
          :for={approval <- @approvals}
          id={"approval-card-#{approval["task_id"]}"}
          class="approval-card"
          role="region"
          aria-label={"Approval required for #{approval["tool_name"]}"}
        >
          <div class="approval-card-head">
            <span class="badge badge-warn mono">approval</span>
            <strong class="mono">{approval["tool_name"]}</strong>
            <span class="muted mono">task #{approval["task_id"]}</span>
          </div>
          <div :if={approval["cwd"]} class="approval-cwd mono muted">
            cwd: {approval["cwd"]}
          </div>
          <pre :if={approval["arguments"]} class="approval-args mono">{format_json_pretty(approval["arguments"])}</pre>
          <div class="approval-actions">
            <button
              id={"approve-tool-#{approval["task_id"]}"}
              type="button"
              class="btn btn-sm btn-primary"
              phx-click="approve_tool"
              phx-value-task-id={approval["task_id"]}
              phx-value-decision="allow"
            >
              Approve
            </button>
            <button
              id={"deny-tool-#{approval["task_id"]}"}
              type="button"
              class="btn btn-sm btn-danger"
              phx-click="approve_tool"
              phx-value-task-id={approval["task_id"]}
              phx-value-decision="deny"
            >
              Deny
            </button>
            <button
              id={"abort-approval-task-#{approval["task_id"]}"}
              type="button"
              class="btn btn-sm btn-ghost"
              phx-click="abort_task"
              phx-value-task-id={approval["task_id"]}
            >
              Abort
            </button>
          </div>
        </article>
      </div>
      <div :if={@active_tools != []} id="live-active-tools" class="active-tool-controls">
        <div
          :for={slot <- @active_tools}
          :if={slot_task_id(slot, @approvals)}
          id={"active-tool-#{slot["id"]}"}
          class="active-tool-row"
        >
          <% tid = slot_task_id(slot, @approvals) %>
          <span class="mono">{slot["name"]}</span>
          <span class="badge mono">{slot["status"]}</span>
          <button
            id={"abort-task-#{tid}"}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="abort_task"
            phx-value-task-id={tid}
          >
            Abort
          </button>
        </div>
      </div>
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
      <div
        :for={sub_wait <- @subagent_waits}
        id={"subagent-wait-#{sub_wait.id}"}
        class="retry-banner subagent-wait-banner"
        role="status"
      >
        <strong>Waiting on subagent <span class="mono">{sub_wait.sid}</span></strong>
        <p :if={sub_wait.detail}>{sub_wait.detail}</p>
        <p>
          <.link
            navigate={
              if sub_wait.cid,
                do: ~p"/sessions/#{sub_wait.sid}/conversations/#{sub_wait.cid}",
                else: ~p"/sessions/#{sub_wait.sid}"
            }
            class="subagent-open-link"
          >
            Open subsession
          </.link>
        </p>
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

      <div :if={@inbox != []} id="live-inbox" class="live-inbox">
        <div class="role-label">Queued ({length(@inbox)})</div>
        <div :for={item <- @inbox} class="inbox-item">
          {format_inbox_item(item)}
        </div>
      </div>

      <div
        :if={@failure}
        id="run-failure-banner"
        class={["run-failure-banner", @budget_exceeded? && "is-budget-exceeded"]}
        data-failure-reason={if(is_map(@failure), do: @failure["reason"])}
      >
        <div>
          <strong>{@failure_label}:</strong>
          <span>{format_failure(@failure)}</span>
          <span :if={@budget_exceeded? && @failure["limit"]} class="badge badge-warn mono">
            {@failure["limit"]}
          </span>
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
          {if @budget_exceeded?, do: "Continue", else: "Continue Run"}
        </button>
      </div>
    </section>
    """
  end

  attr(:id, :string, required: true)
  attr(:card, :map, required: true)
  attr(:child, :map, default: nil)
  attr(:can_fork?, :boolean, default: false)
  attr(:active_task_id, :string, default: nil)

  def subagent_card(assigns) do
    %{card: card, child: child} = assigns

    status =
      cond do
        card.status in ["failed", "aborted", "interrupted"] -> card.status
        child -> child.attention
        true -> card.status
      end

    status_class =
      cond do
        status in ["failed", "error", "quarantined"] -> "badge-danger"
        status in ["running", "sleeping", "retrying", "waiting"] -> "badge-active"
        true -> nil
      end

    abortable_task_id =
      if status in ["pending", "running", "sleeping", "retrying", "waiting"],
        do: assigns.active_task_id || child_parent_task_id(child),
        else: nil

    assigns =
      assign(assigns,
        title: card.title || (child && child.title),
        prompt_preview: preview_text(card.prompt),
        status: status,
        status_class: status_class,
        abortable_task_id: abortable_task_id
      )

    ~H"""
    <article
      id={@id}
      class="entry-card entry-subagent"
      data-child-session-id={@card.child_id}
    >
      <div class="subagent-card">
        <div class="subagent-card-head">
          <span class="badge mono">subagent</span>
          <span class={["badge mono subagent-status-pill", @status_class]}>{@status}</span>
          <button
            :if={@abortable_task_id}
            id={"abort-subagent-#{@abortable_task_id}"}
            type="button"
            class="btn btn-sm btn-ghost"
            phx-click="abort_task"
            phx-value-task-id={@abortable_task_id}
          >
            Abort
          </button>
        </div>
        <div :if={@title} class="subagent-card-title">{@title}</div>
        <p :if={@prompt_preview} class="subagent-card-preview muted">{@prompt_preview}</p>
      </div>
      <.entry_toolbar
        entry_id={@card.entry_id}
        copy_text={@card.prompt}
        copy_label="Copy prompt"
        can_fork?={@can_fork?}
        child_sid={@card.child_id}
      />
    </article>
    """
  end

  defp entry_status(data) when is_map(data) do
    cond do
      data["aborted"] == true or data["stop_reason"] == "aborted" -> :aborted
      data["is_error"] == true or not is_nil(data["error"]) -> :failed
      true -> nil
    end
  end

  defp entry_status(_), do: nil

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

  defp format_json_pretty(value) when is_binary(value), do: value

  defp format_json_pretty(value) do
    Jason.encode!(value, pretty: true)
  rescue
    _ -> format_json(value)
  end

  defp pending_approvals(%{"approvals" => approvals}) when is_map(approvals) do
    approvals
    |> Map.values()
    |> Enum.filter(&is_map/1)
    |> Enum.sort_by(fn rec -> to_string(rec["task_id"] || "") end)
  end

  defp pending_approvals(_), do: []

  defp active_tool_slots(%{"tools" => tools}) when is_map(tools) do
    tools
    |> Enum.map(fn {id, slot} -> Map.put_new(slot, "id", id) end)
    |> Enum.filter(fn slot ->
      is_map(slot) and slot["status"] in ["pending", "running", "waiting", "retrying"]
    end)
    |> Enum.sort_by(fn slot -> to_string(slot["task_id"] || slot["id"] || "") end)
  end

  defp active_tool_slots(%{"tools" => tools}) when is_list(tools) do
    tools
    |> Enum.filter(fn slot ->
      is_map(slot) and slot["status"] in ["pending", "running", "waiting", "retrying"]
    end)
    |> Enum.sort_by(fn slot -> to_string(slot["task_id"] || slot["id"] || "") end)
  end

  defp active_tool_slots(_), do: []

  defp child_parent_task_id(%{parent: %{task_id: tid}}) when not is_nil(tid), do: to_string(tid)

  defp child_parent_task_id(%{"parent" => %{"task_id" => tid}}) when not is_nil(tid),
    do: to_string(tid)

  defp child_parent_task_id(_), do: nil

  defp slot_task_id(slot, approvals) when is_map(slot) do
    slot["task_id"] ||
      Enum.find_value(approvals, fn rec ->
        if rec["call_id"] && rec["call_id"] == slot["id"], do: rec["task_id"]
      end)
  end

  defp slot_task_id(_, _), do: nil
end
