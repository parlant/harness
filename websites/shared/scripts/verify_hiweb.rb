# frozen_string_literal: true

require "cgi"
require "yaml"

# Read the dimensions from the lossy WebP frame header, without image dependencies.
def hiweb_errors(files, root)
  errors = []
  proof = YAML.safe_load_file(File.join(__dir__, "../data/hiweb.yml"))
  home = files.fetch("/")
  section = home[%r{<section id="hiweb".*?</section>}m].to_s
  errors << "/: missing hiweb screenshot section" if section.empty?
  hero_end = home.index('</section>')
  proof_start = home.index('<section id="hiweb"')
  install_start = home.index('<section id="install"') || home.index('<section id="download"')
  unless hero_end && proof_start && install_start && hero_end < proof_start && proof_start < install_start
    errors << "/: expected screenshot section between hero and installation"
  end

  proof.fetch("figures").each do |figure|
    url = "/assets/screenshots/#{figure.fetch('file')}"
    path = root.join(url.delete_prefix("/"))
    unless path.file?
      errors << "Missing screenshot: #{url}"
      next
    end
    bytes = path.binread
    dimensions = nil
    if bytes[0, 4] == "RIFF" && bytes[8, 4] == "WEBP"
      offset = 12
      while offset + 8 <= bytes.bytesize
        size = bytes[offset + 4, 4].unpack1("V")
        if bytes[offset, 4] == "VP8 " && bytes[offset + 11, 3] == "\x9d\x01\x2a".b
          dimensions = bytes[offset + 14, 4].unpack("vv").map { |n| n & 0x3fff }
          break
        end
        offset += 8 + size + (size % 2)
      end
    end
    expected = figure.values_at("width", "height")
    errors << "#{url}: expected WebP dimensions #{expected.inspect}, got #{dimensions.inspect}" unless dimensions == expected
    errors << "#{url}: exceeds 200 KB image budget" if bytes.bytesize > 200_000
    unless section.include?(%(href="#{url}")) && section.include?(%(src="#{url}")) &&
           section.include?(%(alt="#{CGI.escapeHTML(figure.fetch('alt'))}")) &&
           section.include?(%(width="#{expected[0]}" height="#{expected[1]}"))
      errors << "#{url}: missing full-size link or accessible, dimensioned image"
    end
  end
  errors
end
