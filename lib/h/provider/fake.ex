defmodule H.Provider.Fake do
  @moduledoc """
  Deterministic scripted `H.Provider` for `--no-start` unit and recovery tests.

  Steps in `script: [...]` are consumed strictly in FIFO order. Any call to
  `stream_turn/3` when the script queue is exhausted raises
  `H.Provider.Fake.UnscriptedRequestError` (or returns an error if
  `on_unscripted: :error` is configured) rather than repeating an earlier answer.
  """

  @behaviour H.Provider

  use GenServer

  defmodule UnscriptedRequestError do
    @moduledoc "Raised when `H.Provider.Fake` receives a turn after its scripted steps are exhausted."
    defexception [:message, :request]
  end

  @default_models [
    %{
      id: "fake:chat",
      provider: "fake",
      name: "Fake Chat",
      context_window: 128_000,
      max_output_tokens: 8_192,
      supports_tools: true,
      supports_reasoning: true
    },
    %{
      id: "fake:coder",
      provider: "fake",
      name: "Fake Coder",
      context_window: 200_000,
      max_output_tokens: 16_384,
      supports_tools: true,
      supports_reasoning: true
    }
  ]

  # Client API

  @spec start_link(keyword()) :: GenServer.on_start()
  def start_link(opts \\ []) do
    {gen_opts, init_opts} = Keyword.split(opts, [:name])
    GenServer.start_link(__MODULE__, init_opts, gen_opts)
  end

  @doc """
  Returns all requests passed to `stream_turn/3` in arrival order.
  """
  @spec requests(GenServer.server()) :: [map()]
  def requests(server \\ __MODULE__) do
    GenServer.call(server, :requests)
  end

  @doc """
  Returns the remaining scripted steps.
  """
  @spec remaining(GenServer.server()) :: [term()]
  def remaining(server \\ __MODULE__) do
    GenServer.call(server, :remaining)
  end

  @doc """
  Appends a step to the script queue.
  """
  @spec push_step(GenServer.server(), term()) :: :ok
  def push_step(server \\ __MODULE__, step) do
    GenServer.call(server, {:push_step, step})
  end

  @impl H.Provider
  def stream_turn(config, request, emit)
      when is_map(config) and is_map(request) and is_function(emit, 1) do
    server = resolve_server(config)

    case GenServer.call(server, {:next_step, request}) do
      {:ok, step} ->
        execute_step(step, request, emit)

      :empty ->
        message = "Unscripted request to H.Provider.Fake: no scripted steps remaining"

        if Map.get(config, :on_unscripted) == :error do
          {:error, %{code: "unscripted_request", message: message, retryable: false}}
        else
          raise UnscriptedRequestError, message: message, request: request
        end
    end
  end

  @impl H.Provider
  def list_models(config) when is_map(config) do
    Map.get(config, :models, @default_models)
  end

  # GenServer callbacks

  @impl true
  def init(opts) do
    script = Keyword.get(opts, :script, [])
    {:ok, %{script: script, requests: []}}
  end

  @impl true
  def handle_call({:next_step, request}, _from, %{script: []} = state) do
    {:reply, :empty, %{state | requests: state.requests ++ [request]}}
  end

  def handle_call({:next_step, request}, _from, %{script: [step | rest]} = state) do
    {:reply, {:ok, step}, %{state | script: rest, requests: state.requests ++ [request]}}
  end

  def handle_call(:requests, _from, state) do
    {:reply, state.requests, state}
  end

  def handle_call(:remaining, _from, state) do
    {:reply, state.script, state}
  end

  def handle_call({:push_step, step}, _from, state) do
    {:reply, :ok, %{state | script: state.script ++ [step]}}
  end

  # Step execution (runs in caller process, outside GenServer)

  defp execute_step({:expect, assert_fun, next_step}, request, emit)
       when is_function(assert_fun, 1) do
    case assert_fun.(request) do
      false ->
        raise UnscriptedRequestError,
          message: "Request assertion failed in H.Provider.Fake",
          request: request

      _ ->
        execute_step(next_step, request, emit)
    end
  end

  defp execute_step(fun, request, emit) when is_function(fun, 2) do
    fun.(request, emit)
  end

  defp execute_step({:reply, chunks, final_response}, _request, emit) when is_list(chunks) do
    Enum.each(chunks, emit)
    {:ok, normalize_response(final_response)}
  end

  defp execute_step({:error, error_map}, _request, _emit) when is_map(error_map) do
    {:error, normalize_error(error_map)}
  end

  defp execute_step({:error, chunks, error_map}, _request, emit)
       when is_list(chunks) and is_map(error_map) do
    Enum.each(chunks, emit)
    {:error, normalize_error(error_map)}
  end

  defp execute_step({:gate, notify_pid, wait_ref_or_fun}, request, emit) do
    execute_step({:gate, [], notify_pid, wait_ref_or_fun, %{}}, request, emit)
  end

  defp execute_step({:gate, chunks, notify_pid, wait_ref_or_fun}, request, emit)
       when is_list(chunks) do
    execute_step({:gate, chunks, notify_pid, wait_ref_or_fun, %{}}, request, emit)
  end

  defp execute_step(
         {:gate, chunks, notify_pid, wait_ref_or_fun, final_response},
         _request,
         emit
       )
       when is_list(chunks) do
    Enum.each(chunks, emit)
    await_gate(notify_pid, wait_ref_or_fun, final_response)
  end

  defp await_gate(notify_pid, wait_fun, _final_response) when is_function(wait_fun, 0) do
    send(notify_pid, {:gate_entered, self()})
    wait_fun.()
  end

  defp await_gate(notify_pid, wait_fun, _final_response) when is_function(wait_fun, 1) do
    send(notify_pid, {:gate_entered, self()})
    wait_fun.(self())
  end

  defp await_gate(notify_pid, wait_ref, final_response) do
    send(notify_pid, {:gate_entered, wait_ref, self()})

    receive do
      {:release, ^wait_ref} ->
        {:ok, normalize_response(final_response)}

      {:release, ^wait_ref, result} ->
        result

      {:abort, ^wait_ref} ->
        {:cancelled, %{partial_content: [], usage: %{}}}
    end
  end

  defp resolve_server(config) do
    Map.get(config, :server) ||
      Map.get(config, :fake) ||
      Map.get(config, :pid) ||
      __MODULE__
  end

  defp normalize_response(response) when is_map(response) do
    %{
      content: Map.get(response, :content, []),
      tool_calls: Map.get(response, :tool_calls, []),
      finish_reason: Map.get(response, :finish_reason, "stop"),
      usage: Map.get(response, :usage, %{}),
      provider_meta: Map.get(response, :provider_meta, %{})
    }
  end

  defp normalize_error(error_map) do
    %{
      code: Map.get(error_map, :code) || Map.get(error_map, "code") || "fake_error",
      message: Map.get(error_map, :message) || Map.get(error_map, "message") || "Fake error",
      retryable: Map.get(error_map, :retryable, Map.get(error_map, "retryable", false)) == true
    }
  end
end
