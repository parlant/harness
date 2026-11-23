defmodule H.Daemon.SignalHandler do
  @moduledoc false
  @behaviour :gen_event

  def install(owner) when is_pid(owner) do
    :os.set_signal(:sigterm, :handle)

    case :gen_event.which_handlers(:erl_signal_server) do
      handlers when is_list(handlers) ->
        cond do
          __MODULE__ in handlers ->
            :gen_event.call(:erl_signal_server, __MODULE__, {:set_owner, owner})

          :erl_signal_handler in handlers ->
            :gen_event.swap_handler(
              :erl_signal_server,
              {:erl_signal_handler, :swap},
              {__MODULE__, owner}
            )

          true ->
            :gen_event.add_handler(:erl_signal_server, __MODULE__, owner)
        end
    end
  catch
    :exit, _ -> {:error, :signal_server_unavailable}
  end

  def uninstall do
    case :gen_event.which_handlers(:erl_signal_server) do
      handlers when is_list(handlers) ->
        if __MODULE__ in handlers do
          :gen_event.swap_handler(
            :erl_signal_server,
            {__MODULE__, :restore},
            {:erl_signal_handler, []}
          )
        else
          :ok
        end
    end
  catch
    :exit, _ -> :ok
  end

  @impl true
  def init({owner, _prev_term}) when is_pid(owner), do: init(owner)

  def init(owner) when is_pid(owner) do
    {:ok, prev_state} = :erl_signal_handler.init([])
    {:ok, %{owner: owner, prev: prev_state}}
  end

  @impl true
  def handle_event(:sigterm, %{owner: owner} = state) do
    if Process.alive?(owner) do
      send(owner, {:os_signal, :sigterm})
    else
      :init.stop()
    end

    {:ok, state}
  end

  def handle_event(signal, %{prev: prev} = state) do
    case :erl_signal_handler.handle_event(signal, prev) do
      {:ok, next_prev} -> {:ok, %{state | prev: next_prev}}
      other -> other
    end
  end

  @impl true
  def handle_call({:set_owner, owner}, state) when is_pid(owner) do
    {:ok, :ok, %{state | owner: owner}}
  end

  def handle_call(request, %{prev: prev} = state) do
    case :erl_signal_handler.handle_call(request, prev) do
      {:ok, reply, next_prev} -> {:ok, reply, %{state | prev: next_prev}}
      other -> other
    end
  end

  @impl true
  def handle_info(msg, %{prev: prev} = state) do
    case :erl_signal_handler.handle_info(msg, prev) do
      {:ok, next_prev} -> {:ok, %{state | prev: next_prev}}
      other -> other
    end
  end

  @impl true
  def terminate(arg, %{prev: prev}) do
    :erl_signal_handler.terminate(arg, prev)
  end

  @impl true
  def code_change(_old_vsn, state, _extra), do: {:ok, state}
end
