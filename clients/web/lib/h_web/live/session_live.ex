defmodule HWeb.SessionLive do
  @moduledoc """
  LiveView for a running/resumed `H` session and conversation branch.

  Uses `Phoenix.LiveView.stream/4` for committed messages and activity groups,
  and retains compact boundary, doc and cursor state. Subscribes to `H.PubSub`
  on connected mount and resnapshots on sequence gaps.
  """
  use HWeb, :live_view

  alias HWeb.{
    Activity,
    Backend,
    CatalogState,
    ComposerAttachment,
    ConversationComponents,
    InboxComponents,
    InboxFilter,
    Layouts,
    SessionTree,
    SlashCommands,
    Transcript
  }

  @thinking_levels ~w(off minimal low medium high xhigh)

  @impl true
  def mount(%{"session_id" => session_id} = params, _session, socket) do
    cid = normalize_cid(params["conversation_id"])
    from_inbox? = params["from"] == "inbox"

    inbox_filter = InboxFilter.from_params(params)

    socket =
      socket
      |> assign(
        session_id: session_id,
        conversation_id: cid,
        from_inbox?: from_inbox?,
        inbox_filter: inbox_filter,
        subscribed_cid: nil,
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        folder_groups: [],
        folder_filter: %InboxFilter{},
        folder_subsessions_count: 0,
        show_folder_subsessions?: false,
        inbox_neighbors: nil,
        tag_error: nil,
        open_reply_by_default?: false,
        session: nil,
        session_parent: nil,
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
        tool_inspection: nil,
        inbox: [],
        agent: %{},
        usage: %{},
        turn_metrics: [],
        before_entry_id: nil,
        has_more: false,
        run_active?: false,
        extension_status: nil,
        composer_text: "",
        attachment_error: nil,
        cwd_missing?: false,
        show_fork_picker?: false,
        picker_env_id: "host",
        picker_path: "",
        picker_parent_path: nil,
        picker_dirs: [],
        picker_error: nil,
        error_banner: nil,
        info_banner: nil,
        fork_edit: nil,
        tree_raw: nil,
        tree_view: SessionTree.project(nil, current_conversation_id: cid),
        tree_filter: "default",
        tree_query: "",
        tree_folded_ids: MapSet.new(),
        tree_error: nil
      )
      |> allow_upload(:attachment, ComposerAttachment.upload_options())
      |> stream_configure(:entries, dom_id: &"entry-#{&1["id"]}")
      |> load_catalog()
      |> load_initial(session_id, cid)

    {:ok, socket}
  end

  @impl true
  def handle_params(%{"session_id" => sid} = params, _uri, socket) do
    cid = normalize_cid(params["conversation_id"])

    inbox_filter = InboxFilter.from_params(params)

    socket =
      assign(socket,
        from_inbox?: params["from"] == "inbox",
        inbox_filter: inbox_filter
      )

    cond do
      sid != socket.assigns.session_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> reset_composer()
         |> assign(
           session_id: sid,
           conversation_id: cid,
           show_folder_subsessions?: false,
           tag_error: nil,
           provider_filter: nil,
           cwd_missing?: false,
           show_fork_picker?: false,
           picker_error: nil,
           info_banner: nil,
           extension_status: nil,
           fork_edit: nil,
           tree_raw: nil,
           tree_view: SessionTree.project(nil, current_conversation_id: cid),
           tree_filter: "default",
           tree_query: "",
           tree_folded_ids: MapSet.new(),
           tree_error: nil
         )
         |> load_initial(sid, cid)}

      cid != socket.assigns.conversation_id ->
        {:noreply,
         socket
         |> unsubscribe_current()
         |> reset_composer()
         |> assign(
           conversation_id: cid,
           provider_filter: nil,
           info_banner: nil,
           extension_status: nil,
           fork_edit: nil
         )
         |> recompute_tree_view()
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
          |> assign_catalog(next_catalog)
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
         |> stream_transcript_rows(rows, next_t)
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
         socket
         |> stream_transcript_rows([], next_t)
         |> assign(
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
  def handle_event("toggle_folder_subsessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_folder_subsessions?, not socket.assigns.show_folder_subsessions?)
     |> recompute_catalog_assigns()}
  end

  def handle_event("new_session", _params, socket), do: new_session(socket, false)

  def handle_event("add_session_tags", %{"tags" => raw_tags}, socket) when is_binary(raw_tags) do
    new_tags =
      raw_tags |> String.split(",") |> Enum.map(&String.trim/1) |> Enum.reject(&(&1 == ""))

    tags = Enum.uniq(session_tags(socket.assigns) ++ new_tags)

    socket =
      case save_session_tags(socket, tags) do
        {:ok, socket} -> push_event(socket, "session_tags_added", %{value: raw_tags})
        {:error, socket} -> socket
      end

    {:noreply, socket}
  end

  def handle_event("remove_session_tag", %{"tag" => tag}, socket) when is_binary(tag) do
    {_result, socket} = save_session_tags(socket, List.delete(session_tags(socket.assigns), tag))
    {:noreply, socket}
  end

  def handle_event(event, _params, socket)
      when event in ["add_session_tags", "remove_session_tag"],
      do: {:noreply, socket}

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_banner, nil)}
  end

  def handle_event("dismiss_info", _params, socket) do
    {:noreply, assign(socket, :info_banner, nil)}
  end

  def handle_event("cancel_fork_edit", _params, socket) do
    {:noreply, cancel_fork_edit(socket)}
  end

  def handle_event("open_session_tree", params, socket) do
    filter =
      case params["filter"] do
        f when is_binary(f) and f != "" -> SessionTree.normalize_filter(f)
        _ -> socket.assigns.tree_filter
      end

    socket =
      socket
      |> assign(tree_filter: filter, tree_error: nil)
      |> load_session_tree()
      |> push_event("open_panel", %{id: "session-tree-panel"})

    {:noreply, socket}
  end

  def handle_event("tree_filter", %{"filter" => filter}, socket) when is_binary(filter) do
    socket =
      socket
      |> assign(:tree_filter, SessionTree.normalize_filter(filter))
      |> recompute_tree_view()

    {:noreply, socket}
  end

  def handle_event("tree_search", %{"query" => query}, socket) when is_binary(query) do
    socket =
      socket
      |> assign(:tree_query, query)
      |> recompute_tree_view()

    {:noreply, socket}
  end

  def handle_event("tree_toggle_fold", %{"entry_id" => entry_id}, socket)
      when is_binary(entry_id) do
    folded = socket.assigns.tree_folded_ids

    next_folded =
      if MapSet.member?(folded, entry_id),
        do: MapSet.delete(folded, entry_id),
        else: MapSet.put(folded, entry_id)

    socket =
      socket
      |> assign(:tree_folded_ids, next_folded)
      |> recompute_tree_view()

    {:noreply, socket}
  end

  def handle_event("tree_refresh", _params, socket) do
    {:noreply, load_session_tree(socket)}
  end

  def handle_event("tree_branch_at", %{"entry_id" => entry_id_str} = params, socket) do
    source_cid = normalize_cid(params["source_cid"] || socket.assigns.conversation_id)

    case Integer.parse(to_string(entry_id_str)) do
      {entry_id, ""} when entry_id > 0 ->
        envelope =
          build_envelope_for(
            source_cid,
            "fork",
            %{"at_entry_id" => entry_id},
            params["request_id"]
          )

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, receipt} ->
            new_cid = to_string(receipt[:conversation_id] || receipt["conversation_id"] || "")

            socket =
              socket
              |> refresh_detail()
              |> push_event("close_panel", %{id: "session-tree-panel"})

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
            {:noreply, assign(socket, :tree_error, format_error(reason))}
        end

      _ ->
        {:noreply, assign(socket, :tree_error, "Invalid entry ID for fork.")}
    end
  end

  def handle_event("tree_edit_user_step", %{"entry_id" => entry_id_str} = params, socket) do
    source_cid = normalize_cid(params["source_cid"] || socket.assigns.conversation_id)
    socket = begin_fork_edit(socket, to_string(entry_id_str), source_cid)

    socket =
      if socket.assigns.fork_edit do
        push_event(socket, "close_panel", %{id: "session-tree-panel"})
      else
        socket
      end

    {:noreply, socket}
  end

  def handle_event("complete_path", params, socket) do
    lookup_id = params["lookup_id"]
    kind = params["kind"] || "path"
    prefix = if is_binary(params["prefix"]), do: params["prefix"], else: ""
    target_id = params["target_id"] || "prompt-input"
    shell? = params["shell"] == true
    session = socket.assigns.session
    env_id = (session && Map.get(session, :env_id)) || socket.assigns.picker_env_id || "host"

    fallback_cwd =
      cond do
        kind == "picker_directory" and is_binary(socket.assigns.picker_path) and
            String.starts_with?(socket.assigns.picker_path, "/") ->
          socket.assigns.picker_path

        (session && Map.get(session, :cwd_exists, true)) and is_binary(session.cwd) and
            String.starts_with?(session.cwd, "/") ->
          session.cwd

        is_binary(socket.assigns.picker_path) and
            String.starts_with?(socket.assigns.picker_path, "/") ->
          socket.assigns.picker_path

        true ->
          "/"
      end

    items =
      case kind do
        k when k in ["directory", "picker_directory"] ->
          case SlashCommands.complete_directories(env_id, fallback_cwd, prefix) do
            {:ok, list} -> list
            _ -> []
          end

        "workspace_file" ->
          case SlashCommands.complete_session_files(socket.assigns.session_id, prefix) do
            {:ok, list} -> list
            _ -> []
          end

        _ ->
          case SlashCommands.complete_paths(env_id, fallback_cwd, prefix, shell?: shell?) do
            {:ok, list} -> list
            _ -> []
          end
      end

    {:noreply,
     push_event(socket, "completion_results", %{
       lookup_id: lookup_id,
       target_id: target_id,
       kind: kind,
       prefix: prefix,
       items: items
     })}
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

  def handle_event("composer_change", %{"content" => content} = params, socket)
      when is_binary(content) do
    socket = assign(socket, :composer_text, content)

    socket =
      if params["_target"] == ["attachment"],
        do: assign(socket, :attachment_error, nil),
        else: socket

    {:noreply, socket}
  end

  def handle_event("remove_attachment", %{"ref" => ref}, socket) do
    {:noreply, socket |> remove_attachment(ref) |> assign(:attachment_error, nil)}
  end

  def handle_event("submit", params, socket) do
    raw_text = if is_binary(params["content"]), do: params["content"], else: ""
    text = non_empty(raw_text) || ""
    steer? = params["mode"] == "steer"

    cond do
      params["destination"] != composer_destination(socket.assigns) ->
        {:noreply, socket}

      fork_edit = socket.assigns.fork_edit ->
        if String.trim(raw_text) == "/fork cancel" do
          {:noreply, cancel_fork_edit(socket)}
        else
          submit_fork_edit(socket, fork_edit, text, params["request_id"])
        end

      true ->
        case SlashCommands.parse_input(raw_text) do
          {:command, cmd, arg} when not steer? ->
            execute_slash_command(socket, cmd, arg, params["request_id"])

          {:unknown_command, cmd} when not steer? ->
            {:noreply,
             assign(socket,
               error_banner: "Unknown command #{cmd} · type / for commands",
               info_banner: nil,
               composer_text: raw_text
             )}

          {:user_shell, shell_cmd, include_in_context?} when not steer? ->
            execute_user_shell(socket, shell_cmd, include_in_context?, params["request_id"])

          {:message, clean_text} ->
            submit_message(socket, clean_text, steer?, params["request_id"])

          _ ->
            submit_message(socket, text, steer?, params["request_id"])
        end
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

  def handle_event("abort_task", %{"task-id" => task_id_raw} = params, socket) do
    abort_specific_task(socket, task_id_raw, params["request_id"], clear_composer?: false)
  end

  def handle_event("abort_task", %{"task_id" => task_id_raw} = params, socket) do
    abort_specific_task(socket, task_id_raw, params["request_id"], clear_composer?: false)
  end

  def handle_event("approve_tool", params, socket) do
    task_id_raw = params["task-id"] || params["task_id"]
    decision = params["decision"]
    reason = non_empty(params["reason"])

    case {parse_pos_int(task_id_raw), decision} do
      {{:ok, task_id}, d} when d in ["allow", "deny"] ->
        args =
          %{"task_id" => task_id, "decision" => d}
          |> maybe_put("reason", reason)

        envelope = build_envelope(socket, "approve_tool", args, params["request_id"])

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            {:noreply, assign(socket, :error_banner, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      _ ->
        {:noreply, assign(socket, :error_banner, "Invalid tool approval parameters.")}
    end
  end

  def handle_event("configure_approval_policy", params, socket) do
    raw = params["approval_policy"] || params["policy"] || ""

    case parse_approval_policy(raw) do
      {:ok, policy} ->
        envelope =
          build_envelope(
            socket,
            "configure",
            %{"approval_policy" => policy},
            params["request_id"]
          )

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            {:noreply, assign(socket, :error_banner, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error_banner, msg)}
    end
  end

  def handle_event("configure_budget", params, socket) do
    budget_res =
      if params["clear"] in [true, "true", "1"] do
        {:ok, nil}
      else
        parse_budget_params(params)
      end

    case budget_res do
      {:ok, budget} ->
        envelope =
          build_envelope(socket, "configure", %{"budget" => budget}, params["request_id"])

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            {:noreply, assign(socket, :error_banner, nil)}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error_banner, msg)}
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

  def handle_event("edit_entry", %{"entry_id" => entry_id}, socket) when is_binary(entry_id) do
    {:noreply, begin_fork_edit(socket, entry_id, socket.assigns.conversation_id)}
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

  def handle_event("inspect_tool", params, socket) do
    %{session_id: sid, conversation_id: cid, ephemeral_live: live} = socket.assigns
    inspection = Activity.inspect_tool(params, live, &fetch_transcript_entry(sid, cid, &1))

    {:noreply,
     socket
     |> assign(:tool_inspection, inspection)
     |> push_event("open_panel", %{id: "tool-inspection"})}
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
           |> stream_transcript_rows(Enum.reverse(rows), next_t, at: 0)
           |> apply_transcript(next_t)}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  defp new_session(socket, clear_draft?) do
    if socket.assigns.session && !socket.assigns.cwd_missing? do
      session = socket.assigns.session

      case Backend.create_session(%{"env_id" => session.env_id, "cwd" => session.cwd}) do
        {:ok, %{session: new_session}} ->
          sid = new_session[:session_id] || new_session["session_id"]
          socket = if clear_draft?, do: clear_composer_and_draft(socket), else: socket

          {:noreply,
           socket
           |> unsubscribe_current()
           |> push_navigate(
             to:
               InboxFilter.session_path(
                 sid,
                 socket.assigns.inbox_filter,
                 socket.assigns.from_inbox?
               )
           )}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    else
      {:noreply, assign(socket, :error_banner, "Session workspace unavailable.")}
    end
  end

  defp save_session_tags(socket, tags) do
    if tags == session_tags(socket.assigns) do
      {:ok, assign(socket, :tag_error, nil)}
    else
      case Backend.triage_session(socket.assigns.session_id, %{"tags" => tags}) do
        {:ok, %{session: updated}} ->
          {:ok, socket |> assign(tag_error: nil) |> apply_session_to_catalog(updated)}

        {:error, reason} ->
          {:error, assign(socket, :tag_error, format_error(reason))}
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
              |> assign_catalog(catalog)
              |> assign(:catalog_subscribed?, true)
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
        |> assign_catalog(CatalogState.from_list(sessions))
        |> recompute_catalog_assigns()

      _ ->
        recompute_catalog_assigns(socket)
    end
  end

  defp recompute_catalog_assigns(socket) do
    %{catalog: catalog, inbox_filter: filter, session_id: sid} = socket.assigns
    current = catalog.by_id[sid] || socket.assigns.session
    workspace = if current, do: {current.env_id, current.cwd}
    include_subsessions? = socket.assigns.show_folder_subsessions?

    folder_sessions =
      Enum.filter(catalog.sessions, fn s ->
        workspace == {s.env_id, s.cwd} and (s.session_id == sid or not s.archived)
      end)

    folder_groups =
      CatalogState.group_by_workspace(folder_sessions, include_subsessions: include_subsessions?)

    neighbors =
      if socket.assigns.from_inbox? do
        opts = [include_subsessions: filter.subsessions]

        catalog.sessions
        |> then(&InboxFilter.scope(filter, &1))
        |> CatalogState.filter_sessions(filter.mode, "", opts)
        |> CatalogState.group_by_workspace(opts)
        |> Enum.flat_map(&inbox_order(&1.sessions))
        |> inbox_neighbors(sid)
      end

    assign(socket,
      folder_groups: folder_groups,
      folder_filter: %InboxFilter{workspace: workspace, subsessions: include_subsessions?},
      folder_subsessions_count: CatalogState.subsession_count(folder_sessions),
      inbox_neighbors: neighbors,
      session_parent: resolve_session_parent(socket.assigns.session, catalog, sid)
    )
  end

  defp inbox_order(sessions), do: Enum.flat_map(sessions, &[&1 | inbox_order(&1.children)])

  defp inbox_neighbors(sessions, sid) do
    case Enum.split_while(sessions, &(&1.session_id != sid)) do
      {before, [_current | after_current]} ->
        %{previous: List.last(before), next: List.first(after_current)}

      _ ->
        nil
    end
  end

  defp session_tags(%{catalog: catalog, session: session, session_id: sid}) do
    Map.get(catalog.by_id[sid] || session || %{}, :tags, [])
  end

  # Streams don't retain rendered rows. Reinsert only changed cards, and drop
  # a provisional result-only card if its earlier call is loaded later.
  defp stream_transcript_rows(socket, rows, transcript, opts \\ []) do
    before = socket.assigns.transcript.subagent_rows
    current = transcript.subagent_rows

    case {before, current} do
      {same, same} ->
        stream(socket, :entries, rows, opts)

      _ ->
        before
        |> Enum.reduce(socket, fn {id, previous}, acc ->
          case Map.fetch(current, id) do
            :error -> stream_delete(acc, :entries, previous)
            {:ok, ^previous} -> acc
            {:ok, row} -> stream_insert(acc, :entries, row, update_only: true)
          end
        end)
        |> stream(:entries, rows, opts)
    end
  end

  defp assign_catalog(socket, catalog) do
    previous = socket.assigns.catalog.by_id
    socket = assign(socket, :catalog, catalog)

    Enum.reduce(socket.assigns.transcript.subagent_rows, socket, fn {_, row}, acc ->
      child_id = row["subagent"].child_id
      old = previous[child_id]
      new = catalog.by_id[child_id]

      old_sig =
        old &&
          {old.title, old.attention, old.activity_kind, old.activity_label, old.needs_attention}

      new_sig =
        new &&
          {new.title, new.attention, new.activity_kind, new.activity_label, new.needs_attention}

      if old_sig != new_sig do
        stream_insert(acc, :entries, row, update_only: true)
      else
        acc
      end
    end)
  end

  defp apply_transcript(socket, transcript) do
    assigns = Transcript.compact_assigns(transcript)
    model_changed? = socket.assigns.agent["model"] != assigns.agent["model"]

    socket =
      if model_changed?,
        do: assign(socket, :provider_filter, nil),
        else: socket

    socket = socket |> assign(:transcript, transcript) |> assign(assigns)

    if model_changed? or is_nil(socket.assigns.extension_status) do
      refresh_extension_status(socket)
    else
      socket
    end
  end

  defp profile(session, false, groups, provider_filter, agent) when not is_nil(session) do
    if session.status != "archived" and Map.get(session, :cwd_exists, true) do
      active_id = agent["model"]
      active_provider = model_provider(groups, active_id)
      provider = provider_filter || active_provider
      active = Enum.find(groups[active_provider] || [], &(&1.id == active_id))
      thinking = agent["thinking"] || "medium"
      model_label = (active && active.name) || active_id || "Choose model"

      provider_label =
        if active, do: provider_label(active_provider, [active]), else: "No registered provider"

      %{
        label: "#{model_label} · #{thinking_label(thinking)} reasoning",
        model_label: model_label,
        provider_label: provider_label,
        provider: provider,
        models: groups[provider] || [],
        current_visible?: not is_nil(active) and active_provider == provider,
        unavailable_reason: active && active[:unavailable_reason],
        thinking: thinking,
        thinking_label: thinking_label(thinking)
      }
    end
  end

  defp profile(_, _, _, _, _), do: nil

  defp thinking_label("xhigh"), do: "Extra high"
  defp thinking_label(level), do: String.capitalize(level)

  defp session_title(%{title: title}, _) when is_binary(title) and title != "", do: title
  defp session_title(%{cwd: cwd}, _) when is_binary(cwd) and cwd != "", do: Path.basename(cwd)
  defp session_title(_, sid), do: sid

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
            session_parent: resolve_session_parent(session, socket.assigns.catalog, session_id),
            conversations: detail.conversations,
            tasks: detail.tasks,
            cwd_missing?: cwd_missing?,
            show_fork_picker?: false
          )
          |> load_conversation(session_id, cid)
          |> recompute_catalog_assigns()

        socket =
          assign(
            socket,
            :open_reply_by_default?,
            MapSet.size(socket.assigns.transcript.reducer.entry_ids) == 0
          )

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
    socket =
      socket
      |> assign(:tool_inspection, nil)
      |> push_event("close_panel", %{id: "tool-inspection"})

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

  defp composer_destination(%{session_id: sid, conversation_id: cid, fork_edit: %{entry_id: id}}),
    do: "#{sid}:#{cid}:edit:#{id}"

  defp composer_destination(%{session_id: sid, conversation_id: cid}), do: "#{sid}:#{cid}"

  defp composer_content(socket, text) do
    upload = socket.assigns.uploads.attachment
    active = Enum.reject(upload.entries, & &1.cancelled?)

    cond do
      active == [] and upload.errors == [] ->
        {:ok, text}

      upload.errors != [] or not Enum.all?(active, &(&1.valid? and &1.done?)) ->
        {:error, "Finish uploading or remove invalid attachments before sending."}

      true ->
        # Keep uploads available if the daemon rejects the message (e.g. an idle
        # steer). Upload channels clean up their temp files on removal/reset.
        uploaded =
          Enum.map(active, fn entry ->
            consume_uploaded_entry(socket, entry, fn meta -> {:postpone, {meta, entry}} end)
          end)

        with {:ok, blocks} <- ComposerAttachment.read_all(uploaded) do
          prefix = if text == "", do: [], else: [%{"type" => "text", "text" => text}]
          {:ok, prefix ++ blocks}
        end
    end
  end

  defp remove_attachment(socket, ref) do
    if Enum.any?(socket.assigns.uploads.attachment.entries, &(&1.ref == ref and !&1.cancelled?)),
      do: cancel_upload(socket, :attachment, ref),
      else: socket
  end

  defp reset_composer(socket) do
    Enum.reduce(socket.assigns.uploads.attachment.entries, socket, fn entry, acc ->
      remove_attachment(acc, entry.ref)
    end)
    |> assign(composer_text: "", attachment_error: nil)
  end

  defp upload_error(:too_large), do: "Choose an image up to 2 MiB or a text file up to 64 KiB."

  defp upload_error(:too_many_files),
    do: "Attach up to #{ComposerAttachment.max_entries()} files at a time."

  defp upload_error(_), do: "Upload failed. Remove the attachment and choose it again."

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
            |> reset_composer()
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
          |> Map.put(:activity_kind, from_cat.activity_kind)
          |> Map.put(:activity_label, from_cat.activity_label)
          |> Map.put(:next_wake_at, from_cat.next_wake_at)
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
    |> assign_catalog(next_catalog)
    |> recompute_catalog_assigns()
  end

  defp build_envelope(socket, command, args, request_id) do
    build_envelope_for(socket.assigns.conversation_id, command, args, request_id)
  end

  defp build_envelope_for(conversation_id, command, args, request_id) do
    cid_int = String.to_integer(normalize_cid(conversation_id))

    %{
      "version" => 1,
      "request_id" => non_empty(request_id) || generate_request_id(),
      "command" => command,
      "conversation_id" => cid_int,
      "args" => args
    }
  end

  defp clear_composer_and_draft(socket, opts \\ []) do
    socket
    |> reset_composer()
    |> push_event("clear_draft", %{
      session_id: socket.assigns.session_id,
      conversation_id: socket.assigns.conversation_id,
      preserve_saved: Keyword.get(opts, :preserve_saved?, false)
    })
  end

  defp set_composer_draft(socket, text, opts \\ []) do
    open_reply? = Keyword.get(opts, :open_reply?, false)

    socket
    |> assign(:composer_text, text)
    |> push_event("set_draft", %{
      session_id: socket.assigns.session_id,
      conversation_id: socket.assigns.conversation_id,
      text: text,
      open_reply: open_reply?,
      fork_edit: socket.assigns.fork_edit != nil
    })
  end

  defp load_session_tree(socket) do
    case Backend.get_session_tree(socket.assigns.session_id) do
      {:ok, tree} ->
        socket
        |> assign(tree_raw: tree, tree_error: nil)
        |> recompute_tree_view()

      {:error, reason} ->
        assign(socket, :tree_error, format_error(reason))
    end
  end

  defp recompute_tree_view(socket) do
    view =
      SessionTree.project(socket.assigns.tree_raw,
        current_conversation_id: socket.assigns.conversation_id,
        filter: socket.assigns.tree_filter,
        query: socket.assigns.tree_query,
        folded_ids: socket.assigns.tree_folded_ids
      )

    assign(socket, :tree_view, view)
  end

  defp submit_message(socket, text, steer?, request_id) do
    with {:ok, content} <- composer_content(socket, text) do
      if content == "" do
        {:noreply, socket}
      else
        args = %{
          "type" => "input",
          "content" => content,
          "when_busy" => if(steer?, do: "steer", else: "follow_up"),
          "when_idle" => if(steer?, do: "reject", else: "start")
        }

        send_submit(socket, args, request_id, clear_composer?: true)
      end
    else
      {:error, message} -> {:noreply, assign(socket, :attachment_error, message)}
    end
  end

  defp submit_fork_edit(socket, fork_edit, text, request_id) do
    with {:ok, content} <- composer_content(socket, text) do
      content =
        case fork_edit.images do
          [] -> content
          images when is_list(content) -> content ++ images
          images when content == "" -> images
          images -> [%{"type" => "text", "text" => content} | images]
        end

      if content == "" do
        {:noreply, socket}
      else
        if is_nil(fork_edit.predecessor_id) do
          # Root prompt edit: create a new session in the same workspace and submit there.
          session = socket.assigns.session
          env_id = (session && session.env_id) || "host"
          cwd = (session && session.cwd) || "/"
          agent = socket.assigns.agent

          create_params =
            %{"env_id" => env_id, "cwd" => cwd}
            |> maybe_put(
              "agent",
              if(is_map(agent) and map_size(agent) > 0,
                do: Map.take(agent, ["model", "thinking"]),
                else: nil
              )
            )

          case Backend.create_session(create_params) do
            {:ok, %{session: new_session}} ->
              new_sid = new_session[:session_id] || new_session["session_id"]

              envelope =
                build_envelope_for(
                  "1",
                  "submit",
                  %{
                    "type" => "input",
                    "content" => content,
                    "when_busy" => "follow_up",
                    "when_idle" => "start"
                  },
                  request_id
                )

              case Backend.execute_command(new_sid, envelope) do
                {:ok, _} ->
                  {:noreply,
                   socket
                   |> assign(fork_edit: nil, error_banner: nil, info_banner: nil)
                   |> clear_composer_and_draft(preserve_saved?: true)
                   |> unsubscribe_current()
                   |> push_navigate(
                     to:
                       InboxFilter.session_path(
                         new_sid,
                         socket.assigns.inbox_filter,
                         socket.assigns.from_inbox?
                       )
                   )}

                {:error, reason} ->
                  {:noreply, assign(socket, :error_banner, format_error(reason))}
              end

            {:error, reason} ->
              {:noreply, assign(socket, :error_banner, format_error(reason))}
          end
        else
          pred_int = String.to_integer(fork_edit.predecessor_id)

          args = %{"at_entry_id" => pred_int, "content" => content}

          envelope =
            build_envelope_for(fork_edit.source_cid, "fork_and_submit", args, request_id)

          case Backend.execute_command(socket.assigns.session_id, envelope) do
            {:ok, receipt} ->
              new_cid = to_string(receipt[:conversation_id] || receipt["conversation_id"] || "")

              socket =
                socket
                |> assign(fork_edit: nil, error_banner: nil, info_banner: nil)
                |> clear_composer_and_draft(preserve_saved?: true)
                |> refresh_detail()

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
        end
      end
    else
      {:error, message} -> {:noreply, assign(socket, :attachment_error, message)}
    end
  end

  defp begin_fork_edit(socket, entry_id_str, source_cid) do
    session = socket.assigns.session

    with true <- session != nil and session.status != "archived",
         {:ok, items} <- scan_through_entry(socket.assigns.session_id, source_cid, entry_id_str),
         [%{"id" => ^entry_id_str, "kind" => "user", "data" => data} | predecessors] <- items do
      full_text = extract_entry_plain_text(data) || ""
      previous_edit = socket.assigns.fork_edit

      fork_edit = %{
        entry_id: entry_id_str,
        predecessor_id: List.first(predecessors, %{})["id"],
        source_cid: source_cid,
        saved_draft:
          if(previous_edit, do: previous_edit.saved_draft, else: socket.assigns.composer_text),
        images: Enum.filter(List.wrap(data["content"]), &match?(%{"type" => "image"}, &1))
      }

      socket
      |> assign(fork_edit: fork_edit, error_banner: nil, info_banner: nil)
      |> set_composer_draft(full_text, open_reply?: true)
    else
      false -> assign(socket, :error_banner, "Cannot fork-edit an archived session.")
      {:error, reason} -> assign(socket, :error_banner, format_error(reason))
      _ -> assign(socket, :error_banner, "User prompt ##{entry_id_str} not found.")
    end
  end

  # The visible predecessor determines the cut. Read both entries together
  # rather than relying on a cached or truncated session-wide tree.
  defp scan_through_entry(session_id, cid, entry_id) do
    case Integer.parse(entry_id) do
      {id, ""} when id > 0 ->
        case Backend.scan_entries(session_id, cid, %{
               "order" => "desc",
               "cursor" => Integer.to_string(id + 1),
               "limit" => 2
             }) do
          {:ok, %{items: items}} -> {:ok, Enum.map(items, &Transcript.normalize_entry/1)}
          {:error, _} = error -> error
        end

      _ ->
        {:ok, []}
    end
  end

  defp cancel_fork_edit(socket) do
    case socket.assigns.fork_edit do
      nil ->
        socket

      %{saved_draft: saved} ->
        socket
        |> assign(fork_edit: nil, info_banner: "Fork edit cancelled.")
        |> set_composer_draft(saved || "")
    end
  end

  defp fetch_transcript_entry(session_id, cid, entry_id_str) when is_binary(entry_id_str) do
    with {id, ""} when id > 0 <- Integer.parse(entry_id_str),
         {:ok, %{items: [entry]}} <-
           Backend.scan_entries(session_id, cid, %{
             "order" => "desc",
             "cursor" => Integer.to_string(id + 1),
             "limit" => 1
           }),
         %{"id" => ^entry_id_str} = normalized <- Transcript.normalize_entry(entry) do
      normalized
    else
      _ -> nil
    end
  end

  defp fetch_transcript_entry(_session_id, _cid, _entry_id), do: nil

  defp extract_entry_plain_text(data) when is_map(data) do
    case data["content"] || data[:content] do
      text when is_binary(text) ->
        text

      blocks when is_list(blocks) ->
        blocks
        |> Enum.flat_map(fn
          b when is_binary(b) -> [b]
          %{"type" => "text", "text" => t} when is_binary(t) -> [t]
          %{type: "text", text: t} when is_binary(t) -> [t]
          %{"text" => t} when is_binary(t) -> [t]
          _ -> []
        end)
        |> Enum.join("\n")

      _ ->
        nil
    end
  end

  defp extract_entry_plain_text(_), do: nil

  defp execute_user_shell(socket, shell_cmd, include_in_context?, request_id) do
    seq = socket.assigns.cursor_seq

    if is_nil(seq) do
      {:noreply,
       assign(
         socket,
         :error_banner,
         "Not synchronized; wait for snapshot before running shell command."
       )}
    else
      args = %{
        "command" => shell_cmd,
        "include_in_context" => include_in_context?,
        "expected_seq" => seq
      }

      envelope = build_envelope(socket, "user_shell", args, request_id)

      case Backend.execute_command(socket.assigns.session_id, envelope) do
        {:ok, _receipt} ->
          {:noreply,
           socket
           |> assign(error_banner: nil, info_banner: nil)
           |> clear_composer_and_draft()}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  defp execute_slash_command(socket, "/help", _arg, _request_id) do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil)
     |> clear_composer_and_draft()
     |> push_event("open_panel", %{id: "slash-commands-help"})}
  end

  defp execute_slash_command(socket, cmd, _arg, _request_id) when cmd in ["/tree", "/branches"] do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil, tree_error: nil)
     |> clear_composer_and_draft()
     |> load_session_tree()
     |> push_event("open_panel", %{id: "session-tree-panel"})}
  end

  defp execute_slash_command(socket, "/conv", arg, _request_id) do
    clean = String.trim_leading(arg, "#")

    case Integer.parse(clean) do
      {n, ""} when n > 0 ->
        target_cid = Integer.to_string(n)

        {:noreply,
         socket
         |> assign(error_banner: nil, info_banner: nil)
         |> clear_composer_and_draft()
         |> push_patch(
           to:
             InboxFilter.session_path(
               socket.assigns.session_id,
               socket.assigns.inbox_filter,
               socket.assigns.from_inbox?,
               target_cid
             )
         )}

      _ ->
        {:noreply, assign(socket, :error_banner, "Usage: /conv <id>")}
    end
  end

  defp execute_slash_command(socket, "/branch", "", request_id) do
    case latest_visible_entry_id(socket) do
      nil ->
        {:noreply, assign(socket, :error_banner, "No visible entries to branch from.")}

      entry_id ->
        execute_slash_command(socket, "/branch", to_string(entry_id), request_id)
    end
  end

  defp execute_slash_command(socket, "/branch", arg, request_id) do
    clean = String.trim_leading(arg, "#")

    case Integer.parse(clean) do
      {entry_id, ""} when entry_id > 0 ->
        envelope = build_envelope(socket, "fork", %{"at_entry_id" => entry_id}, request_id)

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, receipt} ->
            new_cid = to_string(receipt[:conversation_id] || receipt["conversation_id"] || "")

            socket =
              socket
              |> assign(error_banner: nil, info_banner: nil)
              |> clear_composer_and_draft()
              |> refresh_detail()

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
        {:noreply, assign(socket, :error_banner, "Usage: /branch [<entry_id>]")}
    end
  end

  defp execute_slash_command(socket, "/fork", "", _request_id) do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil, tree_filter: "user-only", tree_error: nil)
     |> clear_composer_and_draft()
     |> load_session_tree()
     |> push_event("open_panel", %{id: "session-tree-panel"})}
  end

  defp execute_slash_command(socket, "/fork", arg, _request_id) do
    if String.downcase(arg) == "cancel" do
      if socket.assigns.fork_edit do
        {:noreply, cancel_fork_edit(socket)}
      else
        {:noreply, assign(socket, :info_banner, "No active fork-edit to cancel.")}
      end
    else
      clean = String.trim_leading(arg, "#")

      case Integer.parse(clean) do
        {n, ""} when n > 0 ->
          {:noreply,
           begin_fork_edit(socket, Integer.to_string(n), socket.assigns.conversation_id)}

        _ ->
          {:noreply, assign(socket, :error_banner, "Usage: /fork [<user_entry_id> | cancel]")}
      end
    end
  end

  defp execute_slash_command(socket, "/cwd", "", _request_id) do
    session = socket.assigns.session

    msg =
      if session do
        "Workspace: #{session.env_id}:#{session.cwd}"
      else
        "Workspace unavailable."
      end

    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: msg)
     |> clear_composer_and_draft()}
  end

  defp execute_slash_command(socket, "/cwd", arg, _request_id) do
    session = socket.assigns.session
    env_id = (session && session.env_id) || "host"
    base_cwd = (session && session.cwd) || "/"

    case SlashCommands.resolve_cwd_input(arg, env_id, base_cwd) do
      {:ok, target_cwd} ->
        fork_params = %{
          "cwd" => target_cwd,
          "env_id" => env_id,
          "conversation_id" => socket.assigns.conversation_id
        }

        case Backend.fork_session(socket.assigns.session_id, fork_params) do
          {:ok, %{session: new_session}} ->
            new_sid = new_session[:session_id] || new_session["session_id"]

            {:noreply,
             socket
             |> clear_composer_and_draft()
             |> unsubscribe_current()
             |> push_navigate(to: InboxFilter.session_path(new_sid, socket.assigns.inbox_filter))}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error_banner, msg)}
    end
  end

  defp execute_slash_command(socket, "/new", _arg, _request_id), do: new_session(socket, true)

  defp execute_slash_command(socket, "/inbox", _arg, _request_id) do
    {:noreply,
     socket
     |> clear_composer_and_draft()
     |> unsubscribe_current()
     |> push_navigate(to: InboxFilter.inbox_path(socket.assigns.inbox_filter))}
  end

  defp execute_slash_command(socket, "/workspaces", _arg, _request_id) do
    {:noreply,
     socket
     |> clear_composer_and_draft()
     |> unsubscribe_current()
     |> push_navigate(to: ~p"/workspaces")}
  end

  defp execute_slash_command(socket, cmd, _arg, _request_id)
       when cmd in ["/resume", "/sessions"] do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil)
     |> clear_composer_and_draft()
     |> push_event("open_panel", %{id: "session-details"})}
  end

  defp execute_slash_command(socket, "/parent", _arg, _request_id) do
    case socket.assigns.session_parent do
      nil ->
        {:noreply,
         socket
         |> assign(error_banner: nil, info_banner: "This session has no parent session.")
         |> clear_composer_and_draft()}

      parent ->
        {:noreply,
         socket
         |> clear_composer_and_draft()
         |> unsubscribe_current()
         |> push_navigate(
           to: ~p"/sessions/#{parent.session_id}/conversations/#{parent.conversation_id}"
         )}
    end
  end

  defp execute_slash_command(socket, cmd, _arg, _request_id) when cmd in ["/review", "/files"] do
    {:noreply,
     socket
     |> clear_composer_and_draft()
     |> unsubscribe_current()
     |> push_navigate(
       to:
         InboxFilter.review_path(
           socket.assigns.session_id,
           socket.assigns.inbox_filter,
           socket.assigns.from_inbox?,
           socket.assigns.conversation_id
         )
     )}
  end

  defp execute_slash_command(socket, "/model", "", _request_id) do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil)
     |> clear_composer_and_draft()
     |> push_event("open_panel", %{id: "agent-options"})}
  end

  defp execute_slash_command(socket, "/model", model_id, request_id) do
    envelope = build_envelope(socket, "configure", %{"model" => model_id}, request_id)

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} ->
        {:noreply,
         socket
         |> assign(error_banner: nil, info_banner: "Model set to #{model_id}.")
         |> clear_composer_and_draft()}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp execute_slash_command(socket, "/thinking", "", _request_id) do
    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: nil)
     |> clear_composer_and_draft()
     |> push_event("open_panel", %{id: "agent-options"})}
  end

  defp execute_slash_command(socket, "/thinking", arg, request_id) do
    level = String.downcase(arg)

    if level in @thinking_levels do
      envelope = build_envelope(socket, "configure", %{"thinking" => level}, request_id)

      case Backend.execute_command(socket.assigns.session_id, envelope) do
        {:ok, _receipt} ->
          {:noreply,
           socket
           |> assign(error_banner: nil, info_banner: "Reasoning effort set to #{level}.")
           |> clear_composer_and_draft()}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    else
      {:noreply,
       assign(
         socket,
         :error_banner,
         "Invalid thinking level #{arg}. Use: #{Enum.join(@thinking_levels, ", ")}"
       )}
    end
  end

  defp execute_slash_command(socket, "/compact", arg, request_id) do
    seq = socket.assigns.cursor_seq

    if is_nil(seq) do
      {:noreply,
       assign(socket, :error_banner, "Not synchronized; wait for snapshot before /compact.")}
    else
      args = %{"expected_seq" => seq} |> maybe_put("instructions", non_empty(arg))
      envelope = build_envelope(socket, "compact", args, request_id)

      case Backend.execute_command(socket.assigns.session_id, envelope) do
        {:ok, _receipt} ->
          {:noreply,
           socket
           |> assign(error_banner: nil, info_banner: "Compaction requested.")
           |> clear_composer_and_draft()}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  defp execute_slash_command(socket, "/continue", _arg, request_id) do
    send_submit(socket, %{"type" => "continue"}, request_id, clear_composer?: true)
  end

  defp execute_slash_command(socket, "/abort", "", request_id) do
    envelope = build_envelope(socket, "abort", %{}, request_id)

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} ->
        {:noreply,
         socket
         |> assign(error_banner: nil, info_banner: "Abort requested.")
         |> clear_composer_and_draft()}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp execute_slash_command(socket, "/abort", arg, request_id) do
    abort_specific_task(socket, arg, request_id, clear_composer?: true)
  end

  defp execute_slash_command(socket, "/harness", _arg, _request_id) do
    socket = refresh_extension_status(socket)

    harness_id =
      (socket.assigns.session && Map.get(socket.assigns.session, :harness_id)) || "coding"

    ext_summary = format_extension_status_summary(socket.assigns.extension_status)

    msg =
      if ext_summary != "" do
        "Harness: #{harness_id} · #{ext_summary}"
      else
        "Harness: #{harness_id}"
      end

    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: msg)
     |> clear_composer_and_draft()}
  end

  defp execute_slash_command(socket, "/budget", "", _request_id) do
    budget = get_in(socket.assigns.agent, ["budget"])
    summary = format_budget_summary(budget)

    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: "Budget: #{summary}")
     |> clear_composer_and_draft()}
  end

  defp execute_slash_command(socket, "/budget", arg, request_id) do
    case parse_budget_slash_arg(arg) do
      {:ok, budget} ->
        envelope = build_envelope(socket, "configure", %{"budget" => budget}, request_id)

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            label =
              if is_nil(budget),
                do: "Budget cleared.",
                else: "Budget set: #{format_budget_summary(budget)}."

            {:noreply,
             socket
             |> assign(error_banner: nil, info_banner: label)
             |> clear_composer_and_draft()}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error_banner, msg)}
    end
  end

  defp execute_slash_command(socket, "/approve", arg, request_id) do
    handle_approval_slash_command(socket, "allow", arg, request_id)
  end

  defp execute_slash_command(socket, "/deny", arg, request_id) do
    handle_approval_slash_command(socket, "deny", arg, request_id)
  end

  defp execute_slash_command(socket, "/approval", "", _request_id) do
    policy = get_in(socket.assigns.agent, ["approval_policy"]) || "never"

    {:noreply,
     socket
     |> assign(
       error_banner: nil,
       info_banner: "Approval policy: #{format_approval_policy(policy)}"
     )
     |> clear_composer_and_draft()}
  end

  defp execute_slash_command(socket, "/approval", arg, request_id) do
    case parse_approval_policy(arg) do
      {:ok, policy} ->
        envelope = build_envelope(socket, "configure", %{"approval_policy" => policy}, request_id)

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            {:noreply,
             socket
             |> assign(
               error_banner: nil,
               info_banner: "Approval policy set to #{format_approval_policy(policy)}."
             )
             |> clear_composer_and_draft()}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      {:error, msg} ->
        {:noreply, assign(socket, :error_banner, msg)}
    end
  end

  defp execute_slash_command(socket, "/stop", _arg, _request_id) do
    case Backend.stop_session(socket.assigns.session_id, %{}) do
      {:ok, %{session: updated}} ->
        {:noreply,
         socket
         |> assign(
           session: updated,
           error_banner: nil,
           info_banner: "Stopped active session work."
         )
         |> apply_session_to_catalog(updated)
         |> clear_composer_and_draft()}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp execute_slash_command(socket, "/dequeue", _arg, request_id) do
    ids =
      socket.assigns.inbox
      |> Enum.map(fn item -> item["submission_id"] || item[:submission_id] end)
      |> Enum.flat_map(fn
        id when is_integer(id) and id > 0 ->
          [id]

        id when is_binary(id) ->
          case Integer.parse(id) do
            {n, ""} when n > 0 -> [n]
            _ -> []
          end

        _ ->
          []
      end)

    if ids == [] do
      {:noreply,
       socket
       |> assign(error_banner: nil, info_banner: "No queued prompts to withdraw.")
       |> clear_composer_and_draft()}
    else
      envelope = build_envelope(socket, "withdraw", %{"submission_ids" => ids}, request_id)

      case Backend.execute_command(socket.assigns.session_id, envelope) do
        {:ok, receipt} ->
          withdrawn = receipt[:withdrawn] || receipt["withdrawn"] || []

          restored =
            withdrawn
            |> Enum.map(fn item ->
              extract_entry_plain_text(%{"content" => item[:content] || item["content"]})
            end)
            |> Enum.reject(&(&1 in [nil, ""]))
            |> Enum.join("\n\n")

          socket =
            socket
            |> assign(error_banner: nil, info_banner: "Withdrew #{length(ids)} queued prompt(s).")

          socket =
            if restored != "" do
              set_composer_draft(socket, restored, open_reply?: true)
            else
              clear_composer_and_draft(socket)
            end

          {:noreply, socket}

        {:error, reason} ->
          {:noreply, assign(socket, :error_banner, format_error(reason))}
      end
    end
  end

  defp execute_slash_command(socket, "/name", "", _request_id) do
    title = session_title(socket.assigns.session, socket.assigns.session_id)

    {:noreply,
     socket
     |> assign(error_banner: nil, info_banner: "Session title: #{title}")
     |> clear_composer_and_draft()}
  end

  defp execute_slash_command(socket, "/name", title, request_id) do
    args =
      %{"title" => title}
      |> maybe_put("expected_seq", socket.assigns.cursor_seq)

    envelope = build_envelope(socket, "rename", args, request_id)

    case Backend.execute_command(socket.assigns.session_id, envelope) do
      {:ok, _receipt} ->
        {:noreply,
         socket
         |> refresh_detail()
         |> assign(error_banner: nil, info_banner: "Session renamed to \"#{title}\".")
         |> clear_composer_and_draft()}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  defp execute_slash_command(socket, "/attention", arg, _request_id) do
    session = socket.assigns.session

    if is_nil(session) or session.status == "archived" do
      {:noreply, assign(socket, :error_banner, "Archived sessions are read-only.")}
    else
      target =
        case String.downcase(arg) do
          "" -> {:ok, not (Map.get(session, :needs_attention, true) == true)}
          v when v in ["on", "true", "yes", "1"] -> {:ok, true}
          v when v in ["off", "false", "no", "0"] -> {:ok, false}
          _ -> :error
        end

      case target do
        {:ok, bool} ->
          case Backend.triage_session(socket.assigns.session_id, %{"needs_attention" => bool}) do
            {:ok, %{session: updated}} ->
              label = if bool, do: "marked for attention", else: "marked as read"

              {:noreply,
               socket
               |> assign(session: updated, error_banner: nil, info_banner: "Session #{label}.")
               |> apply_session_to_catalog(updated)
               |> clear_composer_and_draft()}

            {:error, reason} ->
              {:noreply, assign(socket, :error_banner, format_error(reason))}
          end

        :error ->
          {:noreply, assign(socket, :error_banner, "Usage: /attention [on|off]")}
      end
    end
  end

  defp execute_slash_command(socket, "/archive", arg, _request_id) do
    session = socket.assigns.session

    if is_nil(session) or session.status == "archived" do
      {:noreply, assign(socket, :error_banner, "Imported archives are read-only.")}
    else
      case String.downcase(arg) do
        v when v in ["off", "false", "unarchive", "restore"] ->
          case Backend.archive_session(socket.assigns.session_id, %{"archived" => false}) do
            {:ok, %{session: updated}} ->
              {:noreply,
               socket
               |> assign(
                 session: updated,
                 error_banner: nil,
                 info_banner: "Session restored from archive."
               )
               |> apply_session_to_catalog(updated)
               |> clear_composer_and_draft()}

            {:error, reason} ->
              {:noreply, assign(socket, :error_banner, format_error(reason))}
          end

        v when v in ["", "on", "true", "force", "stop"] ->
          stop? = v in ["force", "stop"]

          case Backend.archive_session(socket.assigns.session_id, %{
                 "archived" => true,
                 "stop" => stop?
               }) do
            {:ok, _} ->
              {:noreply,
               socket
               |> clear_composer_and_draft()
               |> unsubscribe_current()
               |> push_navigate(to: InboxFilter.inbox_path(socket.assigns.inbox_filter))}

            {:error, reason} ->
              {:noreply, assign(socket, :error_banner, format_error(reason))}
          end

        _ ->
          {:noreply, assign(socket, :error_banner, "Usage: /archive [force|off]")}
      end
    end
  end

  defp execute_slash_command(socket, "/steer", arg, request_id) do
    if arg == "" do
      {:noreply, assign(socket, :error_banner, "Usage: /steer <message>")}
    else
      submit_message(socket, arg, true, request_id)
    end
  end

  defp execute_slash_command(socket, "/follow-up", arg, request_id) do
    if arg == "" do
      {:noreply, assign(socket, :error_banner, "Usage: /follow-up <message>")}
    else
      submit_message(socket, arg, false, request_id)
    end
  end

  defp latest_visible_entry_id(socket) do
    case Backend.scan_entries(
           socket.assigns.session_id,
           socket.assigns.conversation_id,
           %{"order" => "desc", "limit" => 1}
         ) do
      {:ok, %{items: [latest | _]}} -> latest[:id] || latest["id"]
      _ -> nil
    end
  end

  defp completion_metadata_json(model_groups) do
    model_groups
    |> SlashCommands.client_metadata()
    |> Phoenix.json_library().encode!()
  end

  defp tree_kind_label("user"), do: "user"
  defp tree_kind_label("assistant"), do: "assistant"
  defp tree_kind_label("tool_result"), do: "tool"
  defp tree_kind_label("user_shell"), do: "shell"
  defp tree_kind_label("compaction"), do: "compact"
  defp tree_kind_label(other), do: other

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

  defp build_metrics_chart(metrics) when is_list(metrics) do
    points = Enum.take(metrics, -24)

    if points == [] do
      nil
    else
      count = length(points)
      left = 32.0
      right = 224.0
      top = 8.0
      bottom = 66.0
      plot_w = right - left
      plot_h = bottom - top

      max_tokens =
        points
        |> Enum.map(& &1.total_tokens)
        |> Enum.max(fn -> 1 end)
        |> max(1)

      tps_values =
        points
        |> Enum.map(& &1.tps)
        |> Enum.filter(&is_number/1)

      max_tps =
        case tps_values do
          [] -> 1.0
          vals -> max(Enum.max(vals), 1.0)
        end

      slot_w = plot_w / count
      bar_w = min(max(slot_w * 0.56, 3.0), 14.0)

      indexed =
        points
        |> Enum.with_index()
        |> Enum.map(fn {m, idx} ->
          cx = left + (idx + 0.5) * slot_w
          in_h = m.input_tokens / max_tokens * plot_h
          out_h = m.output_tokens / max_tokens * plot_h
          tot_h = min(in_h + out_h, plot_h)
          out_y = bottom - tot_h
          in_y = bottom - in_h

          tps_y =
            if is_number(m.tps) do
              bottom - min(m.tps / max_tps, 1.0) * plot_h
            end

          %{
            entry_id: m.entry_id,
            x: Float.round(cx - bar_w / 2, 2),
            cx: Float.round(cx, 2),
            bar_w: Float.round(bar_w, 2),
            in_y: Float.round(in_y, 2),
            in_h: Float.round(in_h, 2),
            out_y: Float.round(out_y, 2),
            out_h: Float.round(max(tot_h - in_h, 0.0), 2),
            tps: m.tps,
            tps_y: if(tps_y, do: Float.round(tps_y, 2)),
            input_tokens: m.input_tokens,
            output_tokens: m.output_tokens,
            total_tokens: m.total_tokens,
            duration_ms: m.duration_ms
          }
        end)

      line_points =
        indexed
        |> Enum.filter(&is_number(&1.tps_y))
        |> Enum.map_join(" ", fn p -> "#{p.cx},#{p.tps_y}" end)

      %{
        points: indexed,
        line_points: line_points,
        has_tps?: tps_values != [],
        max_tps_label: format_tps(max_tps),
        max_tokens_label: format_compact_tokens(max_tokens),
        latest_tps_label:
          case List.last(tps_values) do
            nil -> "—"
            val -> "#{format_tps(val)} tok/s"
          end,
        turns: count
      }
    end
  end

  defp build_metrics_chart(_), do: nil

  defp format_tps(val) when is_number(val) and val >= 100, do: "#{round(val)}"
  defp format_tps(val) when is_number(val), do: :erlang.float_to_binary(val * 1.0, decimals: 1)

  defp format_compact_tokens(n) when is_integer(n) and n >= 1_000_000 do
    "#{Float.round(n / 1_000_000, 1)}M"
  end

  defp format_compact_tokens(n) when is_integer(n) and n >= 1_000 do
    "#{Float.round(n / 1_000, 1)}k"
  end

  defp format_compact_tokens(n) when is_integer(n), do: Integer.to_string(n)

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

  defp abort_specific_task(socket, task_id_raw, request_id, opts) do
    case parse_pos_int(task_id_raw) do
      {:ok, task_id} ->
        envelope = build_envelope(socket, "abort", %{"task_id" => task_id}, request_id)

        case Backend.execute_command(socket.assigns.session_id, envelope) do
          {:ok, _receipt} ->
            socket = assign(socket, :error_banner, nil)

            socket =
              if Keyword.get(opts, :clear_composer?, false) do
                socket
                |> assign(:info_banner, "Abort requested for task ##{task_id}.")
                |> clear_composer_and_draft()
              else
                socket
              end

            {:noreply, socket}

          {:error, reason} ->
            {:noreply, assign(socket, :error_banner, format_error(reason))}
        end

      :error ->
        {:noreply, assign(socket, :error_banner, "Usage: /abort [<task_id>]")}
    end
  end

  defp handle_approval_slash_command(socket, decision, arg, request_id) do
    cmd_name = if decision == "allow", do: "/approve", else: "/deny"

    case String.split(String.trim(arg), ~r/\s+/, parts: 2) do
      [tid_str | rest] when tid_str != "" ->
        case parse_pos_int(tid_str) do
          {:ok, task_id} ->
            reason = rest |> List.first() |> non_empty()

            args =
              %{"task_id" => task_id, "decision" => decision}
              |> maybe_put("reason", reason)

            envelope = build_envelope(socket, "approve_tool", args, request_id)

            case Backend.execute_command(socket.assigns.session_id, envelope) do
              {:ok, _receipt} ->
                verb = if decision == "allow", do: "Approved", else: "Denied"

                {:noreply,
                 socket
                 |> assign(error_banner: nil, info_banner: "#{verb} tool task ##{task_id}.")
                 |> clear_composer_and_draft()}

              {:error, err} ->
                {:noreply, assign(socket, :error_banner, format_error(err))}
            end

          :error ->
            {:noreply, assign(socket, :error_banner, "Usage: #{cmd_name} <task_id> [<reason>]")}
        end

      _ ->
        {:noreply, assign(socket, :error_banner, "Usage: #{cmd_name} <task_id> [<reason>]")}
    end
  end

  defp parse_pos_int(val) when is_integer(val) and val > 0, do: {:ok, val}

  defp parse_pos_int(val) when is_binary(val) do
    clean = val |> String.trim() |> String.trim_leading("#")

    case Integer.parse(clean) do
      {n, ""} when n > 0 -> {:ok, n}
      _ -> :error
    end
  end

  defp parse_pos_int(_), do: :error

  defp parse_approval_policy(raw) when is_list(raw) do
    tools =
      raw |> Enum.map(&String.trim(to_string(&1))) |> Enum.reject(&(&1 == "")) |> Enum.uniq()

    if tools == [],
      do: {:error, "Usage: /approval [never|mutating|tools=t1,t2]"},
      else: {:ok, tools}
  end

  defp parse_approval_policy(raw) when is_binary(raw) do
    trimmed = String.trim(raw)
    lower = String.downcase(trimmed)

    cond do
      lower in ["never", "mutating"] ->
        {:ok, lower}

      String.starts_with?(lower, "tools=") ->
        parse_approval_tool_list(String.slice(trimmed, 6..-1//1))

      String.contains?(trimmed, ",") ->
        parse_approval_tool_list(trimmed)

      true ->
        {:error, "Usage: /approval [never|mutating|tools=t1,t2]"}
    end
  end

  defp parse_approval_policy(_), do: {:error, "Usage: /approval [never|mutating|tools=t1,t2]"}

  defp parse_approval_tool_list(raw) do
    tools =
      raw
      |> String.split(",")
      |> Enum.map(&String.trim/1)
      |> Enum.reject(&(&1 == ""))
      |> Enum.uniq()

    if tools == [] do
      {:error, "Usage: /approval [never|mutating|tools=t1,t2]"}
    else
      {:ok, tools}
    end
  end

  defp parse_budget_slash_arg(arg) do
    trimmed = String.trim(arg)

    if String.downcase(trimmed) == "clear" do
      {:ok, nil}
    else
      tokens = String.split(trimmed, ~r/\s+/, trim: true)

      Enum.reduce_while(tokens, {:ok, %{}}, fn token, {:ok, acc} ->
        case String.split(token, "=", parts: 2) do
          [k, v] ->
            key = String.downcase(k)

            case {key, v} do
              {turns_key, raw_int} when turns_key in ["turns", "max_turns"] ->
                case parse_pos_int(raw_int) do
                  {:ok, n} -> {:cont, {:ok, Map.put(acc, "max_turns", n)}}
                  :error -> {:halt, {:error, "Invalid turns value: #{raw_int}"}}
                end

              {ms_key, raw_int} when ms_key in ["ms", "max_elapsed_ms"] ->
                case parse_pos_int(raw_int) do
                  {:ok, n} -> {:cont, {:ok, Map.put(acc, "max_elapsed_ms", n)}}
                  :error -> {:halt, {:error, "Invalid ms value: #{raw_int}"}}
                end

              {cost_key, raw_float} when cost_key in ["cost", "max_cost_usd"] ->
                case parse_pos_float(raw_float) do
                  {:ok, f} -> {:cont, {:ok, Map.put(acc, "max_cost_usd", f)}}
                  :error -> {:halt, {:error, "Invalid cost value: #{raw_float}"}}
                end

              _ ->
                {:halt, {:error, "Usage: /budget [turns=N] [cost=USD] [ms=N] | clear"}}
            end

          _ ->
            {:halt, {:error, "Usage: /budget [turns=N] [cost=USD] [ms=N] | clear"}}
        end
      end)
      |> case do
        {:ok, map} when map_size(map) == 0 ->
          {:error, "Usage: /budget [turns=N] [cost=USD] [ms=N] | clear"}

        other ->
          other
      end
    end
  end

  defp parse_budget_params(params) do
    turns_raw = non_empty(params["max_turns"] || params["turns"])
    cost_raw = non_empty(params["max_cost_usd"] || params["cost"])
    ms_raw = non_empty(params["max_elapsed_ms"] || params["ms"])

    with {:ok, m1} <- maybe_parse_pos_int_field(%{}, "max_turns", turns_raw),
         {:ok, m2} <- maybe_parse_pos_float_field(m1, "max_cost_usd", cost_raw),
         {:ok, m3} <- maybe_parse_pos_int_field(m2, "max_elapsed_ms", ms_raw) do
      if map_size(m3) == 0, do: {:ok, nil}, else: {:ok, m3}
    end
  end

  defp maybe_parse_pos_int_field(acc, _key, nil), do: {:ok, acc}

  defp maybe_parse_pos_int_field(acc, key, raw) do
    case parse_pos_int(raw) do
      {:ok, n} -> {:ok, Map.put(acc, key, n)}
      :error -> {:error, "Invalid #{key}: #{raw}"}
    end
  end

  defp maybe_parse_pos_float_field(acc, _key, nil), do: {:ok, acc}

  defp maybe_parse_pos_float_field(acc, key, raw) do
    case parse_pos_float(raw) do
      {:ok, f} -> {:ok, Map.put(acc, key, f)}
      :error -> {:error, "Invalid #{key}: #{raw}"}
    end
  end

  defp parse_pos_float(val) when is_number(val) and val > 0, do: {:ok, val * 1.0}

  defp parse_pos_float(val) when is_binary(val) do
    case Float.parse(String.trim(val)) do
      {f, ""} when f > 0 -> {:ok, f}
      _ -> :error
    end
  end

  defp parse_pos_float(_), do: :error

  defp format_approval_policy(tools) when is_list(tools), do: Enum.join(tools, ", ")
  defp format_approval_policy(other) when is_binary(other), do: other
  defp format_approval_policy(_), do: "never"

  defp format_budget_summary(budget) when is_map(budget) and map_size(budget) > 0 do
    parts =
      []
      |> then(fn acc ->
        if budget["max_turns"], do: acc ++ ["turns=#{budget["max_turns"]}"], else: acc
      end)
      |> then(fn acc ->
        if budget["max_cost_usd"], do: acc ++ ["cost=$#{budget["max_cost_usd"]}"], else: acc
      end)
      |> then(fn acc ->
        if budget["max_elapsed_ms"], do: acc ++ ["ms=#{budget["max_elapsed_ms"]}"], else: acc
      end)

    if parts == [], do: "none", else: Enum.join(parts, ", ")
  end

  defp format_budget_summary(_), do: "none"

  defp refresh_extension_status(socket) do
    case Backend.get_extension_status(socket.assigns.session_id, socket.assigns.conversation_id) do
      {:ok, status} when is_map(status) -> assign(socket, :extension_status, status)
      _ -> assign(socket, :extension_status, nil)
    end
  end

  defp format_extension_status_summary(%{"extensions" => extensions})
       when is_map(extensions) and map_size(extensions) > 0 do
    extensions
    |> Enum.sort_by(&elem(&1, 0))
    |> Enum.map_join(" · ", fn {ns, data} ->
      details =
        if is_map(data) do
          data
          |> Enum.sort_by(&elem(&1, 0))
          |> Enum.map_join(", ", fn {k, v} -> "#{k}=#{v}" end)
        else
          inspect(data)
        end

      if details == "", do: ns, else: "#{ns} (#{details})"
    end)
  end

  defp format_extension_status_summary(_), do: ""

  defp active_subagent_task_id(child_id, tasks) when is_binary(child_id) and is_list(tasks) do
    Enum.find_value(tasks, fn task ->
      tid = task[:id] || task["id"]
      kind = task[:kind] || task["kind"]
      status = task[:status] || task["status"]
      memos = task[:memos] || task["memos"] || %{}
      checkpoint = task[:checkpoint] || task["checkpoint"] || %{}
      name = checkpoint["name"] || checkpoint[:name]
      task_child_id = memos["child_session_id"] || memos[:child_session_id]

      if kind == "tool_call" and name == "subagent" and task_child_id == child_id and
           status in ["pending", "running", "sleeping", "retrying", "waiting"] do
        to_string(tid)
      end
    end)
  end

  defp active_subagent_task_id(_, _), do: nil
end
