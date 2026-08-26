---
paths:
  - "Pine/LSP/**"
  - "PineTests/SourceKitLSP*"
---

# SourceKit-LSP integration

- **SourceKit-LSP smoke (opt-in):** `DEVELOPER_DIR=/Applications/Xcode.app/Contents/Developer xcodebuild test -skipPackagePluginValidation -project Pine.xcodeproj -scheme Pine -destination 'platform=macOS' -only-testing:PineTests/SourceKitLSPIntegrationTests PINE_RUN_SOURCEKIT_LSP_SMOKE=1` — creates an isolated temporary Swift package and HOME/cache directories, locates `sourcekit-lsp` through the active Xcode toolchain, bounds every wait, captures server stderr on failure, and always terminates the child. The test is explicitly skipped unless opted in and the server is available
