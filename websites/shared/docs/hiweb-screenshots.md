# Homepage hiweb screenshots

These authorized captures show the real hiweb workbench. Both homepages share the
figure records in `data/hiweb.yml`, the `includes/hiweb.html` section, and the
privacy-reviewed WebPs in `assets/screenshots/`. Each image links directly to the
same safe WebP at its original pixel dimensions. The original PNGs are not shipped.

## Source and processing

| Published file | Authorized source filename | Processing |
| --- | --- | --- |
| `hiweb-inbox.webp` | `2026-11-26_desktop-inbox-detail_screenshot.png` | Opaque rectangle over the workspace path, labeled `[workspace path redacted]`; WebP quality 86. |
| `hiweb-mobile.webp` | `2026-11-26_mobile-session-input_screenshot.png` | WebP quality 84. |
| `hiweb-composer.webp` | `2026-11-26_desktop-input-detail_screenshot.png` | WebP quality 86. |

ImageMagick stripped metadata from all three outputs. The inbox redaction was
flattened before encoding. No source-directory paths belong in published records.
Review the actual full-size outputs whenever replacing an image, including all
text and controls. Do not substitute the sidebar capture, which exposes local
workspace details.

## Checks

Both sites' `make verify` runs `shared/scripts/verify_hiweb.rb`. The dependency-free
check reads WebP dimensions, enforces a 200 KB per-image budget, and checks section
placement, full-size links, alt text, and HTML dimensions. Visual privacy review
remains required; the dimension checker cannot detect sensitive image content.

Browser checks should cover both site palettes, wide and narrow widths, image
loading, full-size navigation, keyboard focus, native disclosures, and reduced
motion. The section itself adds no script or animation.
