# frozen_string_literal: true

require "pathname"
require "cgi"
require "uri"
require "rexml/document"

root = Pathname(ARGV.fetch(0, "_site"))
files = root.glob("**/*.html").to_h do |file|
  ["/#{file.relative_path_from(root)}".sub(/index\.html$/, ""), file.read(encoding: "utf-8")]
end
required = %w[/ /demo/ /demo/hi/ /demo/hiweb/ /features/ /docs/ /docs/setup/ /docs/architecture/ /extensions/]
missing = required - files.keys
abort "Missing pages: #{missing.join(', ')}" unless missing.empty?

llms = root.join("llms.txt").read(encoding: "utf-8")
full = root.join("llms-full.txt").read(encoding: "utf-8")
sitemap = REXML::Document.new(root.join("sitemap.xml").read(encoding: "utf-8"))
locations = sitemap.root.get_elements("url/loc").map { |loc| loc.text }
errors = []
files.each do |route, html|
  errors << "#{route}: expected one h1" unless html.scan(/<h1\b/).size == 1
  errors << "#{route}: missing page description" unless html.include?('name="description"') || route == "/404.html"
  if route == "/features/" || route.start_with?("/docs/", "/extensions/")
    errors << "#{route}: missing section contents" unless html.include?('id="markdown-toc"')
  end
  if route.start_with?("/docs/", "/extensions/")
    errors << "#{route}: missing current chapter" unless html.include?(%(href="#{route}" aria-current="page"))
  end
  html.scan(/(?:href|src)="([^"\s]+)"/).flatten.each do |raw|
    ref = CGI.unescapeHTML(raw)
    next if ref.match?(%r{\A(?:[a-z]+:|//)})

    url = URI.join("https://verify.invalid#{route}", ref)
    page = files[url.path]
    if !page && !root.join(url.path.delete_prefix("/")).file?
      errors << "#{route} -> missing #{ref}"
    elsif page && url.fragment && !page.include?(%(id="#{URI::DEFAULT_PARSER.unescape(url.fragment)}"))
      errors << "#{route} -> missing anchor #{ref}"
    end
  end
  next if route == "/404.html"

  loc = locations.find { |link| URI(link).path == route }
  errors << "#{route}: not in sitemap" unless loc
  errors << "#{route}: not in LLM index" unless loc && llms.include?("(#{loc})") && full.include?("(#{loc})")
end
errors << "Internal planning was published" if root.glob("**/{brief.md,discovery.md,writing-guide.md,Gemfile,package-lock.json}").any?
errors << "Template text in machine context" if [llms, full].any? { |s| s.match?(/example\.com\/about|Site title|{%/) }

slop_terms = %w[
  additionally crucial delve enduring enhance fostering garner interplay intricate landscape
  leverage pivotal showcase tapestry testament underscore vibrant substrate wedge vector
  locus nexus primitive scaffolding paradigm endgame flywheel seamless seamlessly
]
files.each do |route, html|
  text = html.gsub(/<script\b[^>]*>.*?<\/script>/m, "").gsub(/<style\b[^>]*>.*?<\/style>/m, "").gsub(/<[^>]+>/, " ")
  errors << "#{route}: contains forbidden punctuation (em dash or curly quotes)" if text.match?(/[—“”‘’]/)
  found_slop = slop_terms.select { |term| text.match?(/\b#{Regexp.escape(term)}\b/i) }
  errors << "#{route}: retains AI slop vocabulary (#{found_slop.join(', ')})" unless found_slop.empty?
end

abort errors.uniq.join("\n") unless errors.empty?
puts "Verified #{files.size} pages, internal links and fragments, sitemap and both LLM indexes."
