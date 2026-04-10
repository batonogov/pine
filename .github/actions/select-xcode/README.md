# Select Xcode

Composite action that activates an installed Xcode via `sudo xcode-select`
on macOS GitHub Actions runners. This is the first composite action in this
repository; follow this layout (`action.yml` + `README.md` + optional
`inputs`) when adding others.

## Usage

Newest stable Xcode (default):

```yaml
- name: Select Xcode
  uses: ./.github/actions/select-xcode
```

Pin a specific version:

```yaml
- name: Select Xcode
  uses: ./.github/actions/select-xcode
  with:
    xcode-version: Xcode_26.0
```

## Behavior

- Scans `/Applications/Xcode*.app` on the runner.
- Filters out beta builds (`*beta*`, `*Beta*`) because `sort -V` is not
  reliable at ordering them against stable releases.
- Picks the highest `sort -V` entry and runs `sudo xcode-select -s`
  against its `Contents/Developer` directory.
- Prints the selected `xcodebuild -version` for diagnostics.
- Fails loudly (`::error::` + `exit 1`) if no candidate exists or the
  requested exact version is missing.

## Requirements

- **macOS runner.** This action uses `sudo` and `xcode-select`; other
  platforms will fail at the `sudo` step. Keep the calling job on
  `macos-*` runners.
- **`shell: bash` is set explicitly** inside the composite step — no
  extra shell config is needed at the call site.

## Inputs

| Input           | Description                                                                                      | Required | Default                       |
| --------------- | ------------------------------------------------------------------------------------------------ | -------- | ----------------------------- |
| `xcode-version` | Exact Xcode app name without `.app`, e.g. `Xcode_26.0`. When empty, the newest stable is picked. | no       | `""` (auto-select newest)     |

## Why

Before this action, the Select Xcode block was copied into four jobs
across `ci.yml` and `release.yml`. Any drift between copies would change
which Xcode was active without an obvious diff. Extracting to one place
fixes that and gives a single spot to add version pinning when the
runner image gains multiple Xcodes. See #759 for context.
