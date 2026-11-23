.PHONY: install build build-prod serve verify verify-prod clean

DESTINATION ?= _site
CONFIG ?= _config.yml

install:
	npm ci --ignore-scripts
	bundle install

build:
	npm run css:build
	JEKYLL_ENV=production bundle exec jekyll build --config $(CONFIG) --destination $(DESTINATION)

build-prod:
	$(MAKE) build CONFIG=_config.yml,_config.prod.yml DESTINATION=$(DESTINATION)

serve:
	npm start

verify: build
	ruby scripts/serve_test.rb
	ruby scripts/verify_site.rb $(DESTINATION)

verify-prod: build-prod
	ruby scripts/serve_test.rb
	ruby scripts/verify_site.rb $(DESTINATION)

clean:
	rm -rf _site public .jekyll-cache .sass-cache
