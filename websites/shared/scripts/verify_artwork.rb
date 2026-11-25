# frozen_string_literal: true

require "cgi"
require "yaml"

# Check built credits without making CI depend on live museum sites.
def artwork_errors(files)
  errors = []
  files.each do |route, html|
    footer = html[%r{<footer\b[^>]*>.*?</footer>}m]
    unless footer&.match?(%r{<a\s+href="/artwork/">\s*Artwork credits\s*</a>})
      errors << "#{route}: missing Artwork credits footer link"
    end
  end

  artworks = YAML.safe_load_file(File.join(__dir__, "../data/artworks.yml"))
  credits = files.fetch("/artwork/").scan(%r{<li class="artwork-credit" id="([^"]+)">(.*?)</li>}m)
  unless artworks.any? && credits.map(&:first).sort == artworks.keys.sort
    errors << "/artwork/: expected one credit for each artwork record"
  end

  credits.each do |id, html|
    art = artworks[id]
    next unless art

    fields = %w[title artist year museum rights alt]
    fields += %w[sitter house inventory].select { |field| art.key?(field) }
    fields.each do |field|
      value = art[field].to_s
      if value.strip.empty? || !html.include?(CGI.escapeHTML(value))
        errors << "/artwork/##{id}: missing #{field}"
      end
    end

    links = %w[rights_url]
    if art["work_url"] || !art["image_source_url"]
      links << "work_url"
    end
    links << "image_source_url" unless art["source_note"] && !art["image_source_url"]
    links << "rights_policy_url" if art["rights_policy_url"]
    links.each do |field|
      url = art[field].to_s
      unless url.match?(%r{\Ahttps://[^/\s]+/\S+\z}) && html.include?(%(href="#{CGI.escapeHTML(url)}"))
        errors << "/artwork/##{id}: missing HTTPS #{field}"
      end
    end

    %w[source_note rights_note].each do |field|
      if art[field] && (art[field].strip.empty? || !html.include?(CGI.escapeHTML(art[field])))
        errors << "/artwork/##{id}: missing #{field}"
      end
    end

    src, width, height = art.values_at("src", "width", "height")
    image_link = html[%r{<a\b[^>]*href="#{Regexp.escape(src.to_s)}"[^>]*>\s*(<img\b[^>]*>)\s*</a>}, 1]
    attributes = { "src" => src, "width" => width, "height" => height, "alt" => art["alt"] }
    unless src.to_s.match?(%r{\A/assets/art/[^/]+\.webp\z}) && image_link &&
           [width, height].all? { |dimension| dimension.is_a?(Integer) && dimension.positive? } &&
           attributes.all? { |name, value| image_link.include?(%( #{name}="#{CGI.escapeHTML(value.to_s)}")) }
      errors << "/artwork/##{id}: missing linked artwork image, dimensions, or alt text"
    end
  end
  errors
end
