defmodule H.ExtensionsWebTest do
  use ExUnit.Case, async: false

  alias H.Extensions.Web

  defmodule ValidPage do
    def mount(_params, _session, socket), do: {:ok, socket}
    def handle_params(_params, _uri, socket), do: {:noreply, socket}
    def handle_event(_event, _params, socket), do: {:noreply, socket}
    def handle_info(_msg, socket), do: {:noreply, socket}
    def render(_assigns), do: :ok
    def sidebar(_assigns), do: :ok
  end

  defmodule BadArityPage do
    def mount(_params, _session), do: {:ok, nil}
    def render(_assigns), do: :ok
  end

  defmodule NoRenderPage do
    def mount(_params, _session, socket), do: {:ok, socket}
  end

  setup do
    base = if File.dir?("/private/tmp"), do: "/private/tmp", else: System.tmp_dir!()
    root = Path.join(base, "h-ext-web-#{System.pid()}-#{System.unique_integer([:positive])}")
    data_dir = Path.join(root, "data")
    File.mkdir_p!(data_dir)
    on_exit(fn -> File.rm_rf!(root) end)
    {:ok, root: root, data_dir: data_dir}
  end

  describe "H.Extensions.Web.validate/2" do
    test "normalizes valid :web contribution and verifies static files", ctx do
      pkg = Path.join(ctx.root, "pkg")
      static_dir = Path.join([pkg, "priv", "static"])
      File.mkdir_p!(Path.join(static_dir, "nested"))
      File.write!(Path.join(static_dir, "theme.css"), ".x { color: red; }\n")
      File.write!(Path.join([static_dir, "nested", "hook.mjs"]), "export const hooks = {};\n")

      assert {:ok, nil} = Web.validate(nil, %{id: "demo.ext", path: pkg})

      spec = %{
        pages: [%{slug: "demo-page", module: ValidPage, title: "Demo"}],
        nav_items: [%{id: "demo-nav", label: "Demo", slug: "demo-page", order: 10}],
        session_sidebar: [
          %{
            id: "demo-panel",
            position: {:after, "session-agent"},
            module: ValidPage,
            function: :sidebar,
            order: 20
          }
        ],
        stylesheets: ["theme.css"],
        scripts: ["nested/hook.mjs"]
      }

      assert {:ok,
              %{
                ext_id: "demo.ext",
                static_dir: ^static_dir,
                pages: [
                  %{
                    ext_id: "demo.ext",
                    slug: "demo-page",
                    path: "/ext/demo-page",
                    module: ValidPage,
                    title: "Demo"
                  }
                ],
                nav_items: [
                  %{
                    ext_id: "demo.ext",
                    id: "demo-nav",
                    label: "Demo",
                    path: "/ext/demo-page",
                    section: {:ext, "demo-page"},
                    order: 10
                  }
                ],
                session_sidebar: [
                  %{
                    ext_id: "demo.ext",
                    id: "demo-panel",
                    position: {:after, "session-agent"},
                    module: ValidPage,
                    function: :sidebar,
                    order: 20
                  }
                ],
                stylesheets: [
                  %{
                    ext_id: "demo.ext",
                    file: "theme.css",
                    href: "/ext-assets/demo.ext/theme.css"
                  }
                ],
                scripts: [
                  %{
                    ext_id: "demo.ext",
                    file: "nested/hook.mjs",
                    src: "/ext-assets/demo.ext/nested/hook.mjs"
                  }
                ]
              }} = Web.validate(spec, %{id: "demo.ext", path: pkg})
    end

    test "rejects unknown keys, invalid slugs, missing callbacks, and bad callback arities",
         ctx do
      pkg = Path.join(ctx.root, "pkg")
      File.mkdir_p!(Path.join([pkg, "priv", "static"]))

      assert {:error, :invalid_web_contribution} =
               Web.validate(%{unknown: []}, %{id: "demo.ext", path: pkg})

      assert {:error, :invalid_web_contribution} =
               Web.validate(%{pages: [%{slug: "BadSlug", module: ValidPage}]}, %{
                 id: "demo.ext",
                 path: pkg
               })

      assert {:error, :invalid_web_contribution} =
               Web.validate(%{pages: [%{slug: "ok", module: NoRenderPage}]}, %{
                 id: "demo.ext",
                 path: pkg
               })

      assert {:error, :invalid_web_contribution} =
               Web.validate(%{pages: [%{slug: "ok", module: BadArityPage}]}, %{
                 id: "demo.ext",
                 path: pkg
               })

      assert {:error, :invalid_web_contribution} =
               Web.validate(
                 %{
                   session_sidebar: [
                     %{
                       id: "ok",
                       position: {:after, "../bad"},
                       module: ValidPage,
                       function: :sidebar
                     }
                   ]
                 },
                 %{id: "demo.ext", path: pkg}
               )
    end

    test "rejects path traversal, wrong asset extensions, missing files, and symlinks", ctx do
      pkg = Path.join(ctx.root, "pkg")
      static_dir = Path.join([pkg, "priv", "static"])
      File.mkdir_p!(static_dir)
      outside = Path.join(ctx.root, "secret.css")
      File.write!(outside, "body {}")
      File.write!(Path.join(static_dir, "real.css"), "body {}")
      File.write!(Path.join(static_dir, "not_css.txt"), "text")
      File.ln_s!(outside, Path.join(static_dir, "linked.css"))

      for bad_css <- [
            "../secret.css",
            "/etc/passwd",
            "./real.css",
            "missing.css",
            "not_css.txt",
            "linked.css"
          ] do
        assert {:error, :invalid_web_contribution} =
                 Web.validate(%{stylesheets: [bad_css]}, %{id: "demo.ext", path: pkg})
      end

      assert {:error, :invalid_web_contribution} =
               Web.validate(%{scripts: ["real.css"]}, %{id: "demo.ext", path: pkg})
    end
  end

  describe "H.Extensions.load_state/1 with :web contributions" do
    test "loads valid web packages into opts and ext_state and rejects duplicate slugs/ids",
         ctx do
      pkg1 = compile_web_package(ctx.root, "pkg1", "ext.one", "ExtOne")
      pkg2 = compile_web_package(ctx.root, "pkg2", "ext.two", "ExtTwo")

      assert {output, 0} =
               launch("""
               File.write!(
                 #{inspect(Path.join(ctx.data_dir, "extensions.json"))},
                 JSON.encode!(%{
                   version: 1,
                   extensions: [
                     %{path: #{inspect(pkg1)}, settings: %{"slug" => "alpha", "nav_id" => "nav-alpha", "sidebar_id" => "sb-alpha"}},
                     %{path: #{inspect(pkg2)}, settings: %{"slug" => "beta", "nav_id" => "nav-beta", "sidebar_id" => "sb-beta"}}
                   ]
                 })
               )

               {:ok, opts, ext_state} = H.Extensions.load_state(data_dir: #{inspect(ctx.data_dir)})
               2 = length(opts[:web_extensions])
               2 = length(ext_state.web_extensions)

               # Duplicate page slug across packages
               File.write!(
                 #{inspect(Path.join(ctx.data_dir, "extensions.json"))},
                 JSON.encode!(%{
                   version: 1,
                   extensions: [
                     %{path: #{inspect(pkg1)}, settings: %{"slug" => "dup", "nav_id" => "n1", "sidebar_id" => "s1"}},
                     %{path: #{inspect(pkg2)}, settings: %{"slug" => "dup", "nav_id" => "n2", "sidebar_id" => "s2"}}
                   ]
                 })
               )

               {:error, {:extensions, {"ext.two", {:duplicate, :web_page_slug, "dup"}}}} =
                 H.Extensions.load_state(data_dir: #{inspect(ctx.data_dir)})

               # Duplicate nav_id across packages
               File.write!(
                 #{inspect(Path.join(ctx.data_dir, "extensions.json"))},
                 JSON.encode!(%{
                   version: 1,
                   extensions: [
                     %{path: #{inspect(pkg1)}, settings: %{"slug" => "p1", "nav_id" => "dup-nav", "sidebar_id" => "s1"}},
                     %{path: #{inspect(pkg2)}, settings: %{"slug" => "p2", "nav_id" => "dup-nav", "sidebar_id" => "s2"}}
                   ]
                 })
               )

               {:error, {:extensions, {"ext.two", {:duplicate, :web_nav_id, "dup-nav"}}}} =
                 H.Extensions.load_state(data_dir: #{inspect(ctx.data_dir)})

               # Duplicate sidebar_id against pre-seeded opts[:web_extensions]
               File.write!(
                 #{inspect(Path.join(ctx.data_dir, "extensions.json"))},
                 JSON.encode!(%{
                   version: 1,
                   extensions: [
                     %{path: #{inspect(pkg1)}, settings: %{"slug" => "p1", "nav_id" => "n1", "sidebar_id" => "seeded"}}
                   ]
                 })
               )

               {:error, {:extensions, {"ext.one", {:duplicate, :web_sidebar_id, "seeded"}}}} =
                 H.Extensions.load_state(
                   data_dir: #{inspect(ctx.data_dir)},
                   web_extensions: [%{session_sidebar: [%{id: "seeded"}]}]
                 )

               IO.puts("WEB_EXT_OK")
               """)

      assert output =~ "WEB_EXT_OK"
    end
  end

  defp launch(script) do
    pa_args =
      :code.get_path()
      |> Enum.map(&List.to_string/1)
      |> Enum.map(&Path.expand/1)
      |> Enum.filter(&File.dir?/1)
      |> Enum.flat_map(&["-pa", &1])

    System.cmd(
      System.find_executable("elixir"),
      pa_args ++
        [
          "--erl",
          "+S 2:2",
          "-e",
          "Application.put_env(:req_llm, :load_dotenv, false)\n" <> script
        ],
      stderr_to_stdout: true,
      env: [{"H_DATA_DIR", nil}]
    )
  end

  defp compile_web_package(root, dir_name, ext_id, mod_suffix) do
    pkg_dir = Path.join(root, dir_name)
    ebin_dir = Path.join(pkg_dir, "ebin")
    static_dir = Path.join([pkg_dir, "priv", "static"])
    src_path = Path.join(root, "#{dir_name}.ex")

    File.mkdir_p!(ebin_dir)
    File.mkdir_p!(static_dir)
    File.write!(Path.join(static_dir, "style.css"), ".ext { display: block; }\n")

    File.write!(
      Path.join(pkg_dir, "extension.json"),
      JSON.encode!(%{
        "id" => ext_id,
        "api_version" => 1,
        "module" => "Elixir.FixtureWebTest.#{mod_suffix}"
      })
    )

    File.write!(
      src_path,
      """
      defmodule FixtureWebTest.#{mod_suffix}.Page do
        def render(assigns), do: assigns
        def sidebar(assigns), do: assigns
      end

      defmodule FixtureWebTest.#{mod_suffix} do
        @behaviour H.Extension

        @impl true
        def configure(settings, _context) do
          slug = Map.fetch!(settings, "slug")
          nav_id = Map.fetch!(settings, "nav_id")
          sidebar_id = Map.fetch!(settings, "sidebar_id")

          {:ok,
           %{
             web: %{
               pages: [%{slug: slug, module: FixtureWebTest.#{mod_suffix}.Page}],
               nav_items: [%{id: nav_id, label: slug, slug: slug}],
               session_sidebar: [
                 %{
                   id: sidebar_id,
                   position: :bottom,
                   module: FixtureWebTest.#{mod_suffix}.Page,
                   function: :sidebar
                 }
               ],
               stylesheets: ["style.css"]
             }
           }}
        end
      end
      """
    )

    {_, 0} =
      launch("""
      {:ok, _, %{compile_warnings: [], runtime_warnings: []}} =
        Kernel.ParallelCompiler.compile_to_path([#{inspect(src_path)}], #{inspect(ebin_dir)},
          return_diagnostics: true
        )
      """)

    pkg_dir
  end
end
