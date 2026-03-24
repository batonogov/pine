# Homebrew Cask Improvements for pine-editor

Issue: https://github.com/batonogov/pine/issues/425

## Current State

Current cask (`batonogov/homebrew-tap`, `Casks/pine-editor.rb`):

```ruby
cask "pine-editor" do
  version "1.10.1"
  sha256 "5c643a2ff531068fb23aad35550c1fd27b40ef2c7165c7617ceea2fe0bb20b3e"

  url "https://github.com/batonogov/pine/releases/download/v#{version}/Pine-#{version}.dmg"
  name "Pine"
  desc "A native Mac code editor"
  homepage "https://github.com/batonogov/pine"

  depends_on macos: ">= :tahoe"

  app "Pine.app"

  zap trash: [
    "~/Library/Preferences/io.github.batonogov.pine.plist",
    "~/Library/Saved Application State/io.github.batonogov.pine.savedState",
  ]
end
```

## Comparison with Popular Editors

### VS Code (`visual-studio-code.rb`)
- Multiple `name` stanzas: `"Microsoft Visual Studio Code"`, `"VS Code"`
- `auto_updates true`
- `livecheck` block for version tracking
- `uninstall` stanza (launchctl, quit)
- Extensive `zap` covering caches, HTTP storages, preferences, shared file lists

### Zed (`zed.rb`)
- `livecheck` with JSON strategy
- `auto_updates true`
- `binary` symlink for CLI access
- Thorough `zap`: config dirs, caches, logs, HTTP storages, recent documents, saved state

## Recommended Changes

### 1. Improve `desc`

Current: `"A native Mac code editor"` — generic, not discoverable.

Proposed:
```ruby
desc "Minimal native macOS code editor with Liquid Glass UI"
```

Homebrew convention: description should be concise (max ~80 chars), no leading article ("A"), highlight unique value proposition.

### 2. Add `livecheck` block

Enables `brew livecheck pine-editor` to detect new versions automatically:

```ruby
livecheck do
  url :url
  strategy :github_latest
end
```

This uses the GitHub Releases API via the existing `url` pattern — simplest approach for GitHub-hosted releases.

### 3. Add `auto_updates true`

Pine uses Sparkle for auto-updates. Homebrew should know this so `brew outdated` skips it by default:

```ruby
auto_updates true
```

### 4. Expand `zap` stanza

Current `zap` is minimal. Pine also creates caches, Sparkle update data, and recovery files:

```ruby
zap trash: [
  "~/Library/Caches/io.github.batonogov.pine",
  "~/Library/HTTPStorages/io.github.batonogov.pine",
  "~/Library/Preferences/io.github.batonogov.pine.plist",
  "~/Library/Saved Application State/io.github.batonogov.pine.savedState",
  "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/io.github.batonogov.pine.sfl*",
]
```

Note: verify actual bundle identifier paths by installing Pine and checking `~/Library/` subdirectories.

### 5. Add `uninstall` stanza

For clean quit before removal:

```ruby
uninstall quit: "io.github.batonogov.pine"
```

### 6. Homepage

Current `homepage` points to the GitHub repo, which is fine for now. If a dedicated site (e.g. `pine-editor.dev`) is created later, update to that.

## Proposed Final Cask

```ruby
cask "pine-editor" do
  version "1.10.1"
  sha256 "5c643a2ff531068fb23aad35550c1fd27b40ef2c7165c7617ceea2fe0bb20b3e"

  url "https://github.com/batonogov/pine/releases/download/v#{version}/Pine-#{version}.dmg"
  name "Pine"
  desc "Minimal native macOS code editor with Liquid Glass UI"
  homepage "https://github.com/batonogov/pine"

  livecheck do
    url :url
    strategy :github_latest
  end

  auto_updates true
  depends_on macos: ">= :tahoe"

  app "Pine.app"

  uninstall quit: "io.github.batonogov.pine"

  zap trash: [
    "~/Library/Application Support/com.apple.sharedfilelist/com.apple.LSSharedFileList.ApplicationRecentDocuments/io.github.batonogov.pine.sfl*",
    "~/Library/Caches/io.github.batonogov.pine",
    "~/Library/HTTPStorages/io.github.batonogov.pine",
    "~/Library/Preferences/io.github.batonogov.pine.plist",
    "~/Library/Saved Application State/io.github.batonogov.pine.savedState",
  ]
end
```

## Action Items

1. Verify `~/Library/` paths by installing Pine and running `find ~/Library -iname "*pine*" -o -iname "*batonogov*"`
2. Apply changes to `batonogov/homebrew-tap` repo
3. Test with `brew audit --cask pine-editor` and `brew livecheck pine-editor`
4. Consider adding `binary` stanza if Pine ever ships a CLI tool
