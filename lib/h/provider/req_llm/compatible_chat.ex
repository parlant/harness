defmodule H.Provider.ReqLLM.CompatibleChat do
  @moduledoc false

  alias ReqLLM.Providers.OpenAI.ChatAPI
  alias ReqLLM.Streaming.Decoder

  def stream(model, context, opts) do
    ReqLLM.Streaming.start_stream(__MODULE__, model, context, opts)
  end

  # ReqLLM 1.30's Finch client logs the full body of non-2xx responses.
  # Use the same Finch pool, Chat API codec, and ReqLLM stream server, but
  # surface only the status. Never follow redirects or retry inside transport.
  def stream_transport(_model, _opts), do: :in_process

  def attach_in_process_stream(model, context, opts) do
    %H.Credentials.Redacted{value: key} = Keyword.fetch!(opts, :named_key)
    url = Keyword.fetch!(opts, :base_url) <> ChatAPI.path()

    body =
      context
      |> ChatAPI.Request.build_body(
        model.id,
        Keyword.merge(opts, stream: true, req_llm_model: model),
        :chat
      )
      |> Map.delete(:max_completion_tokens)
      |> Map.put(:max_tokens, opts[:max_tokens])
      |> ReqLLM.Schema.apply_property_ordering()
      |> Jason.encode!()

    request =
      Finch.build(
        :post,
        url,
        [
          {"authorization", "Bearer " <> key},
          {"content-type", "application/json"},
          {"accept", "text/event-stream"}
        ],
        body
      )

    timeout = Keyword.fetch!(opts, :receive_timeout)
    finch = ReqLLM.Application.finch_name()

    {:ok,
     Stream.resource(
       fn ->
         ref = Finch.async_request(request, finch, receive_timeout: timeout)
         {ref, Decoder.new(provider_mod: __MODULE__, model: model)}
       end,
       &receive_chunks(&1, timeout),
       fn {ref, _} -> Finch.cancel_async_request(ref) end
     )}
  rescue
    _ -> {:error, :invalid_chat_request}
  end

  # Discard provider-controlled error text/codes instead of guessing which
  # formats might contain echoed credentials.
  def decode_stream_event(%{data: %{"error" => _}}, _model) do
    [
      ReqLLM.StreamChunk.meta(%{
        finish_reason: :error,
        error: :chat_stream_failed,
        terminal?: true
      })
    ]
  end

  defdelegate decode_stream_event(event, model), to: ChatAPI

  defp receive_chunks({ref, decoder} = state, timeout) do
    receive do
      {^ref, {:status, status}} when status in 200..299 ->
        {[], state}

      {^ref, {:status, status}} ->
        {[{:error, {:compatible_http_status, status}}], state}

      {^ref, {:headers, _}} ->
        {[], state}

      {^ref, {:data, bytes}} ->
        case Decoder.decode(bytes, decoder) do
          {:ok, chunks, _, decoder} -> {chunks, {ref, decoder}}
          {:error, _, _} -> {[{:error, :chat_stream_failed}], state}
        end

      {^ref, :done} ->
        # InProcessClient stops on terminal chunks (including a usage-only
        # last frame or [DONE]). An EOF without either is an interrupted turn.
        {chunks, terminal?, decoder} = Decoder.flush_protocol(decoder)
        tail = if terminal?, do: [], else: [{:error, :chat_stream_interrupted}]
        {chunks ++ tail, {ref, decoder}}

      {^ref, {:error, _}} ->
        {[{:error, :chat_transport_failed}], state}
    after
      timeout -> {[{:error, :chat_timeout}], state}
    end
  rescue
    _ -> {[{:error, :chat_stream_failed}], state}
  end
end
