defmodule HWeb.SessionLive do
  @moduledoc """
  LiveView for a running/resumed `H` session and conversation branch.

  Uses `Phoenix.LiveView.stream/4` for committed entries, stores only compact
  doc/cursor state, subscribes to `H.PubSub` on connected mount, reduces frames
  through `H.Transcript` (via `HWeb.Transcript`), resnapshots on sequence gaps,
  and updates only the live region on ephemeral streaming updates.
  """
  use HWeb, :live_view

  alias HWeb.{
    Backend,
    CatalogState,
    ConversationComponents,
    InboxComponents,
    Transcript,
    Workbench
  }

  @thinking_levels ~w(off minimal low medium high xhigh)

  @impl true
  def mount(%{"session_id" => session_id} = params, _session, socket) do
    cid = normalize_cid(params["conversation_id"])
    from_inbox? = params["from"] == "inbox"

    socket =
      socket
      |> assign(
        session_id: session_id,
        conversation_id: cid,
        from_inbox?: from_inbox?,
        subscribed_cid: nil,
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        catalog_groups: [],
        catalog_counts: CatalogState.counts([]),
        show_subsessions?: false,
        other_attention_count: 0,
        next_attention_session: nil,
        session: nil,
        session_parent: nil,
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
      |> load_catalog()
      |> load_initial(session_id, cid)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"session_id" => sid} = params, _uri, socket) do
    cid = normalize_cid(params["conversation_id"])

    from_inbox? =
      if Map.has_key?(params, "from") do
        params["from"] == "inbox"
      else
        socket.assigns.from_inbox?
      end

    socket = assign(socket, :from_inbox?, from_inbox?)

    cond do
      sid != socket.assigns.session_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> assign(session_id: sid, conversation_id: cid, drawer_open?: false)
         |> recompute_catalog_assigns()
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

    if socket.assigns[:catalog_subscribed?] do
      Backend.unsubscribe_sessions()
    end

    :ok
  end

  @impl true
  def handle_info({:catalog_frame, seq, json_bin}, socket) do
    case CatalogState.apply_frame(socket.assigns.catalog, seq, json_bin) do
      {:ok, next_catalog} ->
        {:noreply,
         socket
         |> assign(:catalog, next_catalog)
         |> recompute_catalog_assigns()}

      :stale ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, load_catalog(socket)}
    end
  end

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

  def handle_event("toggle_subsessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_subsessions?, not socket.assigns.show_subsessions?)
     |> recompute_catalog_assigns()}
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
                 to:
                   conversation_path(
                     socket.assigns.session_id,
                     new_cid,
                     socket.assigns.from_inbox?
                   )
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

  defp load_catalog(socket) do
    if connected?(socket) do
      case Backend.subscribe_sessions(self()) do
        {:ok, {:snapshot, seq, json_bin}} ->
          case CatalogState.apply_snapshot(CatalogState.new(), seq, json_bin) do
            {:ok, catalog} ->
              socket
              |> assign(catalog: catalog, catalog_subscribed?: true)
              |> recompute_catalog_assigns()

            {:error, _} ->
              assign(socket, :catalog_subscribed?, true)
          end

        _ ->
          load_catalog_disconnected(socket)
      end
    else
      load_catalog_disconnected(socket)
    end
  end

  defp load_catalog_disconnected(socket) do
    case Backend.list_sessions(%{}) do
      {:ok, sessions} ->
        socket
        |> assign(:catalog, CatalogState.from_list(sessions))
        |> recompute_catalog_assigns()

      _ ->
        recompute_catalog_assigns(socket)
    end
  end

  defp recompute_catalog_assigns(socket) do
    sessions = socket.assigns.catalog.sessions
    current_sid = socket.assigns.session_id
    show_subsessions? = socket.assigns.show_subsessions?
    counts = CatalogState.counts(sessions)
    groups = CatalogState.group_by_workspace(sessions, include_subsessions: show_subsessions?)
    next_attention = CatalogState.next_attention_session(sessions, current_sid)

    other_attention_count =
      Enum.count(sessions, fn s ->
        s.session_id != current_sid and CatalogState.needs_attention?(s)
      end)

    assign(socket,
      catalog_counts: counts,
      catalog_groups: groups,
      next_attention_session: next_attention,
      other_attention_count: other_attention_count,
      session_parent:
        resolve_session_parent(socket.assigns.session, socket.assigns.catalog, current_sid)
    )
  end

  defp conversation_path(session_id, conversation_id, true),
    do: ~p"/sessions/#{session_id}/conversations/#{conversation_id}?from=inbox"

  defp conversation_path(session_id, conversation_id, _false),
    do: ~p"/sessions/#{session_id}/conversations/#{conversation_id}"

  defp load_initial(socket, session_id, cid) do
    case Backend.get_session_detail(session_id) do
      {:ok, detail} ->
        socket
        |> assign(
          session: detail.session,
          session_parent:
            resolve_session_parent(detail.session, socket.assigns.catalog, session_id),
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
          session_parent:
            resolve_session_parent(
              detail.session,
              socket.assigns.catalog,
              socket.assigns.session_id
            ),
          conversations: detail.conversations,
          tasks: detail.tasks
        )

      _ ->
        socket
    end
  end

  defp resolve_session_parent(session, catalog, session_id) do
    raw_parent =
      cond do
        is_map(session) and not is_nil(session[:parent] || session["parent"]) ->
          session[:parent] || session["parent"]

        is_map(catalog) ->
          case Map.get(catalog.by_id, session_id) do
            %{parent: parent} when not is_nil(parent) -> parent
            _ -> nil
          end

        true ->
          nil
      end

    CatalogState.normalize_parent(raw_parent)
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
