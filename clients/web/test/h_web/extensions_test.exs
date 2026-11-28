defmodule HWeb.ExtensionsTest do
  use ExUnit.Case, async: true

  alias HWeb.Extensions

  describe "order_sidebar_items/2" do
    @builtins [
      %{id: "session-meta", kind: :builtin},
      %{id: "session-lineage", kind: :builtin},
      %{id: "session-tags", kind: :builtin},
      %{id: "session-agent", kind: :builtin},
      %{id: "session-conversations", kind: :builtin},
      %{id: "session-inbox-switcher", kind: :builtin}
    ]

    test "places :top, :bottom, {:before, id}, {:after, id}, and chained items with tie-breaking" do
      ext_items = [
        %{id: "bottom-b", position: :bottom, order: 20},
        %{id: "top-b", position: :top, order: 20},
        %{id: "top-a", position: :top, order: 10},
        %{id: "bottom-a", position: :bottom, order: 10},
        %{id: "before-conv-2", position: {:before, "session-conversations"}, order: 20},
        %{id: "before-conv-1", position: {:before, "session-conversations"}, order: 10},
        %{id: "chained-c", position: {:after, "after-tags-b"}, order: 5},
        %{id: "after-tags-b", position: {:after, "session-tags"}, order: 20},
        %{id: "after-tags-a", position: {:after, "session-tags"}, order: 10}
      ]

      ordered = Extensions.order_sidebar_items(@builtins, ext_items)

      assert Enum.map(ordered, & &1.id) == [
               "top-a",
               "top-b",
               "session-meta",
               "session-lineage",
               "session-tags",
               "after-tags-a",
               "after-tags-b",
               "chained-c",
               "session-agent",
               "before-conv-1",
               "before-conv-2",
               "session-conversations",
               "session-inbox-switcher",
               "bottom-a",
               "bottom-b"
             ]
    end

    test "falls back to appending unknown targets and cycles sorted by {order, id}" do
      ext_items = [
        %{id: "unknown-2", position: {:after, "nonexistent"}, order: 30},
        %{id: "cycle-b", position: {:after, "cycle-a"}, order: 15},
        %{id: "cycle-a", position: {:before, "cycle-b"}, order: 10},
        %{id: "unknown-1", position: {:before, "missing"}, order: 5},
        %{id: "normal-top", position: :top, order: 50}
      ]

      ordered = Extensions.order_sidebar_items(@builtins, ext_items)

      assert Enum.map(ordered, & &1.id) == [
               "normal-top",
               "session-meta",
               "session-lineage",
               "session-tags",
               "session-agent",
               "session-conversations",
               "session-inbox-switcher",
               "unknown-1",
               "cycle-a",
               "cycle-b",
               "unknown-2"
             ]
    end
  end

  describe "nav_items/1" do
    test "sorts nav items by {order, label, id}" do
      web_extensions = [
        %{
          ext_id: "ext.b",
          nav_items: [
            %{id: "z-nav", label: "Beta", path: "/ext/beta", section: {:ext, "beta"}, order: 20},
            %{
              id: "a-nav",
              label: "Alpha",
              path: "/ext/alpha",
              section: {:ext, "alpha"},
              order: 20
            }
          ]
        },
        %{
          ext_id: "ext.a",
          nav_items: [
            %{id: "first", label: "Zed", path: "/ext/zed", section: {:ext, "zed"}, order: 5}
          ]
        }
      ]

      assert Enum.map(Extensions.nav_items(web_extensions: web_extensions), & &1.id) == [
               "first",
               "a-nav",
               "z-nav"
             ]
    end
  end

  describe "static_file/3" do
    setup do
      base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
      root = Path.join(base, "hweb-ext-static-#{System.unique_integer([:positive])}")
      static_dir = Path.join(root, "static")
      File.mkdir_p!(Path.join(static_dir, "js"))
      on_exit(fn -> File.rm_rf!(root) end)
      {:ok, root: root, static_dir: static_dir}
    end

    test "serves allowed regular assets and rejects traversal, symlinks, and unknown types",
         ctx do
      js_path = Path.join([ctx.static_dir, "js", "hooks.mjs"])
      css_path = Path.join(ctx.static_dir, "theme.css")
      outside = Path.join(ctx.root, "outside.js")

      File.write!(js_path, "export const hooks = {};\n")
      File.write!(css_path, "body {}\n")
      File.write!(outside, "console.log('secret');\n")
      File.ln_s!(outside, Path.join(ctx.static_dir, "linked.js"))
      File.write!(Path.join(ctx.static_dir, "notes.txt"), "plain\n")

      opts = [web_extensions: [%{ext_id: "demo.ext", static_dir: ctx.static_dir}]]

      assert {:ok, ^js_path, "text/javascript; charset=utf-8"} =
               Extensions.static_file("demo.ext", ["js", "hooks.mjs"], opts)

      assert {:ok, ^css_path, "text/css; charset=utf-8"} =
               Extensions.static_file("demo.ext", ["theme.css"], opts)

      assert :error = Extensions.static_file("demo.ext", ["..", "outside.js"], opts)
      assert :error = Extensions.static_file("demo.ext", ["linked.js"], opts)
      assert :error = Extensions.static_file("demo.ext", ["notes.txt"], opts)
      assert :error = Extensions.static_file("demo.ext", ["missing.js"], opts)
      assert :error = Extensions.static_file("../evil", ["theme.css"], opts)
    end
  end
end
