defmodule H.SchemaTest do
  use ExUnit.Case, async: true

  alias H.Schema

  describe "validate_map/2" do
    test "validates string-keyed JSON maps, applies defaults, and omits unknown keys without creating atoms" do
      unique_unknown = "never_interned_atom_#{System.unique_integer([:positive])}"

      input = %{
        "request_id" => "req-1",
        "version" => 1,
        "conversation_id" => "1",
        unique_unknown => "ignored"
      }

      specs = [
        {:request_id, :non_empty_string, required: true},
        {:version, {:literal, 1}, required: true},
        {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"},
        {:conversation_id, :id_string, required: false},
        {:limit, {:int, min: 1, max: 200}, default: 50}
      ]

      assert {:ok,
              %{
                request_id: "req-1",
                version: 1,
                when_busy: "follow_up",
                conversation_id: "1",
                limit: 50
              }} = Schema.validate_map(input, specs)

      assert_raise ArgumentError, fn ->
        String.to_existing_atom(unique_unknown)
      end
    end

    test "accepts atom keys from internal Elixir callers" do
      specs = [
        {:session_id, :session_id, required: true},
        {:cwd, :abs_path, required: true},
        {:active, :boolean, default: false}
      ]

      assert {:ok, %{session_id: "demo", cwd: "/tmp/work", active: false}} =
               Schema.validate_map(%{session_id: "demo", cwd: "/tmp/work"}, specs)
    end

    test "validates int bounds, nested maps, lists, and nullable fields" do
      specs = [
        {:limit, {:int, min: 1, max: 200}, required: true},
        {:title, :string, nullable: true},
        {:tags, {:list, :non_empty_string}, default: []},
        {:args, {:map, [{:text, :non_empty_string, required: true}]}}
      ]

      assert {:ok, %{limit: 200, title: nil, tags: ["a", "b"], args: %{text: "hi"}}} =
               Schema.validate_map(
                 %{
                   "limit" => 200,
                   "title" => nil,
                   "tags" => ["a", "b"],
                   "args" => %{"text" => "hi"}
                 },
                 specs
               )

      assert {:error, "limit: must be <= 200"} = Schema.validate_map(%{"limit" => 201}, specs)
      assert {:error, "limit: must be >= 1"} = Schema.validate_map(%{"limit" => 0}, specs)

      assert {:error, "args: text is required"} =
               Schema.validate_map(%{"limit" => 10, "args" => %{}}, specs)
    end

    test "rejects missing required fields, bad types, and non-map inputs" do
      specs = [
        {:request_id, :non_empty_string, required: true},
        {:version, {:literal, 1}, required: true},
        {:when_busy, {:enum, ["follow_up", "steer", "reject"]}, default: "follow_up"}
      ]

      assert {:error, "request_id is required"} = Schema.validate_map(%{"version" => 1}, specs)

      assert {:error, "request_id: must be a non-empty string"} =
               Schema.validate_map(%{"request_id" => "   ", "version" => 1}, specs)

      assert {:error, "version: must equal 1"} =
               Schema.validate_map(%{"request_id" => "r1", "version" => 2}, specs)

      assert {:error, "when_busy: must be one of [\"follow_up\", \"steer\", \"reject\"]"} =
               Schema.validate_map(
                 %{"request_id" => "r1", "version" => 1, "when_busy" => "abort"},
                 specs
               )

      assert {:error, "expected a map"} = Schema.validate_map(["not", "a", "map"], specs)
    end
  end

  describe "validate_session_id/1" do
    test "accepts valid alphanumeric, dot, underscore, and hyphen IDs" do
      assert {:ok, "a"} = Schema.validate_session_id("a")
      assert {:ok, "demo_session-1.2"} = Schema.validate_session_id("demo_session-1.2")
      max_id = String.duplicate("x", 128)
      assert {:ok, ^max_id} = Schema.validate_session_id(max_id)
    end

    test "rejects path traversal, slashes, leading punctuation, overlong IDs, and non-strings" do
      assert {:error, _} = Schema.validate_session_id("../escape")
      assert {:error, _} = Schema.validate_session_id("a/b")
      assert {:error, _} = Schema.validate_session_id(".hidden")
      assert {:error, _} = Schema.validate_session_id("-dash")
      assert {:error, _} = Schema.validate_session_id("")
      assert {:error, _} = Schema.validate_session_id(String.duplicate("x", 129))
      assert {:error, _} = Schema.validate_session_id(123)
    end
  end

  describe "parse_pos_int/1" do
    test "parses positive integers from integers and digit strings" do
      assert {:ok, 1} = Schema.parse_pos_int(1)
      assert {:ok, 42} = Schema.parse_pos_int(42)
      assert {:ok, 42} = Schema.parse_pos_int("42")
    end

    test "rejects zero, negative values, signs, whitespace, and non-integers" do
      assert {:error, _} = Schema.parse_pos_int(0)
      assert {:error, _} = Schema.parse_pos_int("0")
      assert {:error, _} = Schema.parse_pos_int(-5)
      assert {:error, _} = Schema.parse_pos_int("-5")
      assert {:error, _} = Schema.parse_pos_int("+42")
      assert {:error, _} = Schema.parse_pos_int("42abc")
      assert {:error, _} = Schema.parse_pos_int(" 42")
      assert {:error, _} = Schema.parse_pos_int(nil)
    end
  end
end
