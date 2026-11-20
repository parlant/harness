defmodule HWeb.Markdown do
  @moduledoc "Renders untrusted assistant Markdown as a restricted set of HTML elements."

  import Phoenix.HTML, only: [attributes_escape: 1, html_escape: 1, raw: 1]

  @elements ~w(p h1 h2 h3 h4 h5 h6 strong em del blockquote ul ol li pre code table thead tbody tr th td)
  @console_languages ~w(console shell-session sh-session bash-session terminal bash sh shell zsh fish powershell)

  def render(text) when is_binary(text) do
    # The parser returns a usable AST even for an unfinished streaming fence.
    {_, ast, _} = EarmarkParser.as_ast(text, gfm_tables: true)
    raw(render_nodes(ast))
  end

  defp render_nodes(nodes), do: Enum.map(nodes, &render_node/1)

  defp render_node(text) when is_binary(text), do: escaped(text)
  defp render_node({_, _, _, %{verbatim: true}}), do: []

  defp render_node({"pre", _, [{"code", attrs, children, _}], _}) do
    language = List.keyfind(attrs, "class", 0, {"class", ""}) |> elem(1)

    if language in @console_languages do
      ["<pre class=\"console-block\"><code>", render_nodes(children), "</code></pre>"]
    else
      ["<pre><code>", render_nodes(children), "</code></pre>"]
    end
  end

  defp render_node({"a", attrs, children, _}) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        case URI.new(href) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["https", "http"] and is_binary(host) and host != "" ->
            {:safe, attributes} =
              attributes_escape(href: href, target: "_blank", rel: "noopener noreferrer")

            ["<a", attributes, ">", render_nodes(children), "</a>"]

          _ ->
            render_nodes(children)
        end

      _ ->
        render_nodes(children)
    end
  end

  # Markdown images get alt text only: don't fetch agent-generated URLs.
  defp render_node({"img", attrs, _, _}) do
    case List.keyfind(attrs, "alt", 0) do
      {"alt", alt} -> escaped(alt)
      _ -> []
    end
  end

  defp render_node({tag, _, _, _}) when tag in ~w(br hr), do: ["<", tag, ">"]

  defp render_node({tag, _, children, _}) when tag in @elements do
    ["<", tag, ">", render_nodes(children), "</", tag, ">"]
  end

  defp render_node({_, _, children, _}), do: render_nodes(children)

  defp escaped(text) do
    {:safe, iodata} = html_escape(text)
    iodata
  end
end
