.PHONY: install build serve verify clean

DESTINATION ?= _site

install:
	npm ci --ignore-scripts
	bundle install

build:
	npm run css:build
	JEKYLL_ENV=production bundle exec jekyll build --destination $(DESTINATION)

serve:
	npm start

verify: build
	ruby scripts/serve_test.rb
	ruby scripts/verify_site.rb $(DESTINATION)

clean:
	rm -rf _site public .jekyll-cache .sass-cache
