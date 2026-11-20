defmodule HWeb.InboxLive do
  @moduledoc """
  Dedicated multi-session inbox LiveView (`/inbox`), grouped by working directory
  root and backed by live `H.Catalog` PubSub frames without waking unloaded
  sessions.
  """
  use HWeb, :live_view

  alias HWeb.{Backend, CatalogState, InboxComponents}

  @impl true
  def mount(params, _session, socket) do
    initial_filter = if params["filter"] == "attention", do: "attention", else: "all"
    initial_search = if is_binary(params["q"]), do: params["q"], else: ""
    initial_subsessions = params["subsessions"] in ["1", "true"]

    socket =
      socket
      |> assign(
        catalog: CatalogState.new(),
        catalog_subscribed?: false,
        filter_mode: initial_filter,
        search: initial_search,
        show_subsessions?: initial_subsessions,
        error_banner: nil
      )
      |> load_catalog()
      |> recompute_view()

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
        {:noreply,
         socket
         |> assign(:catalog, next_catalog)
         |> recompute_view()}

      :stale ->
        {:noreply, socket}

      {:error, _reason} ->
        {:noreply,
         socket
         |> load_catalog()
         |> recompute_view()}
    end
  end

  @impl true
  def handle_event("set_filter", %{"mode" => mode}, socket) do
    normalized = if mode == "attention", do: "attention", else: "all"

    {:noreply,
     socket
     |> assign(:filter_mode, normalized)
     |> recompute_view()}
  end

  def handle_event("toggle_subsessions", _params, socket) do
    {:noreply,
     socket
     |> assign(:show_subsessions?, not socket.assigns.show_subsessions?)
     |> recompute_view()}
  end

  def handle_event("search", %{"q" => q}, socket) when is_binary(q) do
    {:noreply,
     socket
     |> assign(:search, q)
     |> recompute_view()}
  end

  def handle_event("search", _params, socket), do: {:noreply, socket}

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_catalog()
     |> recompute_view()}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_banner, nil)}
  end

  def handle_event("new_session", %{"cwd" => cwd} = params, socket)
      when is_binary(cwd) and cwd != "" do
    env_id =
      case params["env_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> "host"
      end

    case Backend.create_session(%{"env_id" => env_id, "cwd" => cwd}) do
      {:ok, %{session: session}} ->
        sid = session[:session_id] || session["session_id"]
        {:noreply, push_navigate(socket, to: ~p"/sessions/#{sid}?from=inbox")}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("new_session", _params, socket), do: {:noreply, socket}

  defp load_catalog(socket) do
    if connected?(socket) do
      case Backend.subscribe_sessions(self()) do
        {:ok, {:snapshot, seq, json_bin}} ->
          case CatalogState.apply_snapshot(CatalogState.new(), seq, json_bin) do
            {:ok, catalog} ->
              assign(socket, catalog: catalog, catalog_subscribed?: true, error_banner: nil)

            {:error, reason} ->
              assign(socket,
                catalog_subscribed?: true,
                error_banner: format_error(reason)
              )
          end

        {:error, reason} ->
          assign(socket, :error_banner, format_error(reason))
      end
    else
      case Backend.list_sessions(%{}) do
        {:ok, sessions} ->
          assign(socket, catalog: CatalogState.from_list(sessions), error_banner: nil)

        {:error, reason} ->
          assign(socket, :error_banner, format_error(reason))
      end
    end
  end

  defp recompute_view(socket) do
    all_sessions = socket.assigns.catalog.sessions
    show_subsessions? = socket.assigns.show_subsessions?
    counts = CatalogState.counts(all_sessions)

    filtered =
      CatalogState.filter_sessions(
        all_sessions,
        socket.assigns.filter_mode,
        socket.assigns.search,
        include_subsessions: show_subsessions?
      )

    groups = CatalogState.group_by_workspace(filtered, include_subsessions: show_subsessions?)
    next_attention = CatalogState.next_attention_session(all_sessions)

    assign(socket,
      counts: counts,
      groups: groups,
      filtered_count: length(filtered),
      next_attention: next_attention
    )
  end

  defp format_error({:bad_request, msg}), do: msg
  defp format_error({:conflict, msg}), do: msg
  defp format_error(:catalog_unavailable), do: "Session catalog is unavailable."
  defp format_error(:workspace_unavailable), do: "Workspace environment is unavailable."
  defp format_error(other), do: inspect(other)
end
