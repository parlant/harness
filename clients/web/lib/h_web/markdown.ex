defmodule HWeb.Markdown do
  @moduledoc "Renders untrusted assistant Markdown as a restricted set of HTML elements."

  alias HWeb.WorkspaceMedia

  import Phoenix.HTML, only: [attributes_escape: 1, html_escape: 1, raw: 1]

  @elements ~w(p h1 h2 h3 h4 h5 h6 strong em del blockquote ul ol li pre code table thead tbody tr th td)
  @console_languages ~w(console shell-session sh-session bash-session terminal bash sh shell zsh fish powershell)

  def render(text, session_id \\ nil) when is_binary(text) do
    # The parser returns a usable AST even for an unfinished streaming fence.
    {_, ast, _} = EarmarkParser.as_ast(text, gfm_tables: true)
    raw(render_nodes(ast, session_id))
  end

  defp render_nodes(nodes, session_id), do: Enum.map(nodes, &render_node(&1, session_id))

  defp render_node(text, _session_id) when is_binary(text), do: escaped(text)
  defp render_node({_, _, _, %{verbatim: true}}, _session_id), do: []

  defp render_node({"pre", _, [{"code", attrs, children, _}], _}, _session_id) do
    language = List.keyfind(attrs, "class", 0, {"class", ""}) |> elem(1)
    code = render_nodes(children, nil)

    if language in @console_languages do
      ["<pre class=\"console-block\"><code>", code, "</code></pre>"]
    else
      ["<pre><code>", code, "</code></pre>"]
    end
  end

  defp render_node({"a", attrs, children, _}, session_id) do
    case List.keyfind(attrs, "href", 0) do
      {"href", href} ->
        case URI.new(href) do
          {:ok, %URI{scheme: scheme, host: host}}
          when scheme in ["https", "http"] and is_binary(host) and host != "" ->
            {:safe, attributes} =
              attributes_escape(href: href, target: "_blank", rel: "noopener noreferrer")

            ["<a", attributes, ">", render_nodes(children, session_id), "</a>"]

          _ ->
            render_nodes(children, session_id)
        end

      _ ->
        render_nodes(children, session_id)
    end
  end

  # Never fetch URLs from assistant Markdown. A workspace reference is translated
  # into a same-session, raster/video-only preview through the owner endpoint.
  defp render_node({"img", attrs, _, _}, session_id) do
    {_, alt} = List.keyfind(attrs, "alt", 0, {"alt", ""})

    with true <- is_binary(session_id),
         {"src", "workspace:" <> path} <- List.keyfind(attrs, "src", 0),
         {:ok, media} <- WorkspaceMedia.from_reference(session_id, path) do
      render_media(media, alt)
    else
      _ -> escaped(alt)
    end
  end

  defp render_node({tag, _, _, _}, _session_id) when tag in ~w(br hr), do: ["<", tag, ">"]

  defp render_node({tag, _, children, _}, session_id) when tag in @elements do
    ["<", tag, ">", render_nodes(children, session_id), "</", tag, ">"]
  end

  defp render_node({_, _, children, _}, session_id), do: render_nodes(children, session_id)

  defp render_media({:image, url}, alt) do
    {:safe, attrs} = attributes_escape(src: url, alt: alt, loading: "lazy", decoding: "async")
    ["<img", attrs, ">"]
  end

  defp render_media({:video, url}, alt) do
    {:safe, attrs} =
      attributes_escape(
        src: url,
        aria_label: alt,
        controls: true,
        playsinline: true,
        preload: "none"
      )

    ["<video", attrs, ">", escaped(alt), "</video>"]
  end

  defp escaped(text) do
    {:safe, iodata} = html_escape(text)
    iodata
  end
end
