defmodule Example.GreetingTest do
  use ExUnit.Case, async: true

  alias Example.Greeting

  test "validates settings and leaves process creation to the daemon" do
    assert {:error, :invalid_settings} = Greeting.configure(%{"unexpected" => true}, %{})

    assert {:ok, %{harnesses: [Greeting.Profile], children: [child]}} =
             Greeting.configure(%{"instructions" => "Hello from an extension"}, %{})

    refute Process.whereis(Greeting.Instructions)
    start_supervised!(child)

    assert {:ok, %{instructions: "Hello from an extension"}} =
             Greeting.Profile.bootstrap_agent(nil, %{}, [])

    assert {:ok, %{instructions: "Override"}} =
             Greeting.Profile.bootstrap_agent(nil, %{instructions: "Override"}, [])

    assert Greeting.Profile.tools([]) == []
  end
end
