defmodule H.Provider.VertexExpress do
  @moduledoc false

  alias ReqLLM.Providers.GoogleVertex

  # ReqLLM 1.30 formats Vertex Gemini requests and decodes their streams,
  # but only builds project-scoped, bearer-authenticated URLs. Keep its wire
  # format and replace just the route and authentication for Express Mode.
  def stream(model, context, opts) do
    ReqLLM.Streaming.start_stream(__MODULE__, model, context, opts)
  end

  def attach_stream(model, context, opts, finch_name) do
    {api_key, opts} = Keyword.pop!(opts, :api_key)

    opts =
      Keyword.merge(opts,
        project_id: "express",
        region: "global",
        access_token: "express"
      )

    with {:ok, %Finch.Request{path: path} = request} <-
           GoogleVertex.attach_stream(model, context, opts, finch_name),
         "/v1/projects/express/locations/global/publishers/google/" <> endpoint <- path do
      headers =
        Enum.reject(request.headers, fn {k, _} -> String.downcase(k) == "authorization" end)

      {:ok,
       %{
         request
         | path: "/v1/publishers/google/" <> endpoint,
           query: "alt=sse",
           headers: [{"x-goog-api-key", api_key} | headers]
       }}
    else
      {:error, _} = error -> error
      _ -> {:error, "Unsupported Vertex Express Mode route"}
    end
  end

  defdelegate parse_stream_protocol(chunk, state), to: GoogleVertex
  defdelegate init_stream_state(model), to: GoogleVertex
  defdelegate decode_stream_event(event, model, state), to: GoogleVertex
  defdelegate flush_stream_state(model, state), to: GoogleVertex
end
