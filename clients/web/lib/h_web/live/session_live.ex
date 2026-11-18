defmodule HWeb.SessionLive do
  @moduledoc """
  LiveView for a running/resumed `H` session and conversation branch.

  Uses `Phoenix.LiveView.stream/4` for committed entries, stores only compact
  doc/cursor state, subscribes to `H.PubSub` on connected mount, reduces frames
  through `H.Transcript` (via `HWeb.Transcript`), resnapshots on sequence gaps,
  and updates only the live region on ephemeral streaming updates.
  """
  use HWeb, :live_view

  alias HWeb.{Backend, Transcript}

  @thinking_levels ~w(off minimal low medium high xhigh)

  @impl true
  def mount(%{"session_id" => session_id} = params, _session, socket) do
    cid = normalize_cid(params["conversation_id"])

    socket =
      socket
      |> assign(
        session_id: session_id,
        conversation_id: cid,
        subscribed_cid: nil,
        session: nil,
        conversations: [],
        tasks: [],
        models: Backend.list_models(),
        thinking_levels: @thinking_levels,
        transcript: Transcript.new(session_id: session_id, conversation_id: cid),
        cursor_seq: nil,
        committed_docs: %{},
        ephemeral_live: %{},
        inbox: [],
        agent: %{},
        usage: %{},
        before_entry_id: nil,
        has_more: false,
        run_active?: false,
        drawer_open?: false,
        composer_text: "",
        error_banner: nil
      )
      |> stream_configure(:entries, dom_id: &"entry-#{&1["id"]}")
      |> load_initial(session_id, cid)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"session_id" => sid} = params, _uri, socket) do
    cid = normalize_cid(params["conversation_id"])

    cond do
      sid != socket.assigns.session_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> assign(session_id: sid, conversation_id: cid)
         |> load_initial(sid, cid)}

      cid != socket.assigns.conversation_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> assign(conversation_id: cid)
         |> load_conversation(sid, cid)}

      true ->
        {:noreply, socket}
    end
  end

  @impl true
  def terminate(_reason, socket) do
    unsubscribe_current(socket)
    :ok
  end

  @impl true
  def handle_info({:commit_frame, _seq, json}, socket) do
    case Transcript.apply_commit(socket.assigns.transcript, json) do
      {:ok, appended, next_t} ->
        socket =
          Enum.reduce(appended, socket, fn entry, acc ->
            stream_insert(acc, :entries, entry)
          end)

        {:noreply,
         socket
         |> assign(:transcript, next_t)
         |> assign(Transcript.compact_assigns(next_t))}

      {:stale, _t} ->
        {:noreply, socket}

      {:gap, _t} ->
        {:noreply, resnapshot(socket)}

      {:error, _reason} ->
        {:noreply, resnapshot(socket)}
    end
  end

  def handle_info({:ephemeral_frame, json}, socket) do
    case Transcript.apply_ephemeral(socket.assigns.transcript, json) do
      {:ok, next_t} ->
        live = Map.get(next_t.reducer.docs, "live") || %{}

        {:noreply,
         assign(socket,
           transcript: next_t,
           ephemeral_live: live,
           run_active?: Transcript.run_active?(live)
         )}

      :ignored ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, socket}
    end
  end

  @impl true
  def handle_event("toggle_drawer", _params, socket) do
    {:noreply, assign(socket, :drawer_open?, not socket.assigns.drawer_open?)}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_banner, nil)}
  end

  def handle_event("composer_change", %{"content" => content}, socket) do
    {:noreply, assign(socket, :composer_text, content)}
  end

  def handle_event("submit", params, socket) do
    content = String.trim(params["content"] || socket.assigns.composer_text || "")
    mode = params["mode"]

    if content == "" do
      {:noreply, socket}
    else
      args =
        if mode == "steer" do
          %{
            "type" => "input",
            "content" => content,
            "when_busy" => "steer",
            "when_idle" => "reject"
          }
        else
          %{
            "type" => "input",
            "content" => content,
            "when_busy" => "follow_up",
            "when_idle" => "start"
          }
        end

      send_submit(socket, args, params["request_id"], clear_composer?: true)
    end
  end

  def handle_event("steer", params, socket) do
    content = String.trim(params["content"] || socket.assigns.composer_text || "")

    if content == "" do
      {:noreply, assign(socket, :error_banner, "Enter a message before steering.")}
    else
      args = %{
        "type" => "input",
        "content" => content,
        "when_busy" => "steer",
        "when_idle" => "reject"
      }

      send_submit(socket, args, params["request_id"], clear_composer?: true)
    end
  end

  def handle_event("continue_run", params, socket) do
    send_submit(socket, %{"type" => "continue"}, params["request_id"], clear_composer?: false)
  end

  def handle_event("abort", params, socket) do
    envelope = build_envelope(socket, "abort", %{}, params["request_id"])

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} ->
        {:noreply, assign(socket, :error_banner, nil)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("configure", params, socket) do
    args =
      %{}
      |> maybe_put("model", non_empty(params["model"]))
      |> maybe_put("thinking", non_empty(params["thinking"]))

    if map_size(args) == 0 do
      {:noreply, socket}
    else
      envelope = build_envelope(socket, "configure", args, params["request_id"])

      case Backend.execute_command(socket.assigns.session_id, envelope) do
        {:ok, _receipt} ->
          {:noreply, assign(socket, :error_banner, nil)}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  def handle_event("fork_entry", %{"entry_id" => entry_id_str} = params, socket) do
    case Integer.parse(to_string(entry_id_str)) do
      {entry_id, ""} when entry_id > 0 ->
        envelope =
          build_envelope(socket, "fork", %{"at_entry_id" => entry_id}, params["request_id"])

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, receipt} ->
            new_cid = to_string(receipt[:conversation_id] || receipt["conversation_id"] || "")
            socket = refresh_detail(socket)

            if new_cid != "" do
              {:noreply,
               push_patch(socket,
                 to: ~p"/sessions/#{socket.assigns.session_id}/conversations/#{new_cid}"
               )}
            else
              {:noreply, socket}
            end

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      _ ->
        {:noreply, assign(socket, :error_banner, "Invalid entry ID for fork")}
    end
  end

  def handle_event("load_earlier", _params, socket) do
    cursor = socket.assigns.before_entry_id

    if is_nil(cursor) do
      {:noreply, socket}
    else
      sid = socket.assigns.session_id
      cid = socket.assigns.conversation_id

      case Backend.scan_entries(sid, cid, %{"order" => "desc", "cursor" => cursor, "limit" => 50}) do
        {:ok, %{items: items, next_cursor: next_cursor}} ->
          ascending = Enum.reverse(items)

          {older_entries, next_t} =
            Transcript.prepend_older_page(socket.assigns.transcript, ascending, next_cursor)

          socket =
            socket
            |> stream(:entries, Enum.reverse(older_entries), at: 0)
            |> assign(:transcript, next_t)
            |> assign(
              before_entry_id: next_t.reducer.before_entry_id,
              has_more: next_t.reducer.has_more
            )

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  @impl true
  def render(assigns) do
    ~H"""
    <div class={["session-shell", if(@drawer_open?, do: "drawer-open")]}>
      <aside class="session-sidebar" aria-label="Session navigation and config">
        <div class="sidebar-top">
          <.link navigate={~p"/"} class="btn btn-sm btn-ghost">← Workspaces</.link>
          <button
            type="button"
            class="btn btn-sm btn-ghost mobile-only"
            phx-click="toggle_drawer"
          >
            Close
          </button>
        </div>

        <div class="sidebar-section">
          <div class="section-title">Session</div>
          <div class="mono session-id-label">{@session_id}</div>
          <div :if={@session} class="muted mono session-cwd">
            {@session.env_id}: {@session.cwd}
          </div>
        </div>

        <div class="sidebar-section">
          <div class="section-title">Agent Config</div>
          <form id="agent-config-form" phx-change="configure" class="config-form">
            <label class="field-group">
              <span class="field-label">Model</span>
              <select id="model-select" name="model" class="input">
                <option
                  :for={model <- @models}
                  value={model.id}
                  selected={model.id == @agent["model"]}
                >
                  {model.name || model.id}
                </option>
              </select>
            </label>

            <label class="field-group">
              <span class="field-label">Thinking</span>
              <select id="thinking-select" name="thinking" class="input">
                <option
                  :for={level <- @thinking_levels}
                  value={level}
                  selected={level == (@agent["thinking"] || "medium")}
                >
                  {level}
                </option>
              </select>
            </label>
          </form>
        </div>

        <div class="sidebar-section">
          <div class="section-title">Conversations</div>
          <ul id="branches-list" class="branch-list">
            <li :for={conv <- @conversations}>
              <.link
                patch={~p"/sessions/#{@session_id}/conversations/#{conv.id}"}
                class={[
                  "branch-link mono",
                  if(to_string(conv.id) == @conversation_id, do: "is-active")
                ]}
              >
                <span>#{conv.id}</span>
                <span :if={conv.parent} class="muted">
                  from #{conv.parent.conversation_id}@#{conv.parent.at}
                </span>
              </.link>
            </li>
          </ul>
        </div>
      </aside>

      <div class="session-main">
        <header class="session-header">
          <div class="header-left">
            <button
              type="button"
              class="btn btn-sm mobile-only"
              phx-click="toggle_drawer"
            >
              Menu
            </button>
            <span class="mono header-sid">{@session_id}</span>
            <span class="badge mono">conv #{@conversation_id}</span>
            <span :if={!is_nil(@cursor_seq)} id="hdr-seq" class="badge mono">
              seq {@cursor_seq}
            </span>
            <span :if={usage_summary(@usage)} id="hdr-usage" class="badge mono">
              {usage_summary(@usage)}
            </span>
          </div>

          <div class="header-right">
            <button
              :if={@run_active?}
              id="stop-btn"
              type="button"
              class="btn btn-sm btn-danger"
              phx-click="abort"
            >
              Stop
            </button>
            <form action={~p"/logout"} method="post" class="inline-form">
              <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
              <button type="submit" class="btn btn-sm btn-ghost">Sign out</button>
            </form>
          </div>
        </header>

        <div
          :if={@error_banner}
          id="session-error-banner"
          role="alert"
          class="flash-banner flash-error"
        >
          <span>{@error_banner}</span>
          <button type="button" class="btn btn-sm btn-ghost" phx-click="dismiss_error">
            Dismiss
          </button>
        </div>

        <div id="transcript-scroll" class="transcript-scroll">
          <div :if={@has_more} class="load-earlier-wrap">
            <button
              id="load-earlier-btn"
              type="button"
              class="btn btn-sm"
              phx-click="load_earlier"
            >
              Load earlier
            </button>
          </div>

          <div id="entries-stream" phx-update="stream" class="entries-list">
            <article
              :for={{dom_id, entry} <- @streams.entries}
              id={dom_id}
              class={["entry-card", "entry-#{entry["kind"]}"]}
            >
              <header class="entry-header">
                <div class="entry-header-left">
                  <span class="role-label">{entry["kind"]}</span>
                  <span class="badge mono">#{entry["id"]}</span>
                  <span :if={entry["data"]["aborted"]} class="badge badge-warn">aborted</span>
                  <span :if={entry["kind"] == "tool_result"} class="badge mono">
                    {entry["data"]["tool_name"] || entry["data"]["name"] || "tool"}
                  </span>
                  <span
                    :if={
                      entry["kind"] == "tool_result" and
                        (entry["data"]["is_error"] || entry["data"]["error"])
                    }
                    class="badge badge-danger"
                  >
                    error
                  </span>
                </div>

                <button
                  type="button"
                  class="btn btn-sm btn-ghost"
                  phx-click="fork_entry"
                  phx-value-entry_id={entry["id"]}
                >
                  Fork here
                </button>
              </header>

              <div class="entry-body">
                <.entry_body entry={entry} />
              </div>
            </article>
          </div>

          <.live_region live={@ephemeral_live} inbox={@inbox} />
        </div>

        <form
          id="composer-form"
          phx-submit="submit"
          phx-change="composer_change"
          class="composer"
        >
          <textarea
            id="prompt-input"
            name="content"
            rows="2"
            placeholder="Message the agent… (Enter to send, Shift+Enter for newline)"
            phx-hook="ComposerDraft"
            data-session-id={@session_id}
            data-conversation-id={@conversation_id}
            class="composer-input"
          >{@composer_text}</textarea>

          <div class="composer-actions">
            <button
              :if={@run_active?}
              id="steer-btn"
              type="button"
              class="btn btn-warn"
              phx-click="steer"
            >
              Steer
            </button>
            <button id="send-btn" type="submit" class="btn btn-primary">Send</button>
          </div>
        </form>
      </div>
    </div>
    """
  end

  attr(:entry, :map, required: true)

  defp entry_body(assigns) do
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

  defp live_region(assigns) do
    live = assigns.live || %{}
    gen = Map.get(live, "generation")
    run = Map.get(live, "run")
    msg = if is_map(gen), do: Map.get(gen, "message") || gen, else: %{}
    {thinking, text} = extract_parts(msg)
    tools = normalize_live_tools(Map.get(live, "tools"))
    failure = Map.get(live, "run_failure") || Map.get(live, "compaction_failure")
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
          <strong>Run paused:</strong>
          <span>{format_failure(@failure)}</span>
        </div>
        <button
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

  defp load_initial(socket, session_id, cid) do
    case Backend.get_session_detail(session_id) do
      {:ok, detail} ->
        socket
        |> assign(
          session: detail.session,
          conversations: detail.conversations,
          tasks: detail.tasks
        )
        |> load_conversation(session_id, cid)

      {:error, :not_found} ->
        socket
        |> put_flash(:error, "Session not found")
        |> push_navigate(to: ~p"/")

      {:error, {:quarantined, reason}} ->
        socket
        |> put_flash(:error, "Session quarantined: #{inspect(reason)}")
        |> push_navigate(to: ~p"/")
    end
  end

  defp load_conversation(socket, session_id, cid) do
    if connected?(socket) do
      subscribe_and_apply(socket, session_id, cid)
    else
      load_disconnected_entries(socket, session_id, cid)
    end
  end

  defp subscribe_and_apply(socket, session_id, cid) do
    case Backend.subscribe_conversation(session_id, cid, self(), nil) do
      {:ok, {:snapshot, _seq, bin}} ->
        t0 = Transcript.new(session_id: session_id, conversation_id: cid)

        case Transcript.apply_snapshot(t0, bin) do
          {:ok, entries, next_t} ->
            socket
            |> assign(transcript: next_t, subscribed_cid: cid, error_banner: nil)
            |> assign(Transcript.compact_assigns(next_t))
            |> stream(:entries, entries, reset: true)

          {:error, reason} ->
            assign(socket, :error_banner, format_error(reason))
        end

      {:ok, {:replay, _frames}} ->
        load_disconnected_entries(socket, session_id, cid)

      {:error, reason} ->
        assign(socket, :error_banner, format_error(reason))
    end
  end

  defp load_disconnected_entries(socket, session_id, cid) do
    case Backend.scan_entries(session_id, cid, %{"order" => "desc", "limit" => 50}) do
      {:ok, %{items: items, next_cursor: next_cursor}} ->
        entries = items |> Enum.reverse() |> Enum.map(&Transcript.normalize_entry/1)

        socket
        |> assign(
          before_entry_id: next_cursor,
          has_more: not is_nil(next_cursor)
        )
        |> stream(:entries, entries, reset: true)

      {:error, reason} ->
        socket
        |> assign(:error_banner, format_error(reason))
        |> stream(:entries, [], reset: true)
    end
  end

  defp resnapshot(socket) do
    subscribe_and_apply(socket, socket.assigns.session_id, socket.assigns.conversation_id)
  end

  defp unsubscribe_current(socket) do
    sid = socket.assigns[:session_id]
    cid = socket.assigns[:subscribed_cid]

    if sid && cid do
      Backend.unsubscribe_conversation(sid, cid)
      assign(socket, :subscribed_cid, nil)
    else
      socket
    end
  end

  defp refresh_detail(socket) do
    case Backend.get_session_detail(socket.assigns.session_id) do
      {:ok, detail} ->
        assign(socket,
          session: detail.session,
          conversations: detail.conversations,
          tasks: detail.tasks
        )

      _ ->
        socket
    end
  end

  defp send_submit(socket, args, request_id, opts) do
    envelope = build_envelope(socket, "submit", args, request_id)

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} ->
        socket = assign(socket, :error_banner, nil)

        socket =
          if Keyword.get(opts, :clear_composer?, false) do
            socket
            |> assign(:composer_text, "")
            |> push_event("clear_draft", %{
              session_id: socket.assigns.session_id,
              conversation_id: socket.assigns.conversation_id
            })
          else
            socket
          end

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp build_envelope(socket, command, args, request_id) do
    cid_int = String.to_integer(socket.assigns.conversation_id)

    %{
      "version" => 1,
      "request_id" => non_empty(request_id) || generate_request_id(),
      "command" => command,
      "conversation_id" => cid_int,
      "args" => args
    }
  end

  defp generate_request_id do
    "hweb-" <> Base.url_encode64(:crypto.strong_rand_bytes(12), padding: false)
  end

  defp normalize_cid(nil), do: "1"
  defp normalize_cid(""), do: "1"

  defp normalize_cid(val) do
    case Integer.parse(to_string(val)) do
      {n, ""} when n > 0 -> Integer.to_string(n)
      _ -> "1"
    end
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
    failure["reason"] || failure["detail"] || failure["message"] || format_json(failure)
  end

  defp format_failure(other), do: inspect(other)

  defp usage_summary(usage) when is_map(usage) do
    input = usage["input_tokens"] || usage["input"] || 0
    output = usage["output_tokens"] || usage["output"] || 0
    total = usage["total_tokens"] || input + output

    if total == 0 and input == 0 and output == 0 do
      nil
    else
      "tokens: #{input} in / #{output} out"
    end
  end

  defp usage_summary(_), do: nil

  defp format_json(value) when is_binary(value), do: value

  defp format_json(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value)
  end

  defp non_empty(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp format_error({:bad_request, msg}), do: msg
  defp format_error({:conflict, msg}), do: msg
  defp format_error(:not_found), do: "Not found"
  defp format_error(other), do: inspect(other)
end
