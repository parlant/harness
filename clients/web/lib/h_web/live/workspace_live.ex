defmodule HWeb.WorkspaceLive do
  @moduledoc """
  Workspace, environment, and session browser LiveView.
  """
  use HWeb, :live_view

  alias HWeb.Backend

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
        sessions: [],
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

  @impl true
  def render(assigns) do
    filtered_dirs = filter_directories(assigns.directories, assigns.filter)
    assigns = assign(assigns, :filtered_dirs, filtered_dirs)

    ~H"""
    <div class="workspace-shell">
      <header class="topbar">
        <div class="brand">
          <span class="brand-mark">H</span>
          <span class="brand-title">Workspaces &amp; Sessions</span>
        </div>

        <div class="topbar-actions">
          <button
            id="refresh-sessions-btn"
            type="button"
            class="btn btn-sm"
            phx-click="refresh_sessions"
          >
            Refresh
          </button>
          <form action={~p"/logout"} method="post" class="inline-form">
            <input type="hidden" name="_csrf_token" value={get_csrf_token()} />
            <button type="submit" class="btn btn-sm btn-ghost">Sign out</button>
          </form>
        </div>
      </header>

      <main class="workspace-grid">
        <section class="panel browser-panel">
          <div class="panel-header">
            <h2>Workspace Browser</h2>
            <div class="env-tabs" role="tablist" aria-label="Execution environments">
              <button
                :for={env <- @environments}
                type="button"
                class={["btn btn-sm", if(env.id == @env_id, do: "btn-primary", else: "btn-ghost")]}
                phx-click="select_env"
                phx-value-env_id={env.id}
              >
                {env.label || env.id}
              </button>
            </div>
          </div>

          <div class="path-toolbar">
            <button
              id="browse-up-btn"
              type="button"
              class="btn btn-sm"
              phx-click="browse_parent"
              disabled={is_nil(@parent_path)}
            >
              Up ..
            </button>

            <form phx-submit="browse_path" class="path-form">
              <input
                type="text"
                name="path"
                value={@path}
                aria-label="Workspace path"
                class="input mono"
              />
              <button type="submit" class="btn btn-sm">Go</button>
            </form>

            <form id="filter-dirs-form" phx-change="filter_dirs" class="filter-form">
              <input
                type="search"
                name="filter"
                value={@filter}
                placeholder="Filter folders…"
                aria-label="Filter folders"
                class="input"
              />
            </form>
          </div>

          <div :if={@browse_error} class="flash-banner flash-error">
            <span>{@browse_error}</span>
          </div>

          <form id="start-session-form" phx-submit="start_session" class="new-session-card">
            <input type="hidden" name="env_id" value={@env_id} />
            <div class="new-session-fields">
              <label class="field-group">
                <span class="field-label">Selected directory</span>
                <input
                  id="selected-cwd-input"
                  type="text"
                  name="cwd"
                  value={@selected_dir}
                  class="input mono"
                  required
                />
              </label>

              <label class="field-group">
                <span class="field-label">Model</span>
                <select id="workspace-model-select" name="model" class="input">
                  <option
                    :for={model <- @models}
                    value={model.id}
                    selected={model.id == @selected_model}
                  >
                    {model.name || model.id}
                  </option>
                </select>
              </label>

              <label class="field-group">
                <span class="field-label">Session ID (optional)</span>
                <input
                  id="new-session-id-input"
                  type="text"
                  name="session_id"
                  value={@new_session_id}
                  placeholder="auto-generated"
                  class="input mono"
                />
              </label>
            </div>

            <div class="new-session-actions">
              <button id="start-selected-session-btn" type="submit" class="btn btn-primary">
                Start New Session
              </button>
            </div>
          </form>

          <div class="section-block">
            <h3 class="section-title">Folders in <span class="mono">{@path}</span></h3>
            <p :if={@filtered_dirs == []} class="muted">No subdirectories match.</p>

            <ul id="directories-list" class="dir-list">
              <li :for={dir <- @filtered_dirs} class="dir-row">
                <div class="dir-main">
                  <button
                    type="button"
                    class="dir-name-btn"
                    phx-click="browse_dir"
                    phx-value-path={dir.path}
                  >
                    <span class="mono">{dir.name}/</span>
                  </button>

                  <span :for={marker <- dir.markers} class="badge mono">{marker}</span>

                  <span
                    :if={dir.active_session_count > 0}
                    class="badge badge-active"
                    title="Active sessions"
                  >
                    {dir.active_session_count} active
                  </span>

                  <span
                    :if={dir.direct_session_count > 0 or dir.subtree_session_count > 0}
                    class="badge mono"
                  >
                    {dir.direct_session_count} direct / {dir.subtree_session_count} total
                  </span>
                </div>

                <div class="dir-actions">
                  <button
                    type="button"
                    class="btn btn-sm btn-ghost"
                    phx-click="select_dir"
                    phx-value-path={dir.path}
                  >
                    Select
                  </button>
                  <button
                    type="button"
                    class="btn btn-sm btn-primary"
                    phx-click="start_session"
                    phx-value-cwd={dir.path}
                  >
                    Start Session
                  </button>
                </div>
              </li>
            </ul>
          </div>

          <div :if={@folder_sessions != []} class="section-block">
            <h3 class="section-title">Sessions in this folder</h3>
            <ul class="session-list">
              <li :for={s <- @folder_sessions} class="session-card">
                <div class="session-card-info">
                  <span class="mono session-id">{s.session_id}</span>
                  <span :if={s.title} class="session-title">{s.title}</span>
                  <span :if={s.active} class="badge badge-active">active</span>
                </div>
                <.link navigate={~p"/sessions/#{s.session_id}"} class="btn btn-sm">
                  Resume
                </.link>
              </li>
            </ul>
          </div>
        </section>

        <aside class="panel sessions-panel">
          <div class="panel-header">
            <h2>All Sessions</h2>
            <span class="badge mono">{length(@sessions)}</span>
          </div>

          <p :if={@sessions == []} class="muted">
            No sessions yet. Select a folder and start one.
          </p>

          <ul id="all-sessions-list" class="session-list">
            <li :for={s <- @sessions} class="session-card">
              <div class="session-card-info">
                <div class="session-card-top">
                  <span class="mono session-id">{s.session_id}</span>
                  <span :if={s.active} class="badge badge-active">active</span>
                  <span :if={s.status == "quarantined"} class="badge badge-danger">quarantined</span>
                </div>
                <div :if={s.title} class="session-title">{s.title}</div>
                <div class="muted mono session-cwd">{s.env_id}: {s.cwd}</div>
              </div>

              <.link navigate={~p"/sessions/#{s.session_id}"} class="btn btn-sm">
                Resume
              </.link>
            </li>
          </ul>
        </aside>
      </main>
    </div>
    """
  end

  defp load_sessions(socket) do
    case Backend.list_sessions(%{}) do
      {:ok, sessions} -> assign(socket, :sessions, sessions)
      _ -> assign(socket, :sessions, [])
    end
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
