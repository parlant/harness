defmodule HWeb.ReviewLive do
  use HWeb, :live_view

  alias HWeb.{Backend, InboxFilter, Workbench}

  @refresh_ms 2500
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
         dir: "",
         page: 0,
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
    socket = refresh(socket)
    Process.send_after(self(), :review_refresh, @refresh_ms)
    {:noreply, socket}
  end

  @impl true
  def handle_event("review_tab", %{"tab" => tab}, socket) when tab in ["changes", "files"] do
    {:noreply, refresh(assign(socket, tab: tab))}
  end

  def handle_event("review_dir", %{"dir" => dir}, socket)
      when is_binary(dir) and byte_size(dir) <= 4096 do
    {:noreply, refresh(assign(socket, dir: dir, page: 0))}
  end

  def handle_event("review_page", %{"direction" => dir}, socket) when dir in ["prev", "next"] do
    page = max(0, socket.assigns.page + if(dir == "prev", do: -1, else: 1))
    {:noreply, refresh(assign(socket, page: page))}
  end

  def handle_event("review_open", %{"path" => path} = params, socket)
      when is_binary(path) and byte_size(path) in 1..4096 do
    {:noreply, assign(socket, file: %{path: path, deleted?: params["deleted"] == "true"})}
  end

  def handle_event("review_save", %{"path" => path, "revision" => rev, "text" => text}, socket) do
    case socket.assigns do
      %{session: %{archived: false}, file: %{path: ^path}} ->
        reply(socket, Backend.save_review_file(socket.assigns.session_id, path, rev, text))

      _ ->
        reply(socket, {:error, :read_only})
    end
  end

  def handle_event("review_comment", params, socket) do
    reply(socket, comment(socket.assigns, params))
  end

  def handle_event(_, _, socket), do: {:noreply, socket}

  defp refresh(socket) do
    a = socket.assigns

    case Backend.review_workspace(a.session_id, %{
           dir: a.dir,
           page: a.page,
           changes?: a.tab == "changes"
         }) do
      {:ok, browser} ->
        tab = if browser.git == :not_git, do: "files", else: a.tab

        assign(socket,
          browser: browser,
          browser_error: nil,
          session: %{a.session | archived: browser.archived},
          tab: tab,
          git_available?:
            if(a.tab == "changes", do: browser.git != :not_git, else: a.git_available?)
        )

      {:error, reason} ->
        assign(socket, browser: nil, browser_error: error_message(reason))
    end
  end

  defp comment(
         %{
           session: %{archived: false},
           session_id: sid,
           conversation_id: cid,
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
       when path == submitted_path and action in ["save", "ask"] and source in ["working", "head"] and
              is_binary(note) and
              byte_size(note) in 1..8000 and is_binary(id) and byte_size(id) == 36 do
    with true <- (String.valid?(note) and String.trim(note) != "") || {:error, :empty_comment},
         {:ok, %{kind: :text, revision: ^rev, text: text, archived: false}} <-
           Backend.read_review_file(sid, path, if(source == "head", do: :head, else: :working)),
         {:ok, location, excerpt} <- extract(text, range) do
      content =
        "File review · #{path}:#{location} (#{source}, sha256 #{rev})\n\n#{String.trim(note)}\n\nSelected text:\n#{excerpt}"

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
  def error_message(:file_too_large), do: "File exceeds the review size limit."
  def error_message(:unsupported_binary), do: "This binary format cannot be previewed."
  def error_message(:not_text), do: "Not a UTF-8 text file."

  def error_message(:file_changed),
    do: "The file changed on disk. Reload before saving or commenting."

  def error_message(:workspace_busy),
    do: "An agent is writing in this workspace. Try again when it is idle."

  def error_message(:read_only), do: "This session is read-only."
  def error_message(:empty_comment), do: "Enter a comment first."
  def error_message(:invalid_selection), do: "Select a passage of up to 12 KB in the saved file."
  def error_message(:invalid_comment), do: "Select a passage and enter a comment of up to 8 KB."
  def error_message(:symlink_not_followed), do: "Symlinks cannot be opened in the review browser."
  def error_message(:invalid_path), do: "Invalid workspace-relative file path."
  def error_message(_), do: "The workspace operation could not be completed."
end
