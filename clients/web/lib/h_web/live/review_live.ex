defmodule HWeb.ReviewLive do
  use HWeb, :live_view

  alias HWeb.{Backend, InboxFilter, Workbench}

  @refresh_ms 2500
  @max_open_dirs 48
  @max_excerpt 12_000
  @max_line 524_289

  @impl true
  def mount(%{"session_id" => sid} = params, _session, socket) do
    cid = params["conversation"]

    with {:ok, %{session: session, conversations: conversations}} <-
           Backend.get_session_detail(sid),
         cid = cid || session.root_conversation_id,
         true <- Enum.any?(conversations, &(&1.id == cid)) do
      if connected?(socket), do: Process.send_after(self(), :review_refresh, @refresh_ms)

      {:ok,
       assign(socket,
         session_id: sid,
         conversation_id: cid,
         session: session,
         inbox_filter: InboxFilter.from_params(params),
         from_inbox?: params["from"] == "inbox",
         tab: "changes",
         git_available?: true,
         dirs: %{},
         refresh_offset: 0,
         history: nil,
         history_page: 0,
         commit: nil,
         file: nil,
         browser: nil,
         browser_error: nil
       )
       |> refresh()}
    else
      _ ->
        {:ok,
         socket
         |> put_flash(:error, "Review session or conversation not found.")
         |> redirect(to: ~p"/inbox")}
    end
  end

  @impl true
  def handle_info(:review_refresh, socket) do
    Process.send_after(self(), :review_refresh, @refresh_ms)
    {:noreply, refresh(socket)}
  end

  @impl true
  def handle_event("review_tab", %{"tab" => tab}, socket) when tab in ["changes", "files"] do
    {:noreply, refresh(assign(socket, tab: tab))}
  end

  def handle_event("review_history", _, socket) do
    {:noreply,
     socket
     |> assign(tab: "history", commit: nil, file: nil, dirs: %{}, browser: nil)
     |> load_history(socket.assigns.history_page)}
  end

  def handle_event("review_working", _, socket) do
    {:noreply,
     socket
     |> assign(tab: "changes", commit: nil, file: nil, dirs: %{}, browser_error: nil)
     |> refresh()}
  end

  def handle_event(
        "review_history_page",
        %{"direction" => direction},
        %{assigns: %{tab: "history"} = a} = socket
      ) do
    case next_page(a.history_page, a.history, direction) do
      nil -> {:noreply, socket}
      page -> {:noreply, load_history(socket, page)}
    end
  end

  def handle_event("review_commit", %{"ref" => ref}, %{assigns: %{tab: "history"} = a} = socket) do
    ref = if is_binary(ref) and byte_size(ref) <= 64, do: String.trim(ref), else: ref

    case Backend.review_workspace(a.session_id, %{commit: ref}) do
      {:ok, %{commit: commit} = browser} ->
        {:noreply,
         assign(socket,
           commit: commit,
           tab: "changes",
           browser: browser,
           browser_error: nil,
           session: %{a.session | archived: browser.archived}
         )}

      {:error, reason} ->
        {:noreply, assign(socket, browser_error: error_message(reason))}
    end
  end

  def handle_event(
        "review_dir",
        %{"dir" => dir},
        %{assigns: %{tab: "files", dirs: dirs}} = socket
      )
      when is_binary(dir) and byte_size(dir) in 1..4096 do
    parent = Path.dirname(dir)
    parent = if parent == ".", do: "", else: parent

    socket =
      cond do
        Map.has_key?(dirs, dir) ->
          assign(socket, dirs: close_dir(dirs, dir), browser_error: nil)

        not Enum.any?(
          get_in(dirs, [parent, :listing, :entries]) || [],
          &(&1.path == dir && &1.type == "dir")
        ) ->
          socket

        map_size(dirs) >= @max_open_dirs ->
          assign(socket, browser_error: "Close a folder before opening more.")

        true ->
          load_dir(assign(socket, browser_error: nil), dir, 0)
      end

    {:noreply, socket}
  end

  def handle_event(
        "review_page",
        %{"dir" => dir, "direction" => direction},
        %{assigns: %{tab: "files", dirs: dirs}} = socket
      ) do
    case dirs[dir] do
      %{page: page, listing: listing} ->
        case next_page(page, listing, direction) do
          nil -> {:noreply, socket}
          page -> {:noreply, load_dir(socket, dir, page)}
        end

      nil ->
        {:noreply, socket}
    end
  end

  def handle_event("review_open", %{"path" => path} = params, socket)
      when is_binary(path) and byte_size(path) in 1..4096 do
    if socket.assigns.tab == "history" do
      {:noreply, socket}
    else
      {:noreply,
       assign(socket,
         file: %{
           path: path,
           deleted?: params["deleted"] == "true",
           changed?: params["changed"] == "true"
         }
       )}
    end
  end

  def handle_event("review_save", %{"path" => path, "revision" => rev, "text" => text}, socket) do
    case socket.assigns do
      %{session: %{archived: false}, commit: nil, file: %{path: ^path}} ->
        reply(socket, Backend.save_review_file(socket.assigns.session_id, path, rev, text))

      %{commit: %{}, file: %{path: ^path}} ->
        reply(socket, {:error, :historical_file})

      _ ->
        reply(socket, {:error, :read_only})
    end
  end

  def handle_event("review_comment", params, socket) do
    reply(socket, comment(socket.assigns, params))
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp refresh(%{assigns: %{tab: "files", dirs: dirs}} = socket) when map_size(dirs) == 0,
    do: load_dir(socket, "", 0)

  defp refresh(
         %{assigns: %{tab: "files", commit: nil, dirs: dirs, refresh_offset: offset}} = socket
       ) do
    # Don't stat every expanded folder on every tick. Rotate through the open pages.
    keys = Enum.sort(Map.keys(dirs))
    start = rem(offset, length(keys))

    keys
    |> Enum.drop(start)
    |> Enum.take(3)
    |> Enum.reduce(assign(socket, refresh_offset: start + 3), fn dir, acc ->
      case acc.assigns.dirs[dir] do
        %{page: page} -> load_dir(acc, dir, page)
        nil -> acc
      end
    end)
  end

  defp refresh(%{assigns: %{tab: "changes", commit: nil} = a} = socket) do
    case Backend.review_workspace(a.session_id, %{dir: "", page: 0, changes?: true}) do
      {:ok, %{git: :not_git} = browser} ->
        socket
        |> assign(git_available?: false, tab: "files", browser_error: nil)
        |> put_dir("", 0, {:ok, browser})

      {:ok, browser} ->
        assign(socket,
          browser: browser,
          browser_error: nil,
          git_available?: true,
          session: %{a.session | archived: browser.archived}
        )

      {:error, reason} ->
        assign(socket, browser: nil, browser_error: error_message(reason))
    end
  end

  defp refresh(socket), do: socket

  defp load_history(%{assigns: a} = socket, page) do
    case Backend.review_workspace(a.session_id, %{history: page}) do
      {:ok, history} ->
        assign(socket,
          history: history,
          history_page: page,
          browser_error: nil,
          session: %{a.session | archived: history.archived}
        )

      {:error, reason} ->
        assign(socket, browser_error: error_message(reason))
    end
  end

  defp load_dir(%{assigns: a} = socket, dir, page) do
    params = %{dir: dir, page: page, changes?: false}
    params = if a.commit, do: Map.put(params, :commit, a.commit.id), else: params
    put_dir(socket, dir, page, Backend.review_workspace(a.session_id, params))
  end

  defp put_dir(%{assigns: a} = socket, dir, page, result) do
    {listing, error, archived} =
      case result do
        {:ok, listing} ->
          entries = Enum.sort_by(listing.entries, &{&1.type != "dir", &1.name})
          {%{listing | entries: entries}, nil, listing.archived}

        {:error, :enoent} when dir == "" and not is_nil(a.commit) ->
          {nil, "This directory does not exist in the selected commit.", a.session.archived}

        {:error, reason} ->
          {nil, error_message(reason), a.session.archived}
      end

    visible = for entry <- (listing && listing.entries) || [], entry.type == "dir", do: entry.path

    dirs =
      for %{type: "dir", path: path} <- get_in(a.dirs, [dir, :listing, :entries]) || [],
          path not in visible,
          reduce: a.dirs do
        dirs -> close_dir(dirs, path)
      end

    assign(socket,
      dirs: Map.put(dirs, dir, %{page: page, listing: listing, error: error}),
      session: %{a.session | archived: archived}
    )
  end

  defp close_dir(dirs, dir) do
    Map.reject(dirs, fn {path, _} -> path == dir or String.starts_with?(path, dir <> "/") end)
  end

  defp next_page(page, _, "prev") when page > 0, do: page - 1
  defp next_page(page, %{next?: true}, "next") when page < 100_000, do: page + 1
  defp next_page(_, _, _), do: nil

  attr :dir, :string, required: true
  attr :dirs, :map, required: true
  attr :file, :map, required: true

  defp file_tree(assigns) do
    assigns = assign(assigns, :node, assigns.dirs[assigns.dir])

    ~H"""
    <div :if={@node} id={tree_id(@dir)}>
      <p :if={@node.error} class="review-hint muted" role="status">{@node.error}</p>
      <p :if={@node.listing && @node.listing.entries == []} class="review-hint muted">
        No reviewable files on this page.
      </p>
      <ul :if={@node.listing} class={["review-list", @dir != "" && "review-subtree"]}>
        <li :for={entry <- @node.listing.entries}>
          <%= if entry.type == "dir" do %>
            <% expanded? = Map.has_key?(@dirs, entry.path) %>
            <button
              type="button"
              class="review-file review-folder mono"
              phx-click="review_dir"
              phx-value-dir={entry.path}
              aria-expanded={to_string(expanded?)}
              aria-controls={if expanded?, do: tree_id(entry.path)}
              title={entry.path}
            ><span aria-hidden="true">{if expanded?, do: "▾", else: "▸"}</span>{entry.name}/</button>
            <.file_tree :if={expanded?} dir={entry.path} dirs={@dirs} file={@file} />
          <% else %>
            <button
              type="button"
              class="review-file review-tree-file mono"
              phx-click="review_open"
              phx-value-path={entry.path}
              aria-current={if @file && @file.path == entry.path, do: "true"}
              title={entry.path}
            >{entry.name}</button>
          <% end %>
        </li>
      </ul>
      <.pager page={@node.page} listing={@node.listing} event="review_page" dir={@dir} />
    </div>
    """
  end

  attr :page, :integer, required: true
  attr :listing, :map, required: true
  attr :event, :string, required: true
  attr :dir, :string, default: nil

  defp pager(assigns) do
    ~H"""
    <div :if={@page > 0 || (@listing && @listing.next?)} class="review-toolbar review-pager">
      <button
        type="button"
        class="btn btn-sm"
        phx-click={@event}
        phx-value-dir={@dir}
        phx-value-direction="prev"
        disabled={@page == 0}
      >Previous</button>
      <small class="muted">Page {@page + 1}</small>
      <button
        type="button"
        class="btn btn-sm"
        phx-click={@event}
        phx-value-dir={@dir}
        phx-value-direction="next"
        disabled={!@listing || !@listing.next?}
      >Next</button>
    </div>
    """
  end

  defp tree_id(dir), do: "review-dir-" <> Base.url_encode64(dir, padding: false)

  defp deleted?(%{status: status}), do: status == "D"

  defp deleted?(entry),
    do: entry[:working] == "D" || (entry[:staged] == "D" && !entry[:untracked])

  defp comment(
         %{
           session: %{archived: false},
           session_id: sid,
           conversation_id: cid,
           commit: commit,
           file: %{path: path}
         },
         %{
           "note" => note,
           "path" => submitted_path,
           "revision" => rev,
           "range" => range,
           "request_id" => id,
           "action" => action,
           "source" => source
         }
       )
       when path == submitted_path and action in ["save", "ask"] and is_binary(note) and
              byte_size(note) in 1..8000 and is_binary(id) and byte_size(id) == 36 do
    with true <- comment_source?(commit, source) || {:error, :invalid_comment},
         true <- (String.valid?(note) and String.trim(note) != "") || {:error, :empty_comment},
         {:ok, %{kind: :text, revision: ^rev, text: text, archived: false}} <-
           Backend.read_review_file(sid, path, source),
         {:ok, location, excerpt} <- extract(text, range) do
      context = if commit && source != commit.id, do: " · parent of #{commit.id}", else: ""

      content =
        "File review · #{path}:#{location} (#{source}, sha256 #{rev})#{context}\n\n#{String.trim(note)}\n\nSelected text:\n#{excerpt}"

      Backend.execute_command(sid, %{
        "version" => 1,
        "command" => "submit",
        "conversation_id" => cid,
        "request_id" => "review-" <> id,
        "args" => %{
          "type" => if(action == "ask", do: "input", else: "write"),
          "content" => content
        }
      })
    else
      {:ok, %{archived: true}} -> {:error, :read_only}
      {:ok, _} -> {:error, :file_changed}
      {:error, _} = error -> error
    end
  end

  defp comment(_, _), do: {:error, :invalid_comment}

  defp comment_source?(nil, source), do: source in ["working", "head"]

  defp comment_source?(%{id: id, base: base}, source),
    do: source == id or (base not in [nil, "empty"] and source == base)

  # Monaco and browsers return 1-based lines and UTF-16 columns. Extract from
  # the verified file on the server rather than trusting a client excerpt.
  defp extract(text, [sl, sc, el, ec])
       when is_integer(sl) and is_integer(el) and is_integer(sc) and is_integer(ec) and
              sl in 1..@max_line and el in sl..@max_line//1 and sc in 1..@max_line and
              ec in 1..@max_line and
              (el > sl or ec > sc) and el - sl <= @max_excerpt do
    text =
      case text do
        <<0xEF, 0xBB, 0xBF, rest::binary>> -> rest
        _ -> text
      end

    lines = Regex.split(~r/\r\n|\n|\r/, text)
    selected = lines |> Enum.drop(sl - 1) |> Enum.take(el - sl + 1)

    with true <- length(selected) == el - sl + 1,
         bytes =
           selected |> Enum.join("\n") |> :unicode.characters_to_binary(:utf8, {:utf16, :little}),
         last_bytes = utf16_bytes(List.last(selected)),
         first_bytes = utf16_bytes(hd(selected)),
         start = (sc - 1) * 2,
         finish = byte_size(bytes) - last_bytes + (ec - 1) * 2,
         true <- start <= first_bytes and finish <= byte_size(bytes) and finish > start,
         excerpt when is_binary(excerpt) <-
           :unicode.characters_to_binary(
             binary_part(bytes, start, finish - start),
             {:utf16, :little}
           ),
         true <- byte_size(excerpt) <= @max_excerpt do
      {:ok, "#{sl}:#{sc}–#{el}:#{ec}", excerpt}
    else
      _ -> {:error, :invalid_selection}
    end
  end

  defp extract(_, _), do: {:error, :invalid_selection}

  defp utf16_bytes(text),
    do: byte_size(:unicode.characters_to_binary(text, :utf8, {:utf16, :little}))

  defp reply(socket, {:ok, result}), do: {:reply, %{ok: true, result: result}, socket}

  defp reply(socket, {:error, :file_changed}),
    do: {:reply, %{ok: false, code: "file_changed", error: error_message(:file_changed)}, socket}

  defp reply(socket, {:error, reason}),
    do: {:reply, %{ok: false, error: error_message(reason)}, socket}

  def error_message(:enoent), do: "File or directory no longer exists."
  def error_message(:not_in_head), do: "This file does not exist in HEAD."
  def error_message(:not_in_commit), do: "This file does not exist in the selected revision."
  def error_message(:invalid_commit), do: "Enter a full or abbreviated commit hash."
  def error_message(:commit_unavailable), do: "Commit not found or the hash is ambiguous."
  def error_message(:git_unavailable), do: "Git history is unavailable."
  def error_message(:tree_too_large), do: "This directory exceeds the review listing limit."
  def error_message(:file_too_large), do: "File exceeds the review size limit."
  def error_message(:unsupported_binary), do: "This binary format cannot be previewed."
  def error_message(:not_text), do: "Not a UTF-8 text file."

  def error_message(:file_changed),
    do: "The file changed on disk. Reload before saving or commenting."

  def error_message(:workspace_busy),
    do: "An agent is writing in this workspace. Try again when it is idle."

  def error_message(:read_only), do: "This session is read-only."
  def error_message(:historical_file), do: "Files from a commit are read-only."
  def error_message(:empty_comment), do: "Enter a comment first."
  def error_message(:invalid_selection), do: "Select a passage of up to 12 KB in the saved file."
  def error_message(:invalid_comment), do: "Select a passage and enter a comment of up to 8 KB."
  def error_message(:symlink_not_followed), do: "Symlinks cannot be opened in the review browser."
  def error_message(:invalid_path), do: "Invalid workspace-relative file path."
  def error_message(_), do: "The workspace operation could not be completed."
end
