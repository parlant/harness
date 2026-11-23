# Portfolio handoff

[h.md](h.md) is the ready-to-copy entry, including the listing data in its YAML front matter. It is editorial material here, not a page of the H site. Publication is Lukas's decision.

## Where it goes

The portfolio's `_config.yml` gives documents in `_projects/` the `project` layout, English language and `/projects/:name/` route. `projects/index.md` publishes at **`/work/`**, not `/projects/`. Its layout lists published collection documents under the title from `_data/work.yml` (`Projects of interest`). `_includes/project-list.html` reads `title`, `description`, `year`, `status` and `order`. The detail layout can show `repository`, but only if provided. There is deliberately no proposed domain or repository link: an unauthenticated [GitLab project lookup](https://gitlab.com/api/v4/projects/parlant-co%2Fharness) returned “404 Project Not Found” on 21 November 2026. That does not establish public access or a license.

Use the collection, **not** an additional `open_source.items` record. Those rows name an external public repository and require a sponsor key resolved through `work.yml`. Neither a sponsorship nor an open-source release is assumed here. No company, venture, navigation or homepage data edits are needed.

## Apply after approval

1. In a review branch or disposable copy of `~/Work/Parlant/www.lukasrieder.com`, check for conflicting changes and confirm `_projects/h.md` does not exist. From the **H checkout root** copy just the entry (not this README):

   ```sh
   portfolio="$HOME/Work/Parlant/www.lukasrieder.com"
   test ! -e "$portfolio/_projects/h.md" && cp website/docs/portfolio/h.md "$portfolio/_projects/h.md"
   ```

2. This is the first published collection project in the inspected portfolio. It activates a previously hidden section. In the portfolio's `scripts/verify_site.rb`, replace this assertion:

   ```ruby
   abort "Work page lacks one introduction per section" unless work.scan("data-work-introduction").length == 3
   ```

   with:

   ```ruby
   abort "Work page lacks one introduction per section" unless work.scan("data-work-introduction").length == 4
   abort "Work page lacks the H project" unless work.include?('href="/projects/h/"')
   abort "H project page is missing" unless site.join("projects/h/index.html").file?
   ```

   The four introductions are Companies, Ventures, Open-source projects and Projects of interest. Do not increase the expected *repository* count. If another project has already activated the section, keep its count and add only the H assertions.

3. Run `LC_ALL=en_US.UTF-8 make verify` at the portfolio root with its dependencies installed. Inspect `_site/work/index.html` for the **H** link and listing description, `_site/projects/h/index.html` for the full note and **Back to work** link, and the compact Work list in `_site/index.html` (home shows at most two collection entries). Confirm the route is in `sitemap.xml`. Review the byline voice, status and year with Lukas before merging. Add `repository:` or a product-site link only after verifying a public destination. No deploy or domain registration is part of this handoff.

**Integration check (21 November 2026):** Applied the entry and the verifier change to a disposable copy of the portfolio working tree. `make verify` with a UTF-8 locale passed (192 HTML files); the Work page, home page and sitemap all referenced `/projects/h/`. No changes were made to the portfolio checkout.
