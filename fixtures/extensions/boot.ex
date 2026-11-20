defmodule Fixture.BootExtension do
  @behaviour H.Extension

  @impl true
  def configure(%{"instructions" => "duplicate profile"}, _context) do
    {:ok, %{harnesses: [__MODULE__.Profile, __MODULE__.Profile]}}
  end

  def configure(%{"instructions" => text}, context) do
    {:ok,
     %{
       harnesses: [__MODULE__.Profile],
       environments: [
         %{
           id: "fixture.env",
           label: "Fixture",
           kind: "host",
           default_cwd: context.data_dir,
           build: fn cwd -> H.ExecutionEnv.Host.new(cwd, env_id: "fixture.env") end
         }
       ],
       children: [{__MODULE__.Probe, text}]
     }}
  end

  def configure(_, _), do: {:error, :invalid_settings}

  defmodule Probe do
    use Agent

    def start_link("fail to start"), do: {:error, :probe_start_failed}
    def start_link(text), do: Agent.start_link(fn -> text end, name: __MODULE__)
  end

  defmodule Profile do
    @behaviour H.Harness

    @impl true
    def id, do: "fixture.profile"

    @impl true
    def descriptor, do: %{id: id(), name: "Fixture", description: "Test profile"}

    @impl true
    def tools(_opts), do: [__MODULE__.Constant]

    @impl true
    def bootstrap_agent(_env, overrides, _opts) do
      case Agent.get(Fixture.BootExtension.Probe, & &1) do
        "bad bootstrap" -> {:error, :bootstrap_failed}
        text -> {:ok, Map.merge(%{instructions: text, tools: ["fixture_constant"]}, overrides)}
      end
    end

    defmodule Constant do
      @behaviour H.Tool
      @impl true
      def name, do: "fixture_constant"
      @impl true
      def description, do: "Returns a constant"
      @impl true
      def parameters_schema, do: %{"type" => "object", "additionalProperties" => false}
      @impl true
      def replay, do: :safe
      @impl true
      def mutating?, do: false
      @impl true
      def execute(%{}, _ctx) do
        {:ok,
         %{
           content: [%{"type" => "text", "text" => "constant"}],
           details: %{},
           is_error: false,
           diagnostic: nil
         }}
      end
    end
  end
end
