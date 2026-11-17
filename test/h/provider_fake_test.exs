defmodule H.Provider.FakeTest do
  use ExUnit.Case, async: true

  alias H.Provider.Fake
  alias H.Provider.Fake.UnscriptedRequestError

  describe "stream_turn/3" do
    test "executes reply, function, and error steps in strict FIFO order" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [%{type: :text_delta, text: "hello ", metadata: %{}}],
              %{content: [%{type: "text", text: "hello world"}], finish_reason: "stop"}},
             fn req, emit ->
               emit.(%{
                 type: :text_delta,
                 text: req.messages |> List.last() |> hd_text(),
                 metadata: %{}
               })

               {:ok,
                %{
                  content: [%{type: "text", text: "echo"}],
                  tool_calls: [],
                  finish_reason: "stop",
                  usage: %{},
                  provider_meta: %{}
                }}
             end,
             {:error, %{code: "rate_limit", message: "slow down", retryable: true}}
           ]}
        )

      config = %{server: fake}
      collector = start_supervised!({Agent, fn -> [] end})
      emit = fn ev -> Agent.update(collector, &(&1 ++ [ev])) end

      assert {:ok, %{content: [%{type: "text", text: "hello world"}], finish_reason: "stop"}} =
               Fake.stream_turn(
                 config,
                 %{messages: [%{role: "user", content: [%{type: "text", text: "1"}]}]},
                 emit
               )

      assert {:ok, %{content: [%{type: "text", text: "echo"}]}} =
               Fake.stream_turn(
                 config,
                 %{messages: [%{role: "user", content: [%{type: "text", text: "2"}]}]},
                 emit
               )

      assert {:error, %{code: "rate_limit", message: "slow down", retryable: true}} =
               Fake.stream_turn(
                 config,
                 %{messages: [%{role: "user", content: [%{type: "text", text: "3"}]}]},
                 emit
               )

      events = Agent.get(collector, & &1)
      assert [%{type: :text_delta, text: "hello "}, %{type: :text_delta, text: "2"}] = events
      assert length(Fake.requests(fake)) == 3
      assert Fake.remaining(fake) == []
    end

    test "supports deterministic gate pauses and abort/release without sleeps" do
      gate_ref = make_ref()
      test_pid = self()

      fake =
        start_supervised!(
          {Fake,
           script: [
             {:gate, [%{type: :text_delta, text: "partial", metadata: %{}}], test_pid, gate_ref,
              %{content: [%{type: "text", text: "partial done"}], finish_reason: "stop"}},
             {:gate, [], test_pid, gate_ref}
           ]}
        )

      task1 =
        Task.async(fn ->
          Fake.stream_turn(%{server: fake}, %{messages: []}, fn ev ->
            send(test_pid, {:emitted, ev})
          end)
        end)

      assert_receive {:emitted, %{type: :text_delta, text: "partial"}}
      assert_receive {:gate_entered, ^gate_ref, gate_pid1}
      send(gate_pid1, {:release, gate_ref})
      assert {:ok, %{content: [%{type: "text", text: "partial done"}]}} = Task.await(task1)

      task2 =
        Task.async(fn ->
          Fake.stream_turn(%{server: fake}, %{messages: []}, fn _ -> :ok end)
        end)

      assert_receive {:gate_entered, ^gate_ref, gate_pid2}
      send(gate_pid2, {:abort, gate_ref})
      assert {:cancelled, %{partial_content: [], usage: %{}}} = Task.await(task2)
    end

    test "fails explicitly on unscripted requests instead of repeating previous answers" do
      fake =
        start_supervised!(
          {Fake,
           script: [
             {:reply, [], %{content: [%{type: "text", text: "only once"}]}}
           ]}
        )

      assert {:ok, _} = Fake.stream_turn(%{server: fake}, %{messages: []}, fn _ -> :ok end)

      assert_raise UnscriptedRequestError, ~r/no scripted steps remaining/, fn ->
        Fake.stream_turn(%{server: fake}, %{messages: []}, fn _ -> :ok end)
      end

      assert {:error, %{code: "unscripted_request", retryable: false}} =
               Fake.stream_turn(%{server: fake, on_unscripted: :error}, %{messages: []}, fn _ ->
                 :ok
               end)
    end
  end

  describe "list_models/1" do
    test "returns deterministic test models" do
      models = Fake.list_models(%{})
      ids = Enum.map(models, & &1.id)
      assert "fake:chat" in ids
      assert "fake:coder" in ids
      assert is_binary(JSON.encode!(models))
    end
  end

  defp hd_text(%{content: [%{text: text} | _]}), do: text
end
