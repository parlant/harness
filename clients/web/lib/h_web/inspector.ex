defmodule HWeb.Inspector do
  @moduledoc """
  Owner UI feedback goes to one coding session rooted at the configured web
  checkout, never to the workspace or branch currently on screen. A note is a
  normal write-only submission; only an explicit ask starts/queues work.
  """
  alias HWeb.Backend

  @session_id "web-ui-feedback"
  @max_encoded 524_288

  def session_id, do: @session_id

  def submit(
        %{
          "action" => action,
          "note" => note,
          "path" => path,
          "target" => target,
          "request_id" => id
        } = params
      )
      when action in ["save", "ask"] and is_binary(note) and byte_size(note) in 1..8000 and
             is_binary(target) and byte_size(target) in 1..600 and is_binary(path) and
             byte_size(path) in 1..512 and is_binary(id) and byte_size(id) == 36 do
    with cwd when is_binary(cwd) <- Application.get_env(:harness_web, :inspector_workspace),
         true <-
           String.trim(note) != "" and String.starts_with?(path, "/") and
             not String.contains?(path, ["?", "#", "\n"]),
         {:ok, images} <- image_blocks(params["image"]),
         {:ok, %{session: session}} <-
           Backend.create_session(%{
             "cwd" => cwd,
             "session_id" => @session_id,
             "title" => "Web UI feedback"
           }) do
      content = [
        %{
          "type" => "text",
          "text" => "Web UI feedback · #{path}\nElement: #{target}\n\n#{String.trim(note)}"
        }
        | images
      ]

      Backend.execute_command(@session_id, %{
        "version" => 1,
        "command" => "submit",
        "conversation_id" => session.root_conversation_id,
        "request_id" => "inspector-" <> id,
        "args" => %{
          "type" => if(action == "ask", do: "input", else: "write"),
          "content" => content
        }
      })
    else
      {:error, _} = error -> error
      _ -> {:error, :invalid_feedback}
    end
  end

  def submit(_), do: {:error, :invalid_feedback}

  defp image_blocks(nil), do: {:ok, []}

  defp image_blocks(data) when is_binary(data) and byte_size(data) <= @max_encoded do
    with {:ok, <<255, 216, 255, _::binary>> = bytes} <- Base.decode64(data),
         true <- :binary.last(bytes) == 217 and :binary.at(bytes, byte_size(bytes) - 2) == 255 do
      {:ok,
       [
         %{
           "type" => "image",
           "encoding" => "base64",
           "media_type" => "image/jpeg",
           "data" => data
         }
       ]}
    else
      _ -> {:error, :invalid_image}
    end
  end

  defp image_blocks(_), do: {:error, :invalid_image}
end
