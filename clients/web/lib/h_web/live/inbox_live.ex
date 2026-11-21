defmodule HWeb.InboxLive do
  @moduledoc """
  Dedicated multi-session inbox LiveView (`/inbox`), grouped by working directory
  root and backed by live `H.Catalog` PubSub frames without waking unloaded
  sessions.
  """
  use HWeb, :live_view

  alias HWeb.{Backend, CatalogState, InboxComponents, InboxFilter, Layouts}

  @impl true
  def mount(_params, _session, socket) do
    socket =
      socket
      |> assign(catalog: CatalogState.new(), catalog_subscribed?: false, error_banner: nil)
      |> load_catalog()

    {:ok, socket}
  end

  @impl true
  def handle_params(params, _uri, socket) do
    {:noreply,
     socket |> assign(:inbox_filter, InboxFilter.from_params(params)) |> recompute_view()}
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
    filter = %{socket.assigns.inbox_filter | mode: mode}
    {:noreply, push_patch(socket, to: InboxFilter.inbox_path(filter), replace: true)}
  end

  def handle_event("toggle_subsessions", _params, socket) do
    filter = %{
      socket.assigns.inbox_filter
      | subsessions: not socket.assigns.inbox_filter.subsessions
    }

    {:noreply, push_patch(socket, to: InboxFilter.inbox_path(filter), replace: true)}
  end

  def handle_event("filter_inbox", params, socket) do
    filter = InboxFilter.from_form(socket.assigns.inbox_filter, params)
    {:noreply, push_patch(socket, to: InboxFilter.inbox_path(filter), replace: true)}
  end

  def handle_event("refresh", _params, socket) do
    {:noreply,
     socket
     |> load_catalog()
     |> recompute_view()}
  end

  def handle_event("dismiss_error", _params, socket) do
    {:noreply, assign(socket, :error_banner, nil)}
  end

  def handle_event(
        "toggle_attention",
        %{"sid" => sid, "needs-attention" => raw_val},
        socket
      )
      when is_binary(sid) do
    needs_attention = raw_val == "true"

    case Backend.triage_session(sid, %{"needs_attention" => needs_attention}) do
      {:ok, %{session: session}} ->
        {:noreply, apply_session_upsert(socket, session)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("toggle_attention", _params, socket), do: {:noreply, socket}

  def handle_event("stop_session", %{"sid" => sid}, socket) when is_binary(sid) do
    case Backend.stop_session(sid, %{}) do
      {:ok, %{session: session}} ->
        {:noreply, apply_session_upsert(socket, session)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("stop_session", _params, socket), do: {:noreply, socket}

  def handle_event("archive_session", %{"sid" => sid} = params, socket) when is_binary(sid) do
    stop? = params["stop"] == "true"

    case Backend.archive_session(sid, %{"archived" => true, "stop" => stop?}) do
      {:ok, %{session: session}} ->
        {:noreply, apply_session_upsert(socket, session)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("archive_session", _params, socket), do: {:noreply, socket}

  def handle_event("unarchive_session", %{"sid" => sid}, socket) when is_binary(sid) do
    case Backend.archive_session(sid, %{"archived" => false}) do
      {:ok, %{session: session}} ->
        {:noreply, apply_session_upsert(socket, session)}

      {:error, reason} ->
        {:noreply, assign(socket, :error_banner, format_error(reason))}
    end
  end

  def handle_event("unarchive_session", _params, socket), do: {:noreply, socket}

  def handle_event("new_session", %{"cwd" => cwd} = params, socket)
      when is_binary(cwd) and cwd != "" do
    env_id =
      case params["env_id"] do
        id when is_binary(id) and id != "" -> id
        _ -> "host"
      end

    filter = socket.assigns.inbox_filter

    case Backend.create_session(%{"env_id" => env_id, "cwd" => cwd}) do
      {:ok, %{session: session}} ->
        sid = session[:session_id] || session["session_id"]
        {:noreply, push_navigate(socket, to: InboxFilter.session_path(sid, filter))}

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
    filter = socket.assigns.inbox_filter
    show_subsessions? = filter.subsessions == true
    scoped = InboxFilter.scope(filter, all_sessions)

    filtered =
      CatalogState.filter_sessions(scoped, filter.mode, "",
        include_subsessions: show_subsessions?
      )

    assign(socket,
      show_subsessions?: show_subsessions?,
      counts: CatalogState.counts(scoped),
      groups: CatalogState.group_by_workspace(filtered, include_subsessions: show_subsessions?),
      filter_options: InboxFilter.options(filter, all_sessions),
      catalog_empty?: all_sessions == [],
      next_attention: CatalogState.next_attention_session(filtered)
    )
  end

  defp apply_session_upsert(socket, raw_session) do
    session = CatalogState.normalize_session(raw_session)
    catalog = socket.assigns.catalog
    by_id = Map.put(catalog.by_id, session.session_id, session)

    next_catalog = %{
      catalog
      | by_id: by_id,
        sessions: Enum.sort_by(Map.values(by_id), &{&1.updated_at || 0, &1.session_id}, :desc)
    }

    socket
    |> assign(catalog: next_catalog, error_banner: nil)
    |> recompute_view()
  end

  defp format_error({:bad_request, msg}), do: msg
  defp format_error({:conflict, msg}), do: msg
  defp format_error(:not_found), do: "Session not found."
  defp format_error(:catalog_unavailable), do: "Session catalog is unavailable."
  defp format_error(:workspace_unavailable), do: "Workspace environment is unavailable."
  defp format_error(other), do: inspect(other)
end
