## Summary

<!-- What does this PR do? 1-3 bullet points -->

## Related issue

<!-- Closes #1234 -->

## Test plan

- [ ] Unit tests added/updated
- [ ] UI tests added/updated (if applicable)

## Compatibility matrix

<!-- Use Tested, Not tested, or N/A. For tested rows, include the exact version and build. -->
<!-- For compatibility-sensitive changes, paste the complete output of:
     sw_vers
     xcodebuild -version
     xcrun --sdk macosx --show-sdk-version
     xcrun --sdk macosx --show-sdk-build-version
-->

- macOS 26: <!-- Tested / Not tested / N/A — version + build -->
- macOS 27 beta: <!-- Tested / Not tested / N/A — version + build + Developer/Public beta/RC channel -->
- Xcode: <!-- version + build, or Not tested / N/A -->
- macOS SDK: <!-- version + build, or Not tested / N/A -->

### Terminal renderer coverage

<!-- Complete for terminal-related changes. Use Tested, Not tested, or N/A. -->

- Default path (Metal when available): <!-- Tested / Not tested / N/A — effective renderer, fallback log, result -->
- CoreGraphics (`--disable-metal`): <!-- Tested / Not tested / N/A — result -->

## Manual testing checklist

- [ ] Verified the change works as expected
- [ ] No regressions in related features
