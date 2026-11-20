defmodule Example.Greeting do
  @behaviour H.Extension

  @impl true
  def configure(settings, _context) do
    case settings do
      %{} when map_size(settings) == 0 ->
        configure(%{"instructions" => "This is the greeting profile."}, %{})

      %{"instructions" => text}
      when map_size(settings) == 1 and is_binary(text) and byte_size(text) in 1..1024 ->
        {:ok, %{harnesses: [__MODULE__.Profile], children: [{__MODULE__.Instructions, text}]}}

      _ ->
        {:error, :invalid_settings}
    end
  end

  defmodule Instructions do
    @moduledoc false
    use Agent

    def start_link(text), do: Agent.start_link(fn -> text end, name: __MODULE__)
  end

  defmodule Profile do
    @behaviour H.Harness

    @impl true
    def id, do: "example.greeting.v1"

    @impl true
    def descriptor,
      do: %{id: id(), name: "Greeting", description: "A deterministic example profile"}

    @impl true
    def tools(_opts), do: []

    @impl true
    def bootstrap_agent(_env, overrides, _opts) do
      {:ok, Map.put_new(overrides, :instructions, Agent.get(Example.Greeting.Instructions, & &1))}
    end
  end
end
