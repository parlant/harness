defmodule HWeb.ConversationComponents do
  @moduledoc "Stateless rendering for committed messages and in-flight conversation activity."
  use HWeb, :html

  alias HWeb.{Activity, Markdown}

  def message?(%{"kind" => "user"}), do: true

  def message?(%{"kind" => "assistant", "data" => data}) do
    String.trim(message_text(data)) != "" or images(data) != []
  end

  def message?(_), do: false

  attr(:entry, :map, required: true)

  def entry_body(assigns) do
    data = assigns.entry["data"]
    assigns = assign(assigns, text: message_text(data), images: images(data))

    ~H"""
    <img
      :for={encoded <- @images}
      src={"data:image/jpeg;base64," <> encoded}
      class="feedback-image"
      alt="Attached screenshot"
      loading="lazy"
    />
    <.assistant_text :if={@entry["kind"] == "assistant" and @text != ""} text={@text} />
    <p :if={@entry["kind"] == "user" and @text != ""} class="entry-text">{@text}</p>
    """
  end

  attr(:text, :string, required: true)

  defp assistant_text(assigns) do
    ~H"""
    <div class="markdown">{Markdown.render(@text)}</div>
    """
  end

  attr(:id, :string, required: true)
  attr(:count, :integer, required: true)
  attr(:status, :atom, required: true)

  def activity_line(assigns) do
    {label, spinning?} =
      case assigns.status do
        :working -> {"Working", true}
        :retrying -> {"Retrying", true}
        :waiting -> {"Waiting", false}
        :paused -> {"Paused", false}
        :failed -> {"Failed", false}
        :stopped -> {"Stopped", false}
        :interrupted -> {"Interrupted", false}
        :incomplete -> {"Incomplete", false}
        :complete -> {"Complete", false}
      end

    assigns = assign(assigns, label: label, spinning?: spinning?)

    ~H"""
    <div id={@id} class="activity-line" data-status={@status}>
      <span :if={@spinning?} class="activity-spinner" aria-hidden="true"></span>
      <span>{@count} {if @count == 1, do: "activity", else: "activities"}</span>
      <span class="activity-status">· {@label}</span>
    </div>
    """
  end

  attr(:live, :map, required: true)
  attr(:inbox, :list, required: true)
  attr(:tail_activity, :any, required: true)

  def live_region(assigns) do
    live = assigns.live
    gen = live["generation"] || %{}
    msg = gen["message"] || gen
    text = message_text(msg)
    streaming_text? = String.trim(text) != ""
    activity = Activity.live_summary(assigns.tail_activity, live, msg, streaming_text?)

    {failure, failure_label} =
      case {live["run_failure"], live["compaction_failure"]} do
        {run_failure, _} when not is_nil(run_failure) ->
          {run_failure, "Run paused"}

        {nil, %{"automatic" => true} = failure} ->
          {failure, "Run paused during automatic compaction"}

        {nil, failure} ->
          {failure, "Compaction failed"}
      end

    assigns =
      assign(assigns,
        activity: activity,
        streaming_text?: streaming_text?,
        text: text,
        failure: failure,
        failure_label: failure_label
      )

    ~H"""
    <section
      :if={@streaming_text? || @activity || @inbox != [] || @failure}
      id="live-region"
      class="live-region"
      aria-live="polite"
    >
      <.activity_line
        :if={@activity}
        id="live-activity"
        count={@activity.count}
        status={@activity.status}
      />
      <article :if={@streaming_text?} id="live-generation" class="entry-card entry-live">
        <header class="entry-header">
          <span class="role-label">assistant (live)</span>
        </header>
        <.assistant_text text={@text} />
      </article>

      <div :if={@inbox != []} id="live-inbox" class="live-inbox">
        <div class="role-label">Queued ({length(@inbox)})</div>
        <div :for={item <- @inbox} class="inbox-item">
          {format_inbox_item(item)}
        </div>
      </div>

      <div :if={@failure} id="run-failure-banner" class="run-failure-banner">
        <div>
          <strong>{@failure_label}:</strong>
          <span>{format_failure(@failure)}</span>
        </div>
        <p :if={@failure_label == "Compaction failed"}>
          History preserved. Retry with <code>/compact</code> in hi.
        </p>
        <button
          :if={@failure_label != "Compaction failed"}
          id="continue-run-btn"
          type="button"
          class="btn btn-sm btn-primary"
          phx-click="continue_run"
        >
          Continue Run
        </button>
      </div>
    </section>
    """
  end

  defp images(data) do
    for %{
          "type" => "image",
          "encoding" => "base64",
          "media_type" => "image/jpeg",
          "data" => encoded
        } <- List.wrap(data["content"]),
        is_binary(encoded),
        do: encoded
  end

  defp message_text(data) do
    text =
      data["content"]
      |> List.wrap()
      |> Enum.flat_map(fn
        %{"type" => "text", "text" => text} when is_binary(text) -> [text]
        text when is_binary(text) -> [text]
        _ -> []
      end)
      |> Enum.join("\n")

    if text == "" and is_binary(data["text"]), do: data["text"], else: text
  end

  defp format_inbox_item(item) when is_map(item) do
    text = message_text(item)
    mode = if item["when_busy"], do: "[#{item["when_busy"]}] ", else: ""
    mode <> if(text != "", do: text, else: format_json(item))
  end

  defp format_inbox_item(other), do: format_json(other)

  defp format_failure(failure) when is_binary(failure), do: failure

  defp format_failure(failure) when is_map(failure) do
    failure["message"] || failure["detail"] || failure["reason"] || format_json(failure)
  end

  defp format_failure(other), do: inspect(other)

  defp format_json(value) when is_binary(value), do: value

  defp format_json(value) do
    JSON.encode!(value)
  rescue
    _ -> inspect(value)
  end
end
