---
paths:
  - "README.md"
  - "docs/**"
  - "assets/**"
---

# Marketing surface synchronization

Pine's public product description spans several surfaces that must stay consistent. Treat a change to positioning, a flagship user-facing capability, supported-language count, third-party dependencies, installation instructions, or minimum macOS/Xcode requirements as a documentation change too.

- **Canonical surfaces:** update `README.md`, `docs/index.html`, its SEO/Open Graph/X metadata, and all 9 landing-page translations (`en`, `de`, `es`, `fr`, `ja`, `ko`, `pt-BR`, `ru`, `zh-Hans`) in the same PR when a claim changes. Do not update English alone.
- **GitHub About:** keep the repository description, homepage, and topics aligned with the landing-page positioning. Verify with `gh repo view --json description,homepageUrl,repositoryTopics`; update through `gh repo edit` only when the task authorizes external repository metadata changes.
- **Screenshots:** marketing screenshots live in `assets/` and are produced by `PineUITests/ScreenshotTests.swift` through `scripts/update-screenshots.sh`. Fixtures must use a stable, human-readable project name such as `Pine Demo`; never ship UUIDs, temporary paths, stale feature counts, or test-only wording in visible screenshot content.
- **Avoid fragile claims:** prefer durable wording over hard-coded counts or dependency totals. When an exact number is useful (for example, supported syntax grammars), derive or verify it from the repository before publishing.
- **Release check:** before opening a PR that changes any canonical surface, verify the latest-release CTA, Homebrew command, system requirements, external links, responsive layout, keyboard access, reduced-motion behavior, and screenshot lightbox. Keep GitHub Pages deployment on the existing `docs/` workflow; do not create a separate hosting target.
