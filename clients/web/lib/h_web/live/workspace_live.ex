defmodule HWeb.WorkspaceLive do
  @moduledoc """
  Workspace, environment, and session browser LiveView.
  """
  use HWeb, :live_view

  alias HWeb.{Backend, CatalogState, InboxComponents, Layouts, SlashCommands}

  @impl true
  def mount(params, _session, socket) do
    environments = Backend.list_environments()
    harnesses = Backend.list_harnesses()
    models = Backend.list_models()

    initial_env =
      case params["env_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> first_env_id(environments)
      end

    initial_path = params["path"] || ""

    socket =
      socket
      |> assign(
        environments: environments,
        harnesses: harnesses,
        models: models,
        env_id: initial_env,
        path: "",
        parent_path: nil,
        directories: [],
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        sessions_by_dir: %{},
        session_groups: [],
        session_counts: CatalogState.counts([]),
        selected_dir: nil,
        workspace_pane: "folders",
        filter: "",
        new_session: nil,
        browse_error: nil
      )
      |> load_sessions()
      |> browse(initial_env, initial_path)

    {:ok, socket}
  end

  @impl true
  def terminate(_reason, socket) do
    if socket.assigns[:catalog_subscribed?] do
      Backend.unsubscribe_sessions()
    end

    :ok
  end

  @impl true
  def handle_info({:catalog_frame, seq, json_bin}, socket) do
    case CatalogState.apply_frame(socket.assigns.catalog, seq, json_bin) do
      {:ok, next_catalog} ->
        {:noreply, apply_catalog_assigns(socket, next_catalog)}

      :stale ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply, load_sessions(socket)}
    end
  end

  @impl true
  def handle_event("select_env", %{"env_id" => env_id}, socket) do
    {:noreply, browse(socket, env_id, "")}
  end

  def handle_event("browse_dir", %{"path" => path}, socket) do
    {:noreply, browse(socket, socket.assigns.env_id, path)}
  end

  def handle_event("browse_parent", _params, socket) do
    case socket.assigns.parent_path do
      nil -> {:noreply, socket}
      parent -> {:noreply, browse(socket, socket.assigns.env_id, parent)}
    end
  end

  def handle_event("browse_path", %{"path" => path}, socket) do
    {:noreply, browse(socket, socket.assigns.env_id, String.trim(path))}
  end

  def handle_event("filter_dirs", %{"filter" => filter}, socket) do
    {:noreply, assign(socket, :filter, filter)}
  end

  def handle_event("select_dir", %{"path" => path}, socket) do
    cond do
      path == socket.assigns.selected_dir ->
        {:noreply, assign(socket, :selected_dir, nil)}

      Enum.any?(socket.assigns.directories, &(&1.path == path)) ->
        {:noreply, assign(socket, selected_dir: path, workspace_pane: "sessions")}

      true ->
        {:noreply, socket}
    end
  end

  def handle_event("clear_dir_selection", _params, socket) do
    {:noreply, assign(socket, :selected_dir, nil)}
  end

  def handle_event("show_pane", %{"pane" => pane}, socket) when pane in ["folders", "sessions"] do
    {:noreply, assign(socket, :workspace_pane, pane)}
  end

  def handle_event("complete_directory", params, socket) do
    lookup_id = params["lookup_id"]
    prefix = if is_binary(params["prefix"]), do: params["prefix"], else: ""
    target_id = params["target_id"] || "workspace-path-input"
    env_id = socket.assigns.env_id || "host"

    fallback_cwd =
      if is_binary(socket.assigns.path) and String.starts_with?(socket.assigns.path, "/"),
        do: socket.assigns.path,
        else: "/"

    items =
      case SlashCommands.complete_directories(env_id, fallback_cwd, prefix) do
        {:ok, list} -> list
        _ -> []
      end

    {:noreply,
     push_event(socket, "completion_results", %{
       lookup_id: lookup_id,
       target_id: target_id,
       kind: "directory",
       prefix: prefix,
       items: items
     })}
  end

  def handle_event("refresh_sessions", _params, socket) do
    {:noreply,
     socket
     |> load_sessions()
     |> browse(socket.assigns.env_id, socket.assigns.path)}
  end

  def handle_event("prepare_session", %{"cwd" => cwd} = params, socket) do
    env_id = params["env_id"] || socket.assigns.env_id

    if is_binary(cwd) and cwd != "" do
      draft = %{
        cwd: cwd,
        env_id: env_id,
        fields: %{
          "harness_id" => first_harness_id(socket.assigns.harnesses),
          "model" => first_model_id(socket.assigns.models),
          "session_id" => ""
        },
        error: nil
      }

      {:noreply,
       socket
       |> assign(:new_session, draft)
       |> push_event("open_panel", %{id: "workspace-new-session"})}
    else
      {:noreply, socket}
    end
  end

  def handle_event("edit_session_draft", params, %{assigns: %{new_session: draft}} = socket)
      when not is_nil(draft) do
    {:noreply, assign(socket, :new_session, update_session_draft(draft, params))}
  end

  def handle_event("start_session", params, %{assigns: %{new_session: draft}} = socket)
      when not is_nil(draft) do
    draft = update_session_draft(draft, params)
    model = non_empty(draft.fields["model"])

    create_params =
      %{"env_id" => draft.env_id, "cwd" => draft.cwd}
      |> maybe_put("harness_id", non_empty(draft.fields["harness_id"]))
      |> maybe_put("session_id", non_empty(draft.fields["session_id"]))
      |> maybe_put("agent", if(model, do: %{"model" => model}, else: nil))

    case Backend.create_session(create_params) do
      {:ok, %{session: session}} ->
        sid = session[:session_id] || session["session_id"]
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{sid}")}

      {:error, reason} ->
        {:noreply, assign(socket, :new_session, %{draft | error: format_error(reason)})}
    end
  end

  def handle_event(event, _params, socket) when event in ["edit_session_draft", "start_session"],
    do: {:noreply, socket}

  def handle_event("review_workspace", params, socket) do
    with {:ok, %{session: session}} <-
           Backend.open_workspace_review(%{
             "env_id" => params["env_id"] || socket.assigns.env_id,
             "cwd" => non_empty(params["cwd"]) || socket.assigns.path
           }) do
      {:noreply, push_navigate(socket, to: ~p"/sessions/#{session.session_id}/review")}
    else
      {:error, reason} -> {:noreply, put_flash(socket, :error, format_error(reason))}
    end
  end

  defp update_session_draft(draft, params) do
    fields = Map.merge(draft.fields, Map.take(params, Map.keys(draft.fields)))
    %{draft | fields: fields, error: nil}
  end

  defp load_sessions(socket) do
    if connected?(socket) do
      case Backend.subscribe_sessions(self()) do
        {:ok, {:snapshot, seq, json_bin}} ->
          case CatalogState.apply_snapshot(CatalogState.new(), seq, json_bin) do
            {:ok, catalog} ->
              socket
              |> assign(:catalog_subscribed?, true)
              |> apply_catalog_assigns(catalog)

            {:error, _} ->
              assign(socket, :catalog_subscribed?, true)
          end

        _ ->
          load_sessions_disconnected(socket)
      end
    else
      load_sessions_disconnected(socket)
    end
  end

  defp load_sessions_disconnected(socket) do
    case Backend.list_sessions(%{}) do
      {:ok, sessions} ->
        apply_catalog_assigns(socket, CatalogState.from_list(sessions))

      _ ->
        apply_catalog_assigns(socket, CatalogState.new())
    end
  end

  defp apply_catalog_assigns(socket, catalog) do
    root_sessions = Enum.filter(catalog.sessions, &CatalogState.root_session?/1)

    assign(socket,
      catalog: catalog,
      sessions_by_dir: Enum.group_by(root_sessions, &{&1.env_id, &1.cwd}),
      session_groups: CatalogState.group_by_workspace(catalog.sessions),
      session_counts: CatalogState.counts(catalog.sessions)
    )
  end

  defp browse(socket, env_id, path) do
    query = %{"env_id" => env_id} |> maybe_put("path", non_empty(path))

    case Backend.browse_workspace(query) do
      {:ok, view} ->
        same_folder? = view.env_id == socket.assigns.env_id and view.path == socket.assigns.path

        selected_dir =
          if same_folder? and
               Enum.any?(view.directories, &(&1.path == socket.assigns.selected_dir)),
             do: socket.assigns.selected_dir

        assign(socket,
          env_id: view.env_id,
          path: view.path,
          parent_path: view.parent_path,
          directories: view.directories,
          selected_dir: selected_dir,
          workspace_pane: if(same_folder?, do: socket.assigns.workspace_pane, else: "folders"),
          filter: if(same_folder?, do: socket.assigns.filter, else: ""),
          browse_error: nil
        )

      {:error, reason} ->
        assign(socket,
          env_id: env_id,
          path: path,
          parent_path: nil,
          directories: [],
          selected_dir: nil,
          workspace_pane: "folders",
          filter: "",
          browse_error: format_error(reason)
        )
    end
  end

  defp filter_directories(dirs, filter) when filter in [nil, ""], do: dirs

  defp filter_directories(dirs, filter) do
    q = String.downcase(String.trim(filter))
    Enum.filter(dirs, fn d -> String.contains?(String.downcase(d.name), q) end)
  end

  defp first_env_id([%{id: id} | _]), do: id
  defp first_env_id(_), do: "host"

  defp first_harness_id(harnesses) when is_list(harnesses) do
    cond do
      Enum.any?(harnesses, &((&1["id"] || &1[:id]) == "coding")) ->
        "coding"

      match?([_ | _], harnesses) ->
        first = hd(harnesses)
        first["id"] || first[:id] || "coding"

      true ->
        "coding"
    end
  end

  defp first_harness_id(_), do: "coding"

  defp first_model_id([%{id: id} | _]), do: id
  defp first_model_id(_), do: ""

  defp non_empty(val) when is_binary(val) do
    trimmed = String.trim(val)
    if trimmed == "", do: nil, else: trimmed
  end

  defp non_empty(_), do: nil

  defp maybe_put(map, _key, nil), do: map
  defp maybe_put(map, key, val), do: Map.put(map, key, val)

  defp format_error({:bad_request, msg}), do: msg
  defp format_error({:conflict, msg}), do: msg
  defp format_error(:not_found), do: "Directory not found"
  defp format_error(:unknown_environment), do: "Unknown execution environment"
  defp format_error(other), do: inspect(other)
end
