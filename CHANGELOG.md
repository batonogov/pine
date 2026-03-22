# Changelog

## [1.9.1](https://github.com/batonogov/pine/compare/v1.9.0...v1.9.1) (2026-03-22)


### Bug Fixes

* allow gitignored folders to be expanded in sidebar ([#393](https://github.com/batonogov/pine/issues/393)) ([f2c0d94](https://github.com/batonogov/pine/commit/f2c0d94ec0fe1d7a4a9a63f5f8dd085574f5b5aa))

## [1.9.0](https://github.com/batonogov/pine/compare/v1.8.0...v1.9.0) (2026-03-22)


### Features

* add creator story section to landing page with i18n ([#371](https://github.com/batonogov/pine/issues/371)) ([b0fd2bc](https://github.com/batonogov/pine/commit/b0fd2bcc7bbf68829b4bf4488cae8e62c0f37c9e)), closes [#344](https://github.com/batonogov/pine/issues/344)
* find in terminal (Cmd+F) ([#372](https://github.com/batonogov/pine/issues/372)) ([62a8a69](https://github.com/batonogov/pine/commit/62a8a69a937921683d42f867cca02ca02cfce501))
* **i18n:** add missing translations for 14 strings across 7 languages ([#367](https://github.com/batonogov/pine/issues/367)) ([4b99ba6](https://github.com/batonogov/pine/commit/4b99ba66f7b681736b246b5d830c0a85461d419d)), closes [#327](https://github.com/batonogov/pine/issues/327)


### Bug Fixes

* editor find bar overlaps line numbers ([#387](https://github.com/batonogov/pine/issues/387)) ([cf6d395](https://github.com/batonogov/pine/commit/cf6d395d4cf5ff39f6c519a1d92b87ba8f41036e))
* **tests:** add isSelected accessibility trait to active editor tab ([#378](https://github.com/batonogov/pine/issues/378)) ([f9134e6](https://github.com/batonogov/pine/commit/f9134e6753f05168ef57ad4fc40b3674b8bbe1fd))


### Code Refactoring

* **tests:** replace sleep() with expectation-based waiting in UI tests ([#370](https://github.com/batonogov/pine/issues/370)) ([d2476ba](https://github.com/batonogov/pine/commit/d2476baca14caa3103317efe72d2eb282d21f578))

## [1.8.0](https://github.com/batonogov/pine/compare/v1.7.0...v1.8.0) (2026-03-21)


### Features

* crash recovery for unsaved editor content ([#363](https://github.com/batonogov/pine/issues/363)) ([b6837a1](https://github.com/batonogov/pine/commit/b6837a19d4b2d638f0b056cd5510bb66f82922ae))
* **i18n:** add Japanese localization ([#360](https://github.com/batonogov/pine/issues/360)) ([6a31926](https://github.com/batonogov/pine/commit/6a319269013464400886c66b180df5bc92ff78e8))


### Bug Fixes

* **ci:** grant write permissions to Claude CI workflows ([#356](https://github.com/batonogov/pine/issues/356)) ([760f020](https://github.com/batonogov/pine/commit/760f020b55a2eae1ab6b89ce7776495295980fb2))
* correct upside-down branch icon in git blame annotations ([#359](https://github.com/batonogov/pine/issues/359)) ([c04c40f](https://github.com/batonogov/pine/commit/c04c40f05bbc40c0ac7b8129b5c1212bdbc6db03))
* **i18n:** fix translation bugs in zh-Hans, de, and ru ([#352](https://github.com/batonogov/pine/issues/352)) ([b2b9652](https://github.com/batonogov/pine/commit/b2b96522cac396a21587543cd54e038fd47dffb8))
* **i18n:** remove orphaned xcstrings keys that break Xcode 26 build ([#355](https://github.com/batonogov/pine/issues/355)) ([8b69059](https://github.com/batonogov/pine/commit/8b6905967979a18c849f0fdf2b7efcea71727438))
* prevent line number gutter from overlapping native find bar ([#354](https://github.com/batonogov/pine/issues/354)) ([878bd62](https://github.com/batonogov/pine/commit/878bd627c5cd9256dfc5ce2d890983fab3199acb))
* prevent Xcode from modifying Localizable.xcstrings on build ([#350](https://github.com/batonogov/pine/issues/350)) ([c6a7b38](https://github.com/batonogov/pine/commit/c6a7b382cddc944b00f02d6070bbca7140215fa1))


### Documentation

* add MIT license ([#366](https://github.com/batonogov/pine/issues/366)) ([3362374](https://github.com/batonogov/pine/commit/3362374dfc4b3768a9c4b0e026816ec9323a987c))
* update CLAUDE.md to reflect current architecture and features ([#353](https://github.com/batonogov/pine/issues/353)) ([42df37a](https://github.com/batonogov/pine/commit/42df37a0ae077ed5e9c4e7b66df11482d95c0a53))

## [1.7.0](https://github.com/batonogov/pine/compare/v1.6.1...v1.7.0) (2026-03-21)


### Features

* add auto-save files after delay ([#329](https://github.com/batonogov/pine/issues/329)) ([1bde1d9](https://github.com/batonogov/pine/commit/1bde1d9a7681793362959e7130c702e398cd54da))
* add code folding for collapsible regions ([#276](https://github.com/batonogov/pine/issues/276)) ([#287](https://github.com/batonogov/pine/issues/287)) ([9583dcd](https://github.com/batonogov/pine/commit/9583dcd0568b6d4f1bb7a83d1b5cd9af574365ff))
* add dedicated Terraform syntax highlighting grammar ([#286](https://github.com/batonogov/pine/issues/286)) ([a88925b](https://github.com/batonogov/pine/commit/a88925b5018fe51b69e836e39735b10b079988ca))
* add find & replace in editor via native macOS find bar ([#341](https://github.com/batonogov/pine/issues/341)) ([c49b729](https://github.com/batonogov/pine/commit/c49b729d088808bd040723212a5916a3bdff94ef))
* add git blame view with toggle via View menu ([#288](https://github.com/batonogov/pine/issues/288)) ([db303a0](https://github.com/batonogov/pine/commit/db303a060fc6491dd25004d2c8248a59ec7bcdaa))
* show line/column, indentation, line ending and file size in status bar ([#339](https://github.com/batonogov/pine/issues/339)) ([43330eb](https://github.com/batonogov/pine/commit/43330eb255797c9e50f68236ffb9d664f93bd3a1))


### Bug Fixes

* replace List with ScrollView+LazyVStack in welcome recent projects ([#285](https://github.com/batonogov/pine/issues/285)) ([faca3c1](https://github.com/batonogov/pine/commit/faca3c15c69122b992993802371534702448d642))
* resolve corrupted rendering and multi-region fold issues ([#291](https://github.com/batonogov/pine/issues/291)) ([#321](https://github.com/batonogov/pine/issues/321)) ([0c1ddee](https://github.com/batonogov/pine/commit/0c1ddee14ea8409843c0322d02bca23664958136))
* resolve performance regression in code folding ([#320](https://github.com/batonogov/pine/issues/320)) ([1a722d2](https://github.com/batonogov/pine/commit/1a722d26e99ca77d7064537feb24abbd8ad217b7))


### Performance Improvements

* cache line number offsets for O(log n) lookups ([#326](https://github.com/batonogov/pine/issues/326)) ([24c578a](https://github.com/batonogov/pine/commit/24c578a6df2457be133ff0dd53bc471c163e0598))
* make file tree loading async and incremental ([#325](https://github.com/batonogov/pine/issues/325)) ([4a3d0ca](https://github.com/batonogov/pine/commit/4a3d0ca452319e60425cbb3491703858f4551eca))
* make git operations async to unblock main thread ([#319](https://github.com/batonogov/pine/issues/319)) ([846fd01](https://github.com/batonogov/pine/commit/846fd0133d06fb48d40ee58bef7dfbbec84748d9))
* make syntax highlighting async and incremental ([#322](https://github.com/batonogov/pine/issues/322)) ([95e38c4](https://github.com/batonogov/pine/commit/95e38c47c7c6861b4efa3b9118228f6f32538e9e))

## [1.6.1](https://github.com/batonogov/pine/compare/v1.6.0...v1.6.1) (2026-03-20)


### Bug Fixes

* show gitignored directories in sidebar with dimmed appearance ([#282](https://github.com/batonogov/pine/issues/282)) ([b5fa8ab](https://github.com/batonogov/pine/commit/b5fa8ab3d50e67d82b8ec8b74366143bb1144553))

## [1.6.0](https://github.com/batonogov/pine/compare/v1.5.1...v1.6.0) (2026-03-20)


### Features

* configurable terminal shell ([#267](https://github.com/batonogov/pine/issues/267)) ([276166c](https://github.com/batonogov/pine/commit/276166c7ab58d025a50764c5d7f34df709ef5a86))
* navigate between git changes in editor ([#265](https://github.com/batonogov/pine/issues/265)) ([2ec7a80](https://github.com/batonogov/pine/commit/2ec7a80e5df67368ec947503a181f95b97d4a138))
* support file encoding detection beyond UTF-8 ([#271](https://github.com/batonogov/pine/issues/271)) ([ee17cfd](https://github.com/batonogov/pine/commit/ee17cfda2287ddce0da7ba1494537be51270ad06))


### Bug Fixes

* add SF Symbol icons to all menu items for consistent alignment ([#269](https://github.com/batonogov/pine/issues/269)) ([f21d688](https://github.com/batonogov/pine/commit/f21d688eed18510f0c4a4ef312875047e6b103a9))
* resolve session restore UI test flaky on CI ([#272](https://github.com/batonogov/pine/issues/272)) ([691308e](https://github.com/batonogov/pine/commit/691308e96d36a9afe7718657ac38109c0267702b))
* scope all session metadata to project root files only ([#270](https://github.com/batonogov/pine/issues/270)) ([42ac8bd](https://github.com/batonogov/pine/commit/42ac8bd5ca2de5f93ec65af571e6cbf580713e22))

## [1.5.1](https://github.com/batonogov/pine/compare/v1.5.0...v1.5.1) (2026-03-20)


### Bug Fixes

* add bottom inset to editor so last line is not clipped ([#264](https://github.com/batonogov/pine/issues/264)) ([b21a5d7](https://github.com/batonogov/pine/commit/b21a5d73197957bcc5ff520791b46a2aff67ec30))
* remove contentMargins that clips first item in Welcome recent projects list ([#263](https://github.com/batonogov/pine/issues/263)) ([1b58c22](https://github.com/batonogov/pine/commit/1b58c220b10462bf9a8c57862e482723ad78b434)), closes [#207](https://github.com/batonogov/pine/issues/207)

## [1.5.0](https://github.com/batonogov/pine/compare/v1.4.0...v1.5.0) (2026-03-19)


### Features

* add 18 syntax grammars, pattern-based filename matching, and CSS-in-HTML highlighting ([#239](https://github.com/batonogov/pine/issues/239)) ([6d47261](https://github.com/batonogov/pine/commit/6d47261a879edf679cb9e25267d4f0e45dccdc3d))
* add global project search (Cmd+Shift+F) ([#226](https://github.com/batonogov/pine/issues/226)) ([2482421](https://github.com/batonogov/pine/commit/2482421f5b2bc65de8fe3d8eff1d92e7aed16de6))
* replace sidebar segmented picker with native .searchable ([#246](https://github.com/batonogov/pine/issues/246)) ([598162a](https://github.com/batonogov/pine/commit/598162a11c26d541c8b3093eb1975650ff210238))
* support block comments (Cmd+/) for HTML, CSS, Markdown, and SQL ([#238](https://github.com/batonogov/pine/issues/238)) ([d047755](https://github.com/batonogov/pine/commit/d047755258751212c603f7e6ee8b8ddf43a7e005))


### Bug Fixes

* copy ignoredPaths from background git provider ([#211](https://github.com/batonogov/pine/issues/211)) ([e9dfb30](https://github.com/batonogov/pine/commit/e9dfb30316d5035e191716cc6f9dd684a037696f))
* place comment character at column 0, preserving indentation after it ([#255](https://github.com/batonogov/pine/issues/255)) ([da68b3b](https://github.com/batonogov/pine/commit/da68b3b55b45693c142968529d69a2257582b17f))
* prevent cursor jumping to end of file after deleting a character ([#253](https://github.com/batonogov/pine/issues/253)) ([75531bb](https://github.com/batonogov/pine/commit/75531bb72d8aa30d9765bba1e57bc3e3a3aeebbd)), closes [#250](https://github.com/batonogov/pine/issues/250)
* prevent deadlock by disabling undo registration during syntax highlighting ([#254](https://github.com/batonogov/pine/issues/254)) ([32a1283](https://github.com/batonogov/pine/commit/32a128374c97972a7df2f512a219b1c2fa6f0ca8))
* run git refresh asynchronously to prevent SIGSEGV on folder delete ([#213](https://github.com/batonogov/pine/issues/213)) ([96ad0cc](https://github.com/batonogov/pine/commit/96ad0cc89de9e865747a13ed3aa5c801a2ac1992))


### Performance Improvements

* speed up opening large projects ([#240](https://github.com/batonogov/pine/issues/240)) ([e3870d0](https://github.com/batonogov/pine/commit/e3870d0f5a49028dc8f15f0b766f90123d8fa541))


### Miscellaneous

* update localizations for new UI strings ([#241](https://github.com/batonogov/pine/issues/241)) ([65aa881](https://github.com/batonogov/pine/commit/65aa8816b2eb43686be85a9f80edb4a7f3af4290))

## [1.4.0](https://github.com/batonogov/pine/compare/v1.3.0...v1.4.0) (2026-03-18)


### Features

* add lightbox for landing page screenshots ([#202](https://github.com/batonogov/pine/issues/202)) ([97f3665](https://github.com/batonogov/pine/commit/97f366525acbd71e2a693b1c002cd076f5917988))
* show recent projects in Dock context menu ([#206](https://github.com/batonogov/pine/issues/206)) ([7d2d845](https://github.com/batonogov/pine/commit/7d2d8459ef867beffe1f613410caf1165967dc4c))


### Bug Fixes

* propagate untracked status to files and subdirectories inside untracked dirs ([#205](https://github.com/batonogov/pine/issues/205)) ([ea75208](https://github.com/batonogov/pine/commit/ea7520834e28fc357277f4837b28640d8a6383e3))
* update Homebrew tap with versioned DMG filename ([#198](https://github.com/batonogov/pine/issues/198)) ([29fced4](https://github.com/batonogov/pine/commit/29fced412c00b76fb85bd96fc649f7dcbd4b112a))


### Performance Improvements

* fix editor scroll lag on large files ([#203](https://github.com/batonogov/pine/issues/203)) ([d4a1435](https://github.com/batonogov/pine/commit/d4a1435f069f3e7eed49d3750e0aae27cda3a2f1))

## [1.3.0](https://github.com/batonogov/pine/compare/v1.2.1...v1.3.0) (2026-03-18)


### Features

* show formatted changelog in Sparkle update dialog ([#194](https://github.com/batonogov/pine/issues/194)) ([f12de06](https://github.com/batonogov/pine/commit/f12de063948e78166bb85145125fb2469f062c80))


### Bug Fixes

* rename DMG file before upload to match appcast URL ([#192](https://github.com/batonogov/pine/issues/192)) ([a752e09](https://github.com/batonogov/pine/commit/a752e090bd3183d00cbb82acbe5c977a48f378a8))


### Documentation

* update README and landing page for v1.1.0 ([#186](https://github.com/batonogov/pine/issues/186)) ([9b9b5b6](https://github.com/batonogov/pine/commit/9b9b5b63a77dfcab15c4491ed888125fd224cc12))
* update screenshots for macOS 26 Liquid Glass UI ([#193](https://github.com/batonogov/pine/issues/193)) ([18bdcee](https://github.com/batonogov/pine/commit/18bdcee99787c548cd894923d080ae4dc1d99a2b))

## [1.2.1](https://github.com/batonogov/pine/compare/v1.2.0...v1.2.1) (2026-03-18)


### Bug Fixes

* show abbreviated path (~/) in Welcome recent projects ([#185](https://github.com/batonogov/pine/issues/185)) ([2e24b80](https://github.com/batonogov/pine/commit/2e24b807b8ae87c4fda4510de1836791c754a48d))

## [1.2.0](https://github.com/batonogov/pine/compare/v1.1.0...v1.2.0) (2026-03-18)


### Features

* integrate Sparkle for in-app auto-updates ([#152](https://github.com/batonogov/pine/issues/152)) ([8f2f477](https://github.com/batonogov/pine/commit/8f2f4774b6dbd7dbd8ddc52c2fef13d332263198))
* polish project window chrome ([#181](https://github.com/batonogov/pine/issues/181)) ([fd3a51a](https://github.com/batonogov/pine/commit/fd3a51a009363929494960c9cc5d97c3a395c522))


### Bug Fixes

* prevent file tree symlink traversal outside project root and break cycles ([#183](https://github.com/batonogov/pine/issues/183)) ([c93b86a](https://github.com/batonogov/pine/commit/c93b86ae978c024672bc8d6f29588c34d6077e3d))

## [1.1.0](https://github.com/batonogov/pine/compare/v1.0.0...v1.1.0) (2026-03-17)


### Features

* add C and C++ syntax highlighting grammars ([#156](https://github.com/batonogov/pine/issues/156)) ([03743e8](https://github.com/batonogov/pine/commit/03743e88cfa5908bfc81de310d9d79c9cb2d5dbe)), closes [#70](https://github.com/batonogov/pine/issues/70)
* add Cmd+T shortcut for new terminal tab ([#175](https://github.com/batonogov/pine/issues/175)) ([3582aa7](https://github.com/batonogov/pine/commit/3582aa7b55ad81a72d65a46878e83286db0f476e))
* add minimap to code editor ([#171](https://github.com/batonogov/pine/issues/171)) ([4a43512](https://github.com/batonogov/pine/commit/4a435121850b895461319356c70f7afed01a73bc))
* add SQL syntax highlighting grammar ([#177](https://github.com/batonogov/pine/issues/177)) ([9349efa](https://github.com/batonogov/pine/commit/9349efa4cce33dbc633f25f519f639f37bca53f7))
* add toggle line comment with Cmd+/ ([#178](https://github.com/batonogov/pine/issues/178)) ([3c68f20](https://github.com/batonogov/pine/commit/3c68f203d696289506a47ea0f713f93154f067ef))
* bracket matching and highlight ([#176](https://github.com/batonogov/pine/issues/176)) ([b726adf](https://github.com/batonogov/pine/commit/b726adfe54b8c25c2d051ef484fe92a91d6eb2d9))
* editor font size zoom (Cmd+Plus/Minus) ([#180](https://github.com/batonogov/pine/issues/180)) ([22e41d6](https://github.com/batonogov/pine/commit/22e41d617414901f55cc8f4dc05f6af3e327354c))
* large file warning before opening ([#179](https://github.com/batonogov/pine/issues/179)) ([9bcf5b7](https://github.com/batonogov/pine/commit/9bcf5b79ffa9a42dfa0bbbd7a8e9c8a2770d763d))
* persist terminal sessions across window close and app restart ([#173](https://github.com/batonogov/pine/issues/173)) ([e0e9374](https://github.com/batonogov/pine/commit/e0e937414549d93d6aafabdc045496ad73739e7f))


### Bug Fixes

* restrict Markdown preview links to safe URL schemes ([#174](https://github.com/batonogov/pine/issues/174)) ([26eed10](https://github.com/batonogov/pine/commit/26eed101211a7eb2acb7a91bb5777b5e0ee0886b)), closes [#167](https://github.com/batonogov/pine/issues/167)

## [1.0.0](https://github.com/batonogov/pine/compare/v0.12.8...v1.0.0) (2026-03-17)


### ⚠ BREAKING CHANGES

* prepare for 1.0.0 release ([#137](https://github.com/batonogov/pine/issues/137))

### Miscellaneous

* prepare for 1.0.0 release ([#137](https://github.com/batonogov/pine/issues/137)) ([40b56da](https://github.com/batonogov/pine/commit/40b56da1fac846c06f2efb4e4012d35977d111d6))

## [0.12.8](https://github.com/batonogov/pine/compare/v0.12.7...v0.12.8) (2026-03-17)


### Features

* rewrite landing page and README for "fast, minimal, native" positioning ([#153](https://github.com/batonogov/pine/issues/153)) ([965d8fb](https://github.com/batonogov/pine/commit/965d8fbd402285da9c631d05213cab089736eb92))

## [0.12.7](https://github.com/batonogov/pine/compare/v0.12.6...v0.12.7) (2026-03-17)


### Bug Fixes

* add missing localizations for menu.togglePreview ([#148](https://github.com/batonogov/pine/issues/148)) ([fadb9f0](https://github.com/batonogov/pine/commit/fadb9f056620292b513536fe517012cdcda456aa))
* implement Xcode-style branch switching ([#145](https://github.com/batonogov/pine/issues/145)) ([e25fc24](https://github.com/batonogov/pine/commit/e25fc2475ca84b8fd9c19ae2f140cc245edfd650))
* reset top content margins on Welcome recent projects list ([#114](https://github.com/batonogov/pine/issues/114)) ([#151](https://github.com/batonogov/pine/issues/151)) ([959710f](https://github.com/batonogov/pine/commit/959710f326dcd4ba2415eecf64c4d309e015076c))
* show file save errors in UI instead of console ([#150](https://github.com/batonogov/pine/issues/150)) ([ebfbcf0](https://github.com/batonogov/pine/commit/ebfbcf004fdce2c984a1c2a1899cd6c2361fc10b))

## [0.12.6](https://github.com/batonogov/pine/compare/v0.12.5...v0.12.6) (2026-03-16)


### Features

* add duplicate action for directories in sidebar ([#140](https://github.com/batonogov/pine/issues/140)) ([eb435f7](https://github.com/batonogov/pine/commit/eb435f77c30907f646d6fac8e3d5576b8c90e826))


### Bug Fixes

* show line number for trailing empty line ([#142](https://github.com/batonogov/pine/issues/142)) ([30120a2](https://github.com/batonogov/pine/commit/30120a24042bcd33ddd3046c7676b3d50fd73421)), closes [#128](https://github.com/batonogov/pine/issues/128)
* show text content for files with unrecognized extensions ([#144](https://github.com/batonogov/pine/issues/144)) ([35f6eb7](https://github.com/batonogov/pine/commit/35f6eb78f981eaf51036fcdfa4e4298293e1820a)), closes [#143](https://github.com/batonogov/pine/issues/143)

## [0.12.5](https://github.com/batonogov/pine/compare/v0.12.4...v0.12.5) (2026-03-15)


### Features

* add native Markdown preview with source/preview/split modes ([#56](https://github.com/batonogov/pine/issues/56)) ([#136](https://github.com/batonogov/pine/issues/136)) ([f0c008f](https://github.com/batonogov/pine/commit/f0c008f2fc321eb11053810c7142baa095e717ef))
* add Quick Look preview for non-text files ([#135](https://github.com/batonogov/pine/issues/135)) ([4823424](https://github.com/batonogov/pine/commit/48234249184c85afc100d6fbcc334f8a3dec5cdf))


### Bug Fixes

* improve YAML syntax highlighting for nested keys, block scalars, and tags ([#132](https://github.com/batonogov/pine/issues/132)) ([455c7f3](https://github.com/batonogov/pine/commit/455c7f386544e3b008e6286abd2a80e3647a4366)), closes [#129](https://github.com/batonogov/pine/issues/129)
* sync sidebar selection after session restore ([#127](https://github.com/batonogov/pine/issues/127)) ([8192a14](https://github.com/batonogov/pine/commit/8192a149fd2c4c032259ad5c805bd16e52ad66bb))


### Miscellaneous

* upgrade actions/checkout from v4 to v6 (Node.js 24) ([#133](https://github.com/batonogov/pine/issues/133)) ([5b37356](https://github.com/batonogov/pine/commit/5b373564a72575bba8fa1b9aded17fa9d02ac2aa)), closes [#122](https://github.com/batonogov/pine/issues/122)

## [0.12.4](https://github.com/batonogov/pine/compare/v0.12.3...v0.12.4) (2026-03-15)


### Bug Fixes

* increase default window size and sidebar width ([#124](https://github.com/batonogov/pine/issues/124)) ([79600b5](https://github.com/batonogov/pine/commit/79600b5d30aaa0f80b2c87e9e8b917d3ad9aab54))

## [0.12.3](https://github.com/batonogov/pine/compare/v0.12.2...v0.12.3) (2026-03-15)


### Bug Fixes

* close button closes window instead of tabs one by one ([#111](https://github.com/batonogov/pine/issues/111)) ([9ad8f4c](https://github.com/batonogov/pine/commit/9ad8f4cc2dab53b26889453ba9cbb5cb004f0ebc))
* ensure Welcome window always reappears after closing project window ([#121](https://github.com/batonogov/pine/issues/121)) ([4a7f000](https://github.com/batonogov/pine/commit/4a7f000f04956fbef3d0f51dd7d2a51810ac1e4f))
* highlight active file in sidebar file tree ([#118](https://github.com/batonogov/pine/issues/118)) ([a1ba1ae](https://github.com/batonogov/pine/commit/a1ba1aeace0073a14ddbd531f25c9648f4b7b624)), closes [#115](https://github.com/batonogov/pine/issues/115)


### Documentation

* improve Russian landing page copy ([#113](https://github.com/batonogov/pine/issues/113)) ([a576373](https://github.com/batonogov/pine/commit/a576373f7459a403b5fdc14895062f1e21698b30))

## [0.12.2](https://github.com/batonogov/pine/compare/v0.12.1...v0.12.2) (2026-03-14)


### Features

* add Release Please for automated versioning and changelog ([79fa83f](https://github.com/batonogov/pine/commit/79fa83f585f95e640f278ea75c34e1e155478b93))


### Bug Fixes

* address review remarks in manager tests ([bbf0acb](https://github.com/batonogov/pine/commit/bbf0acb4a0751b113fb9d9add2d5dc2c98ef8de1))
* use PAT token in release-please and handle existing releases ([ad2abae](https://github.com/batonogov/pine/commit/ad2abae56617e93bb5d1adcab0007c82e5b69a2d))


### Miscellaneous

* fix review remarks for release-please setup ([45fc987](https://github.com/batonogov/pine/commit/45fc98741ebe6b3ee2fe74bea0a8d16d886c10cd))
* **main:** release 0.12.1 ([5a49267](https://github.com/batonogov/pine/commit/5a492679a8cfcda250d245cd3f5942b2fc6d0e32))
* **main:** release 0.12.1 ([aca8151](https://github.com/batonogov/pine/commit/aca81518887a3934209d3fe3364c2066305d7601))

## [0.12.1](https://github.com/batonogov/pine/compare/v0.12.0...v0.12.1) (2026-03-14)


### Features

* add Release Please for automated versioning and changelog ([79fa83f](https://github.com/batonogov/pine/commit/79fa83f585f95e640f278ea75c34e1e155478b93))


### Miscellaneous

* fix review remarks for release-please setup ([45fc987](https://github.com/batonogov/pine/commit/45fc98741ebe6b3ee2fe74bea0a8d16d886c10cd))
