defmodule HWeb.SessionLive do
  @moduledoc """
  LiveView for a running/resumed `H` session and conversation branch.

  Uses `Phoenix.LiveView.stream/4` for committed messages and activity groups,
  and retains compact boundary, doc and cursor state. Subscribes to `H.PubSub`
  on connected mount and resnapshots on sequence gaps.
  """
  use HWeb, :live_view

  alias HWeb.{
    Backend,
    CatalogState,
    ConversationComponents,
    InboxComponents,
    InboxFilter,
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
        inbox_filter: InboxFilter.from_params(params),
        filter_options: %{workspaces: [], tags: []},
        subscribed_cid: nil,
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        catalog_groups: [],
        catalog_counts: CatalogState.counts([]),
        other_attention_count: 0,
        next_attention_session: nil,
        session: nil,
        conversations: [],
        tasks: [],
        model_groups: Backend.list_models() |> Enum.group_by(& &1.provider),
        provider_filter: nil,
        thinking_levels: @thinking_levels,
        transcript: Transcript.new(session_id: session_id, conversation_id: cid),
        cursor_seq: nil,
        committed_docs: %{},
        ephemeral_live: %{},
        tail_activity: nil,
        inbox: [],
        agent: %{},
        usage: %{},
        before_entry_id: nil,
        has_more: false,
        run_active?: false,
        drawer_open?: false,
        composer_text: "",
        cwd_missing?: false,
        show_fork_picker?: false,
        picker_env_id: "host",
        picker_path: "",
        picker_parent_path: nil,
        picker_dirs: [],
        picker_error: nil,
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

    socket =
      assign(socket,
        from_inbox?: params["from"] == "inbox",
        inbox_filter: InboxFilter.from_params(params)
      )

    cond do
      sid != socket.assigns.session_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> assign(
           session_id: sid,
           conversation_id: cid,
           provider_filter: nil,
           drawer_open?: false,
           cwd_missing?: false,
           show_fork_picker?: false,
           picker_error: nil
         )
         |> recompute_catalog_assigns()
         |> load_initial(sid, cid)}

      cid != socket.assigns.conversation_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> assign(conversation_id: cid, provider_filter: nil)
         |> recompute_catalog_assigns()
         |> load_conversation(sid, cid)}

      true ->
        {:noreply, recompute_catalog_assigns(socket)}
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
        socket =
          socket
          |> assign(:catalog, next_catalog)
          |> sync_current_session_from_catalog()
          |> recompute_catalog_assigns()

        {:noreply, socket}

      :stale ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, load_catalog(socket)}
    end
  end

  def handle_info({:commit_frame, _seq, json}, socket) do
    case Transcript.apply_commit(socket.assigns.transcript, json) do
      {:ok, rows, next_t} ->
        {:noreply,
         socket
         |> stream(:entries, rows)
         |> apply_transcript(next_t)}

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

  def handle_event("filter_inbox", params, socket) do
    filter = InboxFilter.from_form(socket.assigns.inbox_filter, params)

    {:noreply,
     push_patch(socket,
       to:
         session_filter_path(
           socket.assigns.session_id,
           socket.assigns.conversation_id,
           socket.assigns.from_inbox?,
           filter
         ),
       replace: true
     )}
  end

  def handle_event("save_session_tags", %{"tags" => raw_tags}, socket) when is_binary(raw_tags) do
    tags = raw_tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    case Backend.triage_session(socket.assigns.session_id, %{"tags" => tags}) do
      {:ok, %{session: updated}} ->
        {:noreply,
         socket
         |> assign(error_banner: nil)
         |> apply_session_to_catalog(updated)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("save_session_tags", _params, socket), do: {:noreply, socket}

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_banner, nil)}
  end

  def handle_event("toggle_session_attention", _params, socket) do
    session = socket.assigns.session

    if is_nil(session) or session.status == "archived" do
      {:noreply, socket}
    else
      target = not (Map.get(session, :needs_attention, true) == true)

      case Backend.triage_session(socket.assigns.session_id, %{"needs_attention" => target}) do
        {:ok, %{session: updated}} ->
          {:noreply,
           socket
           |> assign(session: updated, error_banner: nil)
           |> apply_session_to_catalog(updated)}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  def handle_event("archive_current_session", _params, socket) do
    stop? = socket.assigns.run_active?

    case Backend.archive_session(socket.assigns.session_id, %{
           "archived" => true,
           "stop" => stop?
         }) do
      {:ok, _} ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> push_navigate(to: InboxFilter.inbox_path(socket.assigns.inbox_filter))}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("unarchive_current_session", _params, socket) do
    case Backend.archive_session(socket.assigns.session_id, %{"archived" => false}) do
      {:ok, %{session: updated}} ->
        {:noreply,
         socket
         |> assign(session: updated, error_banner: nil)
         |> apply_session_to_catalog(updated)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("open_fork_picker", _params, socket) do
    socket =
      socket
      |> assign(:show_fork_picker?, true)
      |> init_directory_picker(socket.assigns.session)

    {:noreply, socket}
  end

  def handle_event("close_fork_picker", _params, socket) do
    {:noreply, assign(socket, :show_fork_picker?, false)}
  end

  def handle_event("picker_browse", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, browse_picker(socket, socket.assigns.picker_env_id, path)}
  end

  def handle_event("picker_parent", _params, socket) do
    case socket.assigns.picker_parent_path do
      nil -> {:noreply, socket}
      parent -> {:noreply, browse_picker(socket, socket.assigns.picker_env_id, parent)}
    end
  end

  def handle_event("picker_go", %{"path" => path}, socket) when is_binary(path) do
    {:noreply, browse_picker(socket, socket.assigns.picker_env_id, String.trim(path))}
  end

  def handle_event("picker_go", _params, socket), do: {:noreply, socket}

  def handle_event("fork_to_directory", params, socket) do
    cwd = non_empty(params["cwd"]) || non_empty(socket.assigns.picker_path)

    if is_nil(cwd) do
      {:noreply, assign(socket, :picker_error, "Select an existing directory first.")}
    else
      fork_params =
        %{
          "cwd" => cwd,
          "env_id" => socket.assigns.picker_env_id,
          "conversation_id" => socket.assigns.conversation_id
        }

      case Backend.fork_session(socket.assigns.session_id, fork_params) do
        {:ok, %{session: new_session}} ->
          new_sid = new_session[:session_id] || new_session["session_id"]

          {:noreply,
           socket
           |> unsubscribe_current()
           |> push_navigate(to: InboxFilter.session_path(new_sid, socket.assigns.inbox_filter))}

        {:error, reason} ->
          {:noreply, assign(socket, :picker_error, format_error(reason))}
      end
    end
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

  def handle_event("workspace_wait", params, socket) do
    args = Map.take(params, ["action", "task_id", "lease_id"])
    envelope = build_envelope(socket, "workspace_wait", args, params["request_id"])

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} -> {:noreply, assign(socket, :error_banner, nil)}
      {:error, reason} -> {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("select_provider", %{"provider" => provider}, socket)
      when is_binary(provider) do
    if is_map_key(socket.assigns.model_groups, provider) do
      {:noreply, assign(socket, :provider_filter, provider)}
    else
      {:noreply, socket}
    end
  end

  def handle_event("configure", params, socket) do
    groups = socket.assigns.model_groups
    current = socket.assigns.agent["model"]
    provider = socket.assigns.provider_filter || model_provider(groups, current)
    models = groups[provider] || []

    args =
      case params["_target"] do
        ["model"] -> Map.take(params, ["model"])
        ["thinking"] -> Map.take(params, ["thinking"])
        nil -> Map.take(params, ["model", "thinking"])
        _ -> %{}
      end

    args =
      Map.reject(args, fn
        {"model", id} ->
          id == current or not Enum.any?(models, &(&1.id == id))

        {"thinking", level} ->
          level == socket.assigns.agent["thinking"] or level not in @thinking_levels
      end)

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
                   InboxFilter.session_path(
                     socket.assigns.session_id,
                     socket.assigns.inbox_filter,
                     socket.assigns.from_inbox?,
                     new_cid
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
          {rows, next_t} =
            Transcript.prepend_older_page(socket.assigns.transcript, items, next_cursor)

          {:noreply,
           socket
           |> stream(:entries, Enum.reverse(rows), at: 0)
           |> apply_transcript(next_t)}

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
    all_sessions = socket.assigns.catalog.sessions
    filter = socket.assigns.inbox_filter

    scoped = InboxFilter.scope(filter, all_sessions)
    sessions = CatalogState.filter_sessions(scoped, filter.mode)
    current_sid = socket.assigns.session_id
    counts = CatalogState.counts(sessions)

    sidebar_sessions =
      if filter.mode == "inbox" do
        Enum.filter(scoped, &(&1.session_id == current_sid or CatalogState.active_inbox?(&1)))
      else
        sessions
      end

    groups = CatalogState.group_by_workspace(sidebar_sessions)
    next_attention = CatalogState.next_attention_session(sessions, current_sid)

    other_attention_count =
      Enum.count(sessions, fn s ->
        s.session_id != current_sid and CatalogState.needs_attention?(s)
      end)

    assign(socket,
      catalog_counts: counts,
      catalog_groups: groups,
      filter_options: InboxFilter.options(filter, all_sessions),
      next_attention_session: next_attention,
      other_attention_count: other_attention_count
    )
  end

  defp apply_transcript(socket, transcript) do
    assigns = Transcript.compact_assigns(transcript)

    socket =
      if socket.assigns.agent["model"] != assigns.agent["model"],
        do: assign(socket, :provider_filter, nil),
        else: socket

    socket |> assign(:transcript, transcript) |> assign(assigns)
  end

  defp model_provider(groups, id) do
    Enum.find_value(groups, fn {provider, models} ->
      if Enum.any?(models, &(&1.id == id)), do: provider
    end) ||
      case id do
        model when is_binary(model) ->
          [provider | _] = String.split(model, [":", "/"], parts: 2)
          if is_map_key(groups, provider), do: provider

        _ ->
          nil
      end || groups |> Map.keys() |> Enum.min(fn -> nil end)
  end

  defp provider_label(provider, [model | _]) do
    model[:provider_name] ||
      case provider do
        "openai" -> "OpenAI"
        "openai_codex" -> "OpenAI Codex"
        "anthropic" -> "Anthropic"
        "google" -> "Google Gemini"
        "google_vertex" -> "Google Vertex AI"
        "deepseek" -> "DeepSeek"
        "openrouter" -> "OpenRouter"
        id -> id
      end
  end

  defp session_filter_path(sid, cid, from_inbox?, filter) do
    InboxFilter.session_path(sid, filter, from_inbox?, if(cid != "1", do: cid))
  end

  defp load_initial(socket, session_id, cid) do
    case Backend.get_session_detail(session_id) do
      {:ok, detail} ->
        session = detail.session

        cwd_missing? =
          session.status != "archived" and Map.get(session, :cwd_exists, true) == false

        socket =
          socket
          |> assign(
            session: session,
            conversations: detail.conversations,
            tasks: detail.tasks,
            cwd_missing?: cwd_missing?,
            show_fork_picker?: false
          )
          |> load_conversation(session_id, cid)

        if cwd_missing? do
          init_directory_picker(socket, session)
        else
          socket
        end

      {:error, :not_found} ->
        redirect_with_error(socket, "Session not found.")

      {:error, {:quarantined, reason}} ->
        redirect_with_error(socket, "Session quarantined: #{inspect(reason)}")

      {:error, :workspace_unavailable} ->
        redirect_with_error(socket, "Session workspace environment is currently unavailable.")

      {:error, :harness_unavailable} ->
        redirect_with_error(socket, "Session harness profile is currently unavailable.")

      {:error, reason} ->
        redirect_with_error(socket, "Unable to open session: #{format_error(reason)}")
    end
  end

  defp redirect_with_error(socket, message) do
    dest =
      if socket.assigns.from_inbox?,
        do: InboxFilter.inbox_path(socket.assigns.inbox_filter),
        else: ~p"/"

    socket
    |> put_flash(:error, message)
    |> push_navigate(to: dest)
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
            |> assign(subscribed_cid: cid, error_banner: nil)
            |> apply_transcript(next_t)
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
        {rows, next_t} =
          Transcript.prepend_older_page(
            Transcript.new(session_id: session_id, conversation_id: cid),
            items,
            next_cursor
          )

        socket
        |> apply_transcript(next_t)
        |> stream(:entries, rows, reset: true)

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
        socket =
          socket
          |> assign(:error_banner, nil)
          |> then(fn s ->
            if s.assigns.session && Map.get(s.assigns.session, :archived) == true do
              refresh_detail(s)
            else
              s
            end
          end)

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

      {:error, {:conflict, "cwd_missing"}} ->
        socket =
          socket
          |> refresh_detail()
          |> assign(
            cwd_missing?: true,
            error_banner:
              "Working directory no longer exists. Select a directory below to fork and continue."
          )
          |> then(fn s -> init_directory_picker(s, s.assigns.session) end)

        {:noreply, socket}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp init_directory_picker(socket, nil), do: socket

  defp init_directory_picker(socket, session) do
    env_id = Map.get(session, :env_id) || "host"
    cwd = Map.get(session, :cwd) || ""

    case browse_nearest_existing(env_id, cwd) do
      {:ok, view} ->
        assign(socket,
          picker_env_id: view.env_id,
          picker_path: view.path,
          picker_parent_path: view.parent_path,
          picker_dirs: view.directories,
          picker_error: nil
        )

      {:error, reason} ->
        assign(socket,
          picker_env_id: env_id,
          picker_path: "",
          picker_parent_path: nil,
          picker_dirs: [],
          picker_error: format_error(reason)
        )
    end
  end

  defp browse_nearest_existing(env_id, cwd) when is_binary(cwd) and cwd != "" do
    cwd
    |> ancestor_paths()
    |> Enum.reduce_while({:error, :not_found}, fn candidate, _acc ->
      case Backend.browse_workspace(%{"env_id" => env_id, "path" => candidate}) do
        {:ok, view} -> {:halt, {:ok, view}}
        {:error, _} -> {:cont, {:error, :not_found}}
      end
    end)
    |> case do
      {:ok, view} -> {:ok, view}
      {:error, _} -> Backend.browse_workspace(%{"env_id" => env_id})
    end
  end

  defp browse_nearest_existing(env_id, _cwd) do
    Backend.browse_workspace(%{"env_id" => env_id})
  end

  defp ancestor_paths(path) do
    expanded = Path.expand(path)
    collect_ancestors(expanded, [])
  end

  defp collect_ancestors(path, acc) do
    parent = Path.dirname(path)

    if parent == path do
      Enum.reverse([path | acc])
    else
      collect_ancestors(parent, [path | acc])
    end
  end

  defp browse_picker(socket, env_id, path) do
    query = %{"env_id" => env_id} |> maybe_put("path", non_empty(path))

    case Backend.browse_workspace(query) do
      {:ok, view} ->
        assign(socket,
          picker_env_id: view.env_id,
          picker_path: view.path,
          picker_parent_path: view.parent_path,
          picker_dirs: view.directories,
          picker_error: nil
        )

      {:error, reason} ->
        assign(socket, :picker_error, format_error(reason))
    end
  end

  defp sync_current_session_from_catalog(socket) do
    case {socket.assigns.session,
          Map.get(socket.assigns.catalog.by_id, socket.assigns.session_id)} do
      {%{status: status} = current, %{session_id: _} = from_cat} when status != "archived" ->
        updated =
          current
          |> Map.put(:needs_attention, from_cat.needs_attention)
          |> Map.put(:archived, from_cat.archived)
          |> Map.put(:attention, from_cat.attention)
          |> Map.put(:cwd_exists, from_cat.cwd_exists)
          |> Map.put(:loaded, from_cat.loaded)

        assign(socket, :session, updated)

      _ ->
        socket
    end
  end

  defp apply_session_to_catalog(socket, raw_session) do
    normalized = CatalogState.normalize_session(raw_session)
    catalog = socket.assigns.catalog
    by_id = Map.put(catalog.by_id, normalized.session_id, normalized)

    next_catalog = %{
      catalog
      | by_id: by_id,
        sessions: Enum.sort_by(Map.values(by_id), &{&1.updated_at || 0, &1.session_id}, :desc)
    }

    socket
    |> assign(:catalog, next_catalog)
    |> recompute_catalog_assigns()
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
  defp format_error(:workspace_unavailable), do: "Workspace environment is unavailable."
  defp format_error(:harness_unavailable), do: "Harness profile is unavailable."
  defp format_error(other), do: inspect(other)
end
