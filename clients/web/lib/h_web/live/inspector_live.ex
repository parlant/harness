defmodule HWeb.InspectorLive do
  @moduledoc "Sticky, owner-authenticated feedback surface independent of the routed LiveView."
  use Phoenix.LiveView, layout: false, log: false
  use HWeb, :verified_routes
  alias HWeb.{Backend, Inspector}

  on_mount {HWeb.Auth, :require_owner}

  @impl true
  def mount(_params, _session, socket) do
    if Application.get_env(:harness_web, :inspector_workspace) do
      {:ok, assign(socket, session_id: Inspector.session_id(), seq: nil, recent: [])}
    else
      {:ok, redirect(socket, to: ~p"/")}
    end
  end

  @impl true
  def handle_event("watch", _params, socket), do: {:noreply, watch(socket)}

  def handle_event("unwatch", _params, socket) do
    Backend.unsubscribe_conversation(socket.assigns.session_id, 1)
    {:noreply, assign(socket, seq: nil, recent: [])}
  end

  def handle_event("feedback", params, socket) do
    reply =
      case Inspector.submit(params) do
        {:ok, _receipt} ->
          %{ok: true}

        {:error, :invalid_image} ->
          %{error: "Invalid or oversized screenshot."}

        {:error, :invalid_feedback} ->
          %{error: "Check the target and feedback (8 KB maximum)."}

        {:error, _} ->
          %{error: "Feedback not confirmed. Check the feedback session before retrying."}
      end

    socket = if reply[:ok] && is_nil(socket.assigns.seq), do: watch(socket), else: socket
    {:reply, reply, socket}
  end

  @impl true
  def handle_info({:commit_frame, seq, json}, socket) do
    current = socket.assigns.seq

    if current && seq > current do
      frame = JSON.decode!(json)

      if frame["prev_seq"] == current do
        {:noreply, append_activity(socket, frame["appended_entries"], seq)}
      else
        {:noreply, watch(socket)}
      end
    else
      {:noreply, socket}
    end
  end

  # The floating summary follows committed notes and replies, not token deltas.
  def handle_info({:ephemeral_frame, _}, socket), do: {:noreply, socket}

  defp watch(socket) do
    case Backend.subscribe_conversation(socket.assigns.session_id, 1, self(), nil) do
      {:ok, {:snapshot, seq, json}} ->
        append_activity(assign(socket, :recent, []), JSON.decode!(json)["entries"], seq)

      {:error, _} ->
        assign(socket, seq: nil, recent: [])
    end
  end

  defp append_activity(socket, entries, seq) do
    previews =
      for %{"kind" => kind, "data" => data} <- entries,
          kind in ["user", "assistant"],
          text = preview(data),
          text != "",
          do: {kind, text}

    assign(socket, seq: seq, recent: Enum.take(socket.assigns.recent ++ previews, -3))
  end

  defp preview(data) do
    (data["content"] || data["text"])
    |> List.wrap()
    |> Enum.flat_map(fn
      %{"type" => "text", "text" => text} when is_binary(text) -> [text]
      text when is_binary(text) -> [text]
      _ -> []
    end)
    |> Enum.join("\n")
    |> String.slice(0, 400)
  end
end
