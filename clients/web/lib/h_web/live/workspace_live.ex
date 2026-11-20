defmodule HWeb.WorkspaceLive do
  @moduledoc """
  Workspace, environment, and session browser LiveView.
  """
  use HWeb, :live_view

  alias HWeb.{Backend, CatalogState, InboxComponents, Workbench}

  @impl true
  def mount(params, _session, socket) do
    environments = Backend.list_environments()
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
        models: models,
        env_id: initial_env,
        path: "",
        parent_path: nil,
        directories: [],
        folder_sessions: [],
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        sessions: [],
        session_groups: [],
        session_counts: CatalogState.counts([]),
        selected_dir: "",
        filter: "",
        new_session_id: "",
        selected_model: first_model_id(models),
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
    {:noreply,
     socket
     |> assign(filter: "")
     |> browse(env_id, "")}
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
    {:noreply, assign(socket, :selected_dir, path)}
  end

  def handle_event("refresh_sessions", _params, socket) do
    {:noreply,
     socket
     |> load_sessions()
     |> browse(socket.assigns.env_id, socket.assigns.path)}
  end

  def handle_event("start_session", params, socket) do
    cwd =
      non_empty(params["cwd"]) || non_empty(socket.assigns.selected_dir) || socket.assigns.path

    env_id = non_empty(params["env_id"]) || socket.assigns.env_id
    session_id = non_empty(params["session_id"])
    model = non_empty(params["model"]) || non_empty(socket.assigns.selected_model)

    create_params =
      %{"env_id" => env_id, "cwd" => cwd}
      |> maybe_put("session_id", session_id)
      |> maybe_put("agent", if(model, do: %{"model" => model}, else: nil))

    case Backend.create_session(create_params) do
      {:ok, %{session: session}} ->
        sid = session[:session_id] || session["session_id"]
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{sid}")}

      {:error, reason} ->
        {:noreply, put_flash(socket, :error, format_error(reason))}
    end
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
    assign(socket,
      catalog: catalog,
      sessions: catalog.sessions,
      session_groups: CatalogState.group_by_workspace(catalog.sessions),
      session_counts: CatalogState.counts(catalog.sessions)
    )
  end

  defp browse(socket, env_id, path) do
    query = %{"env_id" => env_id} |> maybe_put("path", non_empty(path))

    case Backend.browse_workspace(query) do
      {:ok, view} ->
        assign(socket,
          env_id: view.env_id,
          path: view.path,
          parent_path: view.parent_path,
          directories: view.directories,
          folder_sessions: view.sessions,
          selected_dir: view.path,
          browse_error: nil
        )

      {:error, reason} ->
        assign(socket,
          env_id: env_id,
          directories: [],
          folder_sessions: [],
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
