# Changelog

## [1.21.0](https://github.com/batonogov/pine/compare/v1.20.1...v1.21.0) (2026-04-10)


### Features

* **editor:** add SmartListContinuation pure logic ([#803](https://github.com/batonogov/pine/issues/803)) ([c74bf85](https://github.com/batonogov/pine/commit/c74bf8540c834e57cde571c380ef374998a87a83))
* **grammar:** add setext headings, image links, nested emphasis to markdown ([#786](https://github.com/batonogov/pine/issues/786)) ([8a71f7c](https://github.com/batonogov/pine/commit/8a71f7c36240721eed6b3b28a71a877d02701215))


### Bug Fixes

* **editor:** diagnostic gutter icon hover/click regression ([#784](https://github.com/batonogov/pine/issues/784)) ([87840cb](https://github.com/batonogov/pine/commit/87840cbd95d037de1c2cc25273b9a03004bdb6cd))
* **editor:** guard SyntaxHighlighter against nil attribute values and concurrent access ([#801](https://github.com/batonogov/pine/issues/801)) ([fb46272](https://github.com/batonogov/pine/commit/fb4627283748acadf38afd22a9327a21465de2c4)), closes [#790](https://github.com/batonogov/pine/issues/790)
* **editor:** restore git diff gutter updates in split panes ([#782](https://github.com/batonogov/pine/issues/782)) ([609773b](https://github.com/batonogov/pine/commit/609773b0c94b3f4eb9633771d3b3f425c0d7ffe6))
* **grammar:** scan full text for multiline rules (fenced code interiors) ([#789](https://github.com/batonogov/pine/issues/789)) ([5584225](https://github.com/batonogov/pine/commit/5584225863b1016638306dcfb4c0743512861850))
* **sidebar:** refresh tree promptly for changes from built-in terminal ([#774](https://github.com/batonogov/pine/issues/774)) ([#777](https://github.com/batonogov/pine/issues/777)) ([0485df3](https://github.com/batonogov/pine/commit/0485df32116e6161e03afb570fbe5173c9acf917))


### Code Refactoring

* **app:** split PineApp.swift into menu commands and notifications ([#785](https://github.com/batonogov/pine/issues/785)) ([2ea3bc3](https://github.com/batonogov/pine/commit/2ea3bc3b3969097244e6dfe797c332982d491899))
* **editor:** split CodeEditorView.swift into focused files ([#797](https://github.com/batonogov/pine/issues/797)) ([370c91c](https://github.com/batonogov/pine/commit/370c91cbc895886b7c5273639221778146b6a66a))

## [1.20.1](https://github.com/batonogov/pine/compare/v1.20.0...v1.20.1) (2026-04-09)


### Bug Fixes

* **sidebar:** align file-leaf icons with folder icons via chevron-width spacer ([#770](https://github.com/batonogov/pine/issues/770)) ([770fe2f](https://github.com/batonogov/pine/commit/770fe2fb9355ee689fce2b14e14a1b0b25cc7537))
* **sidebar:** flatten file tree alignment by removing chevron ([#778](https://github.com/batonogov/pine/issues/778)) ([1690758](https://github.com/batonogov/pine/commit/1690758297bce760350d83333c4ff8180752d10b))
* **sidebar:** unify vertical rhythm across nesting levels ([#766](https://github.com/batonogov/pine/issues/766)) ([e69c5d6](https://github.com/batonogov/pine/commit/e69c5d62e2521d69b9be6ddcb7a6fe7598806001))
* **terminal:** match Terminal.app Basic palette for TUI parity ([#768](https://github.com/batonogov/pine/issues/768)) ([7b091bc](https://github.com/batonogov/pine/commit/7b091bc57581933b0564fd56786763f39c2caf87))

## [1.20.0](https://github.com/batonogov/pine/compare/v1.19.0...v1.20.0) (2026-04-07)


### Features

* **sidebar:** rename files and folders with Enter key ([#742](https://github.com/batonogov/pine/issues/742)) ([97bfc98](https://github.com/batonogov/pine/commit/97bfc980929836d14cbc06d4515d5b52032fc942))


### Bug Fixes

* **ci:** unblock screenshots workflow blocked by gitignored asset paths ([#760](https://github.com/batonogov/pine/issues/760)) ([3e96b96](https://github.com/batonogov/pine/commit/3e96b96d3f689f8339d7dea19655903bc5f65466))

## [1.19.0](https://github.com/batonogov/pine/compare/v1.18.3...v1.19.0) (2026-04-07)


### Features

* **sidebar:** expand folder on row click ([#747](https://github.com/batonogov/pine/issues/747)) ([6fb42fe](https://github.com/batonogov/pine/commit/6fb42fec0c43a44944a27f1baba9eff07a2923df))


### Bug Fixes

* **grammars:** unify dict key scope across Python, Ruby, JSON, YAML ([#745](https://github.com/batonogov/pine/issues/745)) ([2f96059](https://github.com/batonogov/pine/commit/2f96059cce40ba4281aeafb2594e1bb5df00b783))
* **sidebar:** align inline rename row with siblings ([#748](https://github.com/batonogov/pine/issues/748)) ([8733b36](https://github.com/batonogov/pine/commit/8733b3649ac231a325fa134e52aeb3188b18984e))
* **terminal:** restore readable bright-black for zsh autosuggestions ([#754](https://github.com/batonogov/pine/issues/754)) ([748ddc5](https://github.com/batonogov/pine/commit/748ddc5352191ba8482aa5305fe0dc35e037f39e))

## [1.18.3](https://github.com/batonogov/pine/compare/v1.18.2...v1.18.3) (2026-04-07)


### Bug Fixes

* **ci:** make Detect Changes fail-safe on unreachable base SHA ([#752](https://github.com/batonogov/pine/issues/752)) ([3e38e3a](https://github.com/batonogov/pine/commit/3e38e3a9d52b107a58ad40f4f3e6a48851bb3d6c)), closes [#751](https://github.com/batonogov/pine/issues/751)
* **ci:** repair screenshots workflow (Swift 6 race + xcresult extraction) ([#746](https://github.com/batonogov/pine/issues/746)) ([b6f29e1](https://github.com/batonogov/pine/commit/b6f29e1b53620fdaeddb52a16593863f2aeb1c49))
* **git:** stop status indicator flicker on rapid updates ([#744](https://github.com/batonogov/pine/issues/744)) ([f150928](https://github.com/batonogov/pine/commit/f150928478d09159f3d1fce3cba4306d4636b1e3)), closes [#738](https://github.com/batonogov/pine/issues/738)
* **grammar:** markdown syntax highlighting hierarchy ([#735](https://github.com/batonogov/pine/issues/735)) ([79a2959](https://github.com/batonogov/pine/commit/79a29590580e148a52f0e448815de9deef6430db))
* reload editor content on external file change ([#734](https://github.com/batonogov/pine/issues/734)) ([#743](https://github.com/batonogov/pine/issues/743)) ([a6afebf](https://github.com/batonogov/pine/commit/a6afebf0029b46cff9cca5d00b8df294783ca1cb))
* **terminal:** align SwiftTerm ANSI palette with macOS system colors ([#741](https://github.com/batonogov/pine/issues/741)) ([e2faef3](https://github.com/batonogov/pine/commit/e2faef3d22a11d6f9b8ac84f7f0381a8564e4408)), closes [#733](https://github.com/batonogov/pine/issues/733)


### Code Refactoring

* **tests:** migrate PineTests to Swift 6 mode ([#729](https://github.com/batonogov/pine/issues/729)) ([ba54411](https://github.com/batonogov/pine/commit/ba544110d322f6b65758ff09ad8b9c687833209b)), closes [#579](https://github.com/batonogov/pine/issues/579)

## [1.18.2](https://github.com/batonogov/pine/compare/v1.18.1...v1.18.2) (2026-04-06)


### Bug Fixes

* **concurrency:** nonisolated InlineDiffProvider + CI guard for background queues ([#719](https://github.com/batonogov/pine/issues/719)) ([576e150](https://github.com/batonogov/pine/commit/576e15066b7838f041af6a20b94fc2f0d7d5d9ed))
* diagnostic icons show explanation via tooltip and popover ([#679](https://github.com/batonogov/pine/issues/679)) ([#720](https://github.com/batonogov/pine/issues/720)) ([3a22964](https://github.com/batonogov/pine/commit/3a229647068d7097246cf7c3661e0b71f6ee1827))

## [1.18.1](https://github.com/batonogov/pine/compare/v1.18.0...v1.18.1) (2026-04-06)


### Bug Fixes

* prune empty editor leaf when surrounded by terminals ([#725](https://github.com/batonogov/pine/issues/725)) ([856a7c8](https://github.com/batonogov/pine/commit/856a7c8091faa3e95fdd36a34f02fb1e8d816241))

## [1.18.0](https://github.com/batonogov/pine/compare/v1.17.0...v1.18.0) (2026-04-06)


### Features

* cross-type center drop creates auto-split pane ([#714](https://github.com/batonogov/pine/issues/714)) ([#715](https://github.com/batonogov/pine/issues/715)) ([32b254b](https://github.com/batonogov/pine/commit/32b254bee22c394cb9bb3a3748526db1bfad0040))
* drag files from sidebar to open in specific editor pane ([#709](https://github.com/batonogov/pine/issues/709)) ([48a5cf3](https://github.com/batonogov/pine/commit/48a5cf376af5e81980701ba30233add476aa5007))
* root-level drop zones for full-width/height pane splits ([#713](https://github.com/batonogov/pine/issues/713)) ([9ff1755](https://github.com/batonogov/pine/commit/9ff17559c356ce36ac44de9e133a301999af9b56))
* split panes with terminal integration ([#543](https://github.com/batonogov/pine/issues/543)) ([#707](https://github.com/batonogov/pine/issues/707)) ([d04be74](https://github.com/batonogov/pine/commit/d04be74be3d07aec444a8f95d7dbb6447574390d))
* terminal tab drag-and-drop reorder and cross-pane move ([#711](https://github.com/batonogov/pine/issues/711)) ([859a813](https://github.com/batonogov/pine/commit/859a8137df8f24e6c0c027d0aa9c48c98ec15558))


### Bug Fixes

* clear stale pane drop-zone overlays after sidebar drag ([#710](https://github.com/batonogov/pine/issues/710)) ([#716](https://github.com/batonogov/pine/issues/716)) ([00409ac](https://github.com/batonogov/pine/commit/00409acab1f64cef2c740dcf7856e95a6adfa49c))


### Miscellaneous

* update SwiftTerm to fix windowCommand crash ([#717](https://github.com/batonogov/pine/issues/717)) ([08323c4](https://github.com/batonogov/pine/commit/08323c4086b65d17f962c3d7ff1371bae1e1797d))

## [1.17.0](https://github.com/batonogov/pine/compare/v1.16.1...v1.17.0) (2026-03-31)


### Features

* add file icons for Terraform, Helm, Vagrant, and DevOps tooling ([#702](https://github.com/batonogov/pine/issues/702)) ([44fb658](https://github.com/batonogov/pine/commit/44fb658734f7ab3c81966027ddb2e1d330d99e73))

## [1.16.1](https://github.com/batonogov/pine/compare/v1.16.0...v1.16.1) (2026-03-31)


### Bug Fixes

* resolve ConfigValidator SIGTRAP crash ([#700](https://github.com/batonogov/pine/issues/700)) ([018e6cc](https://github.com/batonogov/pine/commit/018e6cc0e0f8297fba7f85e0e42b0a199623b499))

## [1.16.0](https://github.com/batonogov/pine/compare/v1.15.0...v1.16.0) (2026-03-31)


### Features

* enable Swift 6 language mode for Pine app target ([#657](https://github.com/batonogov/pine/issues/657)) ([3d5d26d](https://github.com/batonogov/pine/commit/3d5d26d955674dc7e6ece3257ce07523c4f6534d))


### Bug Fixes

* allow docs-only PRs to pass required CI checks ([#656](https://github.com/batonogov/pine/issues/656)) ([#682](https://github.com/batonogov/pine/issues/682)) ([87beb8c](https://github.com/batonogov/pine/commit/87beb8ca66b17cd195764671185e52ac6bdcec73))
* improve inline diff rendering — remove strikethrough, yellow markers ([#678](https://github.com/batonogov/pine/issues/678)) ([#681](https://github.com/batonogov/pine/issues/681)) ([6e94088](https://github.com/batonogov/pine/commit/6e94088c99faf76fd7653eab7e14fbbb8dba6b0a))
* move git fetch operations to non-MainActor GitFetcher enum ([#613](https://github.com/batonogov/pine/issues/613)) ([#683](https://github.com/batonogov/pine/issues/683)) ([2e2feaa](https://github.com/batonogov/pine/commit/2e2feaa687f5f28daf3c79f2bf23385005b0c1da))
* remove broken accept/revert buttons from gutter ([#690](https://github.com/batonogov/pine/issues/690)) ([2e6b87e](https://github.com/batonogov/pine/commit/2e6b87ed1b8d523ecb4ff1d79fd28a21accb3af5))
* remove phantom overlay for modified lines ([#681](https://github.com/batonogov/pine/issues/681)) ([#685](https://github.com/batonogov/pine/issues/685)) ([4a674d3](https://github.com/batonogov/pine/commit/4a674d39e5ffd86101fbba6bc2cc5c4868cf64a9))
* stabilize gutter width and add diagnostic tooltips ([#677](https://github.com/batonogov/pine/issues/677), [#679](https://github.com/batonogov/pine/issues/679)) ([#680](https://github.com/batonogov/pine/issues/680)) ([6f8e74e](https://github.com/batonogov/pine/commit/6f8e74e953c26162506a2df43251d8acf399210c))

## [1.15.0](https://github.com/batonogov/pine/compare/v1.14.0...v1.15.0) (2026-03-30)


### Features

* add file type icon colors in sidebar, tab bar, and quick open ([#644](https://github.com/batonogov/pine/issues/644)) ([61106a0](https://github.com/batonogov/pine/commit/61106a00d5999f859b2b4fa621091670cb995c17))
* add inline config validation for YAML, Terraform, shell scripts, and Dockerfiles ([#314](https://github.com/batonogov/pine/issues/314)) ([#627](https://github.com/batonogov/pine/issues/627)) ([85ddb19](https://github.com/batonogov/pine/commit/85ddb1932a208cdedc3cf5190aa606b27a07236a))
* add tab context menu with close, copy path, reveal actions ([#634](https://github.com/batonogov/pine/issues/634)) ([#641](https://github.com/batonogov/pine/issues/641)) ([9f5bfa9](https://github.com/batonogov/pine/commit/9f5bfa9a84bf0b23f7c2ea4156f0c8e73408cfc3))
* add toast notifications for live file reload ([#312](https://github.com/batonogov/pine/issues/312)) ([#628](https://github.com/batonogov/pine/issues/628)) ([3077b22](https://github.com/batonogov/pine/commit/3077b223bcdc82ccbd5916b8044465ed2ba7c799))
* add validation diagnostic icons in editor gutter ([#648](https://github.com/batonogov/pine/issues/648)) ([#658](https://github.com/batonogov/pine/issues/658)) ([7845636](https://github.com/batonogov/pine/commit/784563651c2ee19a60d4c201a2d069be3cd32bd8))
* inline diff review with Accept/Revert for AI agent changes ([#313](https://github.com/batonogov/pine/issues/313)) ([#632](https://github.com/batonogov/pine/issues/632)) ([2982e9b](https://github.com/batonogov/pine/commit/2982e9bae0ff0dac4d830cdc95f9271ea28089ce))
* migrate Pine app target to Swift 6 and tighten concurrency ([#626](https://github.com/batonogov/pine/issues/626)) ([d4789fc](https://github.com/batonogov/pine/commit/d4789fc3d49c3383440ef528ec55d8cad0b1265d))
* prepare codebase for Swift 6 strict concurrency ([#574](https://github.com/batonogov/pine/issues/574)) ([#625](https://github.com/batonogov/pine/issues/625)) ([56d0cf8](https://github.com/batonogov/pine/commit/56d0cf8ef4dcaf43f34c38de5686d2096272c494))
* send selected code to terminal via Cmd+Shift+Enter ([#311](https://github.com/batonogov/pine/issues/311)) ([#630](https://github.com/batonogov/pine/issues/630)) ([c89e27d](https://github.com/batonogov/pine/commit/c89e27db378ae4625bd77c8303f462cc9249c666))
* show inline diff on gutter click instead of always visible ([#672](https://github.com/batonogov/pine/issues/672)) ([#676](https://github.com/batonogov/pine/issues/676)) ([0aa4c31](https://github.com/batonogov/pine/commit/0aa4c310f6b1a7597fc1e46981bce741252498ff))


### Bug Fixes

* add built-in validators so diagnostic icons appear without external tools ([#663](https://github.com/batonogov/pine/issues/663)) ([#666](https://github.com/batonogov/pine/issues/666)) ([454e6fb](https://github.com/batonogov/pine/commit/454e6fbcc56119b6a5298cf39f0d745fa10ae0c3))
* add visual before/after comparison for inline diff review ([#664](https://github.com/batonogov/pine/issues/664)) ([09ef5da](https://github.com/batonogov/pine/commit/09ef5daff9c9519047475bec87b6f3dd775ef393))
* capture editedRange via NSTextStorageDelegate for incremental highlighting ([#655](https://github.com/batonogov/pine/issues/655)) ([bb452b2](https://github.com/batonogov/pine/commit/bb452b2d81e4e080c1ab172ffa6e1a410517dd7d))
* improve config validator accuracy and add fallback ([#663](https://github.com/batonogov/pine/issues/663)) ([#667](https://github.com/batonogov/pine/issues/667)) ([cfeef3a](https://github.com/batonogov/pine/commit/cfeef3a24ce7922cf18765bc737120e7676fbc7e))
* make screenshot extraction work on macOS 26 with fallback strategies ([#622](https://github.com/batonogov/pine/issues/622)) ([af2d0b5](https://github.com/batonogov/pine/commit/af2d0b5be1b6fc9fc32a455a07257206c5b9f6a4))
* prevent blank terminal by deferring PTY start until non-zero size ([#662](https://github.com/batonogov/pine/issues/662)) ([f6f1fef](https://github.com/batonogov/pine/commit/f6f1fef3ba3f7b9a7ceeb6512617b1aa0b6ba22d))
* prevent diagnostic icon from overlapping line numbers in gutter ([#669](https://github.com/batonogov/pine/issues/669)) ([#670](https://github.com/batonogov/pine/issues/670)) ([84199e4](https://github.com/batonogov/pine/commit/84199e4e77130005875c4a49edb7c43b67a532b9))
* prevent EXC_BAD_ACCESS crash on Cmd+Z by deferring syntax highlighting during undo ([#650](https://github.com/batonogov/pine/issues/650)) ([#653](https://github.com/batonogov/pine/issues/653)) ([1ca7864](https://github.com/batonogov/pine/commit/1ca78642d5a3543f9bb542ec2b5fe5dfb84d73e2))
* prevent stale highlight from overwriting colors after newline insertion ([#665](https://github.com/batonogov/pine/issues/665)) ([f2f0b7b](https://github.com/batonogov/pine/commit/f2f0b7b5048c1359779d19775cbbf49bcd40ef43))
* trigger highlighting for session-restored tabs ([#671](https://github.com/batonogov/pine/issues/671)) ([#674](https://github.com/batonogov/pine/issues/674)) ([06edb9b](https://github.com/batonogov/pine/commit/06edb9b99e1cf80196354bd7bc88cd16f4a3ed73))
* work around QuickLookUI crash on macOS 26 ([#675](https://github.com/batonogov/pine/issues/675)) ([7de8b75](https://github.com/batonogov/pine/commit/7de8b75dd1206f334783e0de8d33090f9134308c))


### Performance Improvements

* lazy syntax highlighting for visible viewport only ([#640](https://github.com/batonogov/pine/issues/640)) ([91af3aa](https://github.com/batonogov/pine/commit/91af3aaf2640b1a69ed19792fb1319a36a5352dd))


### Documentation

* rewrite README with marketing story and feature overview ([#607](https://github.com/batonogov/pine/issues/607)) ([9b3b714](https://github.com/batonogov/pine/commit/9b3b7148fdcc497f88af82a731c6e36d7b1113c1))


### Miscellaneous

* exclude CodeEditorView.swift from coverage threshold ([#668](https://github.com/batonogov/pine/issues/668)) ([02289b8](https://github.com/batonogov/pine/commit/02289b8dcd537526a66159ac6597850dbcf6b737))

## [1.14.0](https://github.com/batonogov/pine/compare/v1.13.1...v1.14.0) (2026-03-28)


### Features

* add clickable line endings indicator with LF/CRLF conversion ([#277](https://github.com/batonogov/pine/issues/277)) ([#615](https://github.com/batonogov/pine/issues/615)) ([960b16a](https://github.com/batonogov/pine/commit/960b16a128550cf76ec08a83dccefcf155f27453))
* auto-update screenshots in assets/ via UI tests ([#608](https://github.com/batonogov/pine/issues/608)) ([17d180f](https://github.com/batonogov/pine/commit/17d180f0c86291ee9397ba8f71488e48ebc0302c))
* migrate PineUITests target to Swift 6 mode ([#614](https://github.com/batonogov/pine/issues/614)) ([2980094](https://github.com/batonogov/pine/commit/29800949f67f10c1d7ad9a941cb09669ef56283a)), closes [#578](https://github.com/batonogov/pine/issues/578)


### Bug Fixes

* disable code signing in screenshot script for CI runners ([#621](https://github.com/batonogov/pine/issues/621)) ([76f4f8d](https://github.com/batonogov/pine/commit/76f4f8d4a71fd25f6c9bce1353e6d2b09060d553))
* guard against nil previewItem in QLPreviewView to prevent crash ([#618](https://github.com/batonogov/pine/issues/618)) ([#619](https://github.com/batonogov/pine/issues/619)) ([1d7ea4b](https://github.com/batonogov/pine/commit/1d7ea4b097338d853c73834aefed5ef731d9ed8f))
* make About panel tests locale-independent ([#576](https://github.com/batonogov/pine/issues/576)) ([#604](https://github.com/batonogov/pine/issues/604)) ([94ba892](https://github.com/batonogov/pine/commit/94ba8925507095d56131ce99d5a4094a65030a08))
* redesign screenshot tests with XCTAttachment and CI automation ([#289](https://github.com/batonogov/pine/issues/289)) ([#620](https://github.com/batonogov/pine/issues/620)) ([0a8100a](https://github.com/batonogov/pine/commit/0a8100a7b3f809d9e4c9ded9259df834e7421611))
* stabilize flaky debounceCoalescesRapidUpdates test on CI ([#603](https://github.com/batonogov/pine/issues/603)) ([c226405](https://github.com/batonogov/pine/commit/c226405af22b587af950dc6ef983f2c4e525badf))

## [1.13.1](https://github.com/batonogov/pine/compare/v1.13.0...v1.13.1) (2026-03-27)


### Bug Fixes

* align indent guides correctly for tab-indented files ([#587](https://github.com/batonogov/pine/issues/587)) ([#601](https://github.com/batonogov/pine/issues/601)) ([c0a194b](https://github.com/batonogov/pine/commit/c0a194bb4adea28da1e420786c3fb44dcc65f1c0))
* correct match highlighting in project search results ([#575](https://github.com/batonogov/pine/issues/575)) ([#598](https://github.com/batonogov/pine/issues/598)) ([e4baa3e](https://github.com/batonogov/pine/commit/e4baa3ecb7513f268bd0849a06199fd702f008ea))
* eliminate scroll position jump when switching editor tabs ([#595](https://github.com/batonogov/pine/issues/595)) ([#599](https://github.com/batonogov/pine/issues/599)) ([174f660](https://github.com/batonogov/pine/commit/174f660015fbabe6ca5cff72ddcf8f4a8aff82d2))
* prevent editor tabs from overlapping with long file names ([#596](https://github.com/batonogov/pine/issues/596)) ([c8c43cb](https://github.com/batonogov/pine/commit/c8c43cb6e2673160dcc68a6bad4ad23145ece58b))
* remove broken Unicode branch icon from toolbar subtitle ([#594](https://github.com/batonogov/pine/issues/594)) ([#597](https://github.com/batonogov/pine/issues/597)) ([3ef4e46](https://github.com/batonogov/pine/commit/3ef4e465bb9d0ddcba50b2ea7de4fd19ffd46adf))

## [1.13.0](https://github.com/batonogov/pine/compare/v1.12.0...v1.13.0) (2026-03-26)


### Features

* add pane tree data model for flexible split layout ([#569](https://github.com/batonogov/pine/issues/569)) ([7fcd478](https://github.com/batonogov/pine/commit/7fcd47867292bd4aa03001653d68df65fb9fd174))
* add symbol navigation for quick jump to functions and classes ([#306](https://github.com/batonogov/pine/issues/306)) ([#573](https://github.com/batonogov/pine/issues/573)) ([26129d3](https://github.com/batonogov/pine/commit/26129d319e3bb612ab28d9bf58779fe071c28c2b))
* convert scroll to arrow keys for TUI apps on alternate screen ([#567](https://github.com/batonogov/pine/issues/567)) ([4e562fb](https://github.com/batonogov/pine/commit/4e562fb4aa9f8e612b2ce62c068de3f390fd2ac3))
* pass editor context to terminal via environment variables ([#571](https://github.com/batonogov/pine/issues/571)) ([7f2904b](https://github.com/batonogov/pine/commit/7f2904bd1a5c8c89edf9c25c49cdbe2d8dad773b))


### Bug Fixes

* add missing Symbol Navigator localizations for all 9 languages ([#582](https://github.com/batonogov/pine/issues/582)) ([#583](https://github.com/batonogov/pine/issues/583)) ([92dc833](https://github.com/batonogov/pine/commit/92dc8339a8f940e4307b8e7f34c639ff0ca049ed))
* auto-focus terminal on new tab creation and tab switch ([#558](https://github.com/batonogov/pine/issues/558)) ([#560](https://github.com/batonogov/pine/issues/560)) ([129d121](https://github.com/batonogov/pine/commit/129d1218707340c1c02fcf8a0dc64ee6087dd663))
* make terminal view first responder on mouse click in scroll interceptor ([#565](https://github.com/batonogov/pine/issues/565)) ([6fe111a](https://github.com/batonogov/pine/commit/6fe111a6ef5e1e0311d547ad670c266164ab48a5))
* move context file from project root to Application Support ([#590](https://github.com/batonogov/pine/issues/590)) ([#592](https://github.com/batonogov/pine/issues/592)) ([089ac4b](https://github.com/batonogov/pine/commit/089ac4b3877e2776d3bcef3f58aa8644b2872226))
* prevent minimap viewport jump when adding lines at end of file ([#586](https://github.com/batonogov/pine/issues/586)) ([#591](https://github.com/batonogov/pine/issues/591)) ([2c82454](https://github.com/batonogov/pine/commit/2c824544329945848977ac2987cc709b736a8753))
* prevent syntax highlighting from disappearing after initial display ([#556](https://github.com/batonogov/pine/issues/556)) ([#562](https://github.com/batonogov/pine/issues/562)) ([f8cc976](https://github.com/batonogov/pine/commit/f8cc9767ef56d34a70dcf10955a04f93666b0e93))
* rename DocumentSymbol/SymbolKind to resolve type ambiguity with swift-markdown ([#588](https://github.com/batonogov/pine/issues/588)) ([#589](https://github.com/batonogov/pine/issues/589)) ([21e1f67](https://github.com/batonogov/pine/commit/21e1f6743df8ab1813f4a42705ff90c9d62f81f5))
* use scroll interceptor overlay to forward mouse events to TUI apps ([#561](https://github.com/batonogov/pine/issues/561)) ([e85d0ec](https://github.com/batonogov/pine/commit/e85d0ec6b9989e666918cb7776bc6d9b6f8f8e53))


### Code Refactoring

* split ContentView.swift into focused subviews ([#532](https://github.com/batonogov/pine/issues/532)) ([#555](https://github.com/batonogov/pine/issues/555)) ([5411de5](https://github.com/batonogov/pine/commit/5411de580cbfa02436ee2269ecbaa0aa1f687275))

## [1.12.0](https://github.com/batonogov/pine/compare/v1.11.0...v1.12.0) (2026-03-25)


### Features

* add Helm and Jinja2 grammars, enrich Groovy/HCL/Nginx grammars ([#318](https://github.com/batonogov/pine/issues/318)) ([#540](https://github.com/batonogov/pine/issues/540)) ([bf17977](https://github.com/batonogov/pine/commit/bf179778c56b7acfc575c200914bd74601ffb66e))
* add tab pinning support ([#334](https://github.com/batonogov/pine/issues/334)) ([#548](https://github.com/batonogov/pine/issues/548)) ([cb31cc2](https://github.com/batonogov/pine/commit/cb31cc242c9ae352f78744ca0dff90e79ae686ee))
* breadcrumb path bar above editor ([#335](https://github.com/batonogov/pine/issues/335)) ([#536](https://github.com/batonogov/pine/issues/536)) ([cf4b180](https://github.com/batonogov/pine/commit/cf4b180026223efc7194fd16151390c20b770973))
* CLI tool pine command to open files from terminal ([#419](https://github.com/batonogov/pine/issues/419)) ([#535](https://github.com/batonogov/pine/issues/535)) ([15529c6](https://github.com/batonogov/pine/commit/15529c68c72d7b4a81e523c6288941bc1b635119))
* highlight matching brackets at cursor ([#338](https://github.com/batonogov/pine/issues/338)) ([#537](https://github.com/batonogov/pine/issues/537)) ([c48bd69](https://github.com/batonogov/pine/commit/c48bd6977c5495ba493177199849413a0a77289c))
* improve drag & drop tab reorder with visual feedback and spring animations ([#538](https://github.com/batonogov/pine/issues/538)) ([e88005d](https://github.com/batonogov/pine/commit/e88005db3504960334cc26bc43b45ea5d97459bf)), closes [#279](https://github.com/batonogov/pine/issues/279)
* register file type associations for Open With in Finder ([#421](https://github.com/batonogov/pine/issues/421)) ([#534](https://github.com/batonogov/pine/issues/534)) ([a86591d](https://github.com/batonogov/pine/commit/a86591db283a172e71cf4595f929b70d05ce06cc))
* word wrap toggle (Option+Z) ([#416](https://github.com/batonogov/pine/issues/416)) ([#533](https://github.com/batonogov/pine/issues/533)) ([a818313](https://github.com/batonogov/pine/commit/a81831345a9e1418a444de6d676d058680b9f5dd))


### Bug Fixes

* add docs workflow to unblock docs-only PRs ([#552](https://github.com/batonogov/pine/issues/552)) ([#553](https://github.com/batonogov/pine/issues/553)) ([ccf4c82](https://github.com/batonogov/pine/commit/ccf4c8259859518cce320615da030f8d8a2f00d3))
* forward mouse scroll events to TUI apps in terminal ([#524](https://github.com/batonogov/pine/issues/524)) ([#544](https://github.com/batonogov/pine/issues/544)) ([a2dc514](https://github.com/batonogov/pine/commit/a2dc514f4a7e5d36b149cee3fc60fc59644aadd1))
* group create+rename into single undo step via beginUndoGrouping ([#527](https://github.com/batonogov/pine/issues/527)) ([#545](https://github.com/batonogov/pine/issues/545)) ([6246528](https://github.com/batonogov/pine/commit/62465280714905ecf2e787161a8ab1ac58693abf))
* use getpwuid to detect user's default shell instead of $SHELL ([#550](https://github.com/batonogov/pine/issues/550)) ([54f1e61](https://github.com/batonogov/pine/commit/54f1e6154c4edcc6cb90a9797dca68f6c855be93))


### Miscellaneous

* update app icon ([#554](https://github.com/batonogov/pine/issues/554)) ([5979bdd](https://github.com/batonogov/pine/commit/5979bdd7f2f393b6d0fa45d313c4f8d54556a679))

## [1.11.0](https://github.com/batonogov/pine/compare/v1.10.1...v1.11.0) (2026-03-24)


### Features

* About Pine window with version, build, and credits ([#414](https://github.com/batonogov/pine/issues/414)) ([#515](https://github.com/batonogov/pine/issues/515)) ([bf74939](https://github.com/batonogov/pine/commit/bf749391d274eb3f4e5fb668a8ef592b67d6c8c7))
* add defensive coding — depth limits, iteration guards, assertions ([#501](https://github.com/batonogov/pine/issues/501)) ([4725c10](https://github.com/batonogov/pine/commit/4725c10d8c8772528378f24cf6b8bed65fb9a8e6)), closes [#474](https://github.com/batonogov/pine/issues/474)
* add keyboard tab navigation (Cmd+1..9, Ctrl+Tab) and first responder flow ([#518](https://github.com/batonogov/pine/issues/518)) ([a3d062f](https://github.com/batonogov/pine/commit/a3d062ff2431ffb990f320569b16d4d1b105cfaa))
* data migration system for UserDefaults schema changes ([#471](https://github.com/batonogov/pine/issues/471)) ([#505](https://github.com/batonogov/pine/issues/505)) ([f90b7ce](https://github.com/batonogov/pine/commit/f90b7cec8b4a8077607902dc5f60bc4687fce964))
* drag & drop files and folders to open in Pine ([#420](https://github.com/batonogov/pine/issues/420)) ([#523](https://github.com/batonogov/pine/issues/523)) ([441ee4f](https://github.com/batonogov/pine/commit/441ee4f44b0f04b14082b9e0fed2009f8f864dd2))
* progress indicators for long operations ([#470](https://github.com/batonogov/pine/issues/470)) ([#500](https://github.com/batonogov/pine/issues/500)) ([9355a8e](https://github.com/batonogov/pine/commit/9355a8e09487f04a2cfda9129c19f38a273afb33))
* remove project from recent list via context menu ([#301](https://github.com/batonogov/pine/issues/301)) ([#514](https://github.com/batonogov/pine/issues/514)) ([494601d](https://github.com/batonogov/pine/commit/494601d9b9d680b37750ef48d4beaad3ff646285))
* restore scroll position, cursor, and fold state per tab ([#468](https://github.com/batonogov/pine/issues/468)) ([#495](https://github.com/batonogov/pine/issues/495)) ([2ca4ee5](https://github.com/batonogov/pine/commit/2ca4ee51b15f5c5ef17d93923540956f05dd4715))
* search in recent projects list on Welcome screen ([#300](https://github.com/batonogov/pine/issues/300)) ([#513](https://github.com/batonogov/pine/issues/513)) ([93266e3](https://github.com/batonogov/pine/commit/93266e31f4b52dd6b8942d14cf390e247647ee55))
* undo support for file operations ([#469](https://github.com/batonogov/pine/issues/469)) ([#502](https://github.com/batonogov/pine/issues/502)) ([e9bb73a](https://github.com/batonogov/pine/commit/e9bb73adbfab13025e4a771f269db53283af3c69))
* unified logging with os_log / Logger ([#466](https://github.com/batonogov/pine/issues/466)) ([#492](https://github.com/batonogov/pine/issues/492)) ([5a9ff1d](https://github.com/batonogov/pine/commit/5a9ff1df2d5bc4e96805627822b1884f27fbd258))
* update Welcome screen tagline to "A code editor that belongs on your Mac." ([#520](https://github.com/batonogov/pine/issues/520)) ([9a043cf](https://github.com/batonogov/pine/commit/9a043cfd187422dce4874dbd816b4fb5a0baccaf)), closes [#519](https://github.com/batonogov/pine/issues/519)


### Bug Fixes

* add NSLock synchronization to SyntaxHighlighter ([#462](https://github.com/batonogov/pine/issues/462)) ([#489](https://github.com/batonogov/pine/issues/489)) ([b4aac12](https://github.com/batonogov/pine/commit/b4aac12a7ff8fee8bac960dc2834afe2d1038bac))
* auto-scroll sidebar to newly created file ([#528](https://github.com/batonogov/pine/issues/528)) ([#530](https://github.com/batonogov/pine/issues/530)) ([9b488d4](https://github.com/batonogov/pine/commit/9b488d433466a0a38ca5e807d26624b14523af97))
* eliminate layout jitter during project load, sidebar refresh, and tab switching ([#509](https://github.com/batonogov/pine/issues/509)) ([#517](https://github.com/batonogov/pine/issues/517)) ([3cea969](https://github.com/batonogov/pine/commit/3cea9697f8b2d95dde631fb3a87fa35aa2c283f4))
* eliminate syntax highlight flash on tab switch ([#529](https://github.com/batonogov/pine/issues/529)) ([#531](https://github.com/batonogov/pine/issues/531)) ([91d6062](https://github.com/batonogov/pine/commit/91d60623e93173c80bb16866d523b770640213b4))
* new files not appearing in sidebar until manual interaction ([#439](https://github.com/batonogov/pine/issues/439)) ([#493](https://github.com/batonogov/pine/issues/493)) ([b2e572d](https://github.com/batonogov/pine/commit/b2e572d2f3e208f2c1fa38e50ad055f2122e04cd))
* prevent .js and .ts files from being treated as binary ([#479](https://github.com/batonogov/pine/issues/479)) ([#490](https://github.com/batonogov/pine/issues/490)) ([10c8c2e](https://github.com/batonogov/pine/commit/10c8c2e9d3bd74817a814eb1bea872c33be5180a))
* prevent QuickOpenProvider from indexing files outside project root via symlinks ([#486](https://github.com/batonogov/pine/issues/486)) ([#491](https://github.com/batonogov/pine/issues/491)) ([fa68b74](https://github.com/batonogov/pine/commit/fa68b749c1b3495ffab830bedf4861510bbc3746))
* Quick Open index goes stale after file tree changes ([#477](https://github.com/batonogov/pine/issues/477)) ([#494](https://github.com/batonogov/pine/issues/494)) ([c7db89a](https://github.com/batonogov/pine/commit/c7db89ae03d52b06725f78848b441ecde15d40a7))
* replace class LoadContext with struct to prevent use-after-free ([#405](https://github.com/batonogov/pine/issues/405)) ([#504](https://github.com/batonogov/pine/issues/504)) ([c555705](https://github.com/batonogov/pine/commit/c5557056bd4614bfb2438512cbaf40386ebf8c44))
* replace silent try? with proper error logging ([#463](https://github.com/batonogov/pine/issues/463)) ([#496](https://github.com/batonogov/pine/issues/496)) ([ee07336](https://github.com/batonogov/pine/commit/ee0733697bd61ddb8655b73e1282e1d39c87784a))
* use static methods in FileOperationUndoManager to prevent use-after-free ([#525](https://github.com/batonogov/pine/issues/525)) ([#526](https://github.com/batonogov/pine/issues/526)) ([f84048c](https://github.com/batonogov/pine/commit/f84048c8edd8ff61ce582123e3401da5c8e92829))


### Performance Improvements

* replace serial syntax highlighting queue with concurrent OperationQueue ([#400](https://github.com/batonogov/pine/issues/400)) ([#521](https://github.com/batonogov/pine/issues/521)) ([0db386e](https://github.com/batonogov/pine/commit/0db386ec88ba771216729763903ba77acd0d4a30))


### Code Refactoring

* extract magic numbers into named constants ([#499](https://github.com/batonogov/pine/issues/499)) ([a02e1e7](https://github.com/batonogov/pine/commit/a02e1e763f519d24691a2a83669f931520f4a574)), closes [#464](https://github.com/batonogov/pine/issues/464)
* standardize animations and transitions across UI flows ([#506](https://github.com/batonogov/pine/issues/506)) ([#510](https://github.com/batonogov/pine/issues/510)) ([6a55877](https://github.com/batonogov/pine/commit/6a55877b9a4c54441328a22739d7ba4556ea93b6))

## [1.10.1](https://github.com/batonogov/pine/compare/v1.10.0...v1.10.1) (2026-03-24)


### Bug Fixes

* editor tab bar overflows without scroll or collapse when many tabs open ([#453](https://github.com/batonogov/pine/issues/453)) ([f846d58](https://github.com/batonogov/pine/commit/f846d58c6883ce59ef5ee5ff859b6fdf5205083b))
* prevent infinite loops in Finder-style copy URL generation ([#484](https://github.com/batonogov/pine/issues/484)) ([ab253a5](https://github.com/batonogov/pine/commit/ab253a5fb62f7a2b92dfac663ec27e2a072d5a68))
* repair PineTests target dependencies for clean builds ([#480](https://github.com/batonogov/pine/issues/480)) ([737dbaf](https://github.com/batonogov/pine/commit/737dbafe6c77f88c8a4b1bc99cfa78a35343d73f))
* replace force cast with safe cast and add defer for FileHandle ([#461](https://github.com/batonogov/pine/issues/461)) ([#485](https://github.com/batonogov/pine/issues/485)) ([80d9cd3](https://github.com/batonogov/pine/commit/80d9cd3e42fc7f58ca0e67ed0713971f8695ce6e))
* resolve Swift 6 concurrency warnings in GitStatusProvider and ProjectSearchProvider ([#481](https://github.com/batonogov/pine/issues/481)) ([fe9f678](https://github.com/batonogov/pine/commit/fe9f678ceb304acbd65fbedf711e4273bb419694))
* scope NotificationCenter observers to specific scroll views ([#487](https://github.com/batonogov/pine/issues/487)) ([a8245cb](https://github.com/batonogov/pine/commit/a8245cb2f16e3a21dbc78bf02a8e526cbfeb7460))
* show correct file content when switching editor tabs ([#455](https://github.com/batonogov/pine/issues/455)) ([#456](https://github.com/batonogov/pine/issues/456)) ([64cbd3c](https://github.com/batonogov/pine/commit/64cbd3cad91e65b77543dc2009629a63e36cf796))


### Performance Improvements

* optimize scrolling for 120Hz ProMotion displays ([#447](https://github.com/batonogov/pine/issues/447)) ([0ea7706](https://github.com/batonogov/pine/commit/0ea770632aaf8fcd132c001870639f8578c26914))

## [1.10.0](https://github.com/batonogov/pine/compare/v1.9.2...v1.10.0) (2026-03-23)


### Features

* add Go to Line dialog (Cmd+L) ([#432](https://github.com/batonogov/pine/issues/432)) ([cd87484](https://github.com/batonogov/pine/commit/cd87484fe226d1f5ff3b15c607513f9058c47052))
* Quick Open file search (Cmd+P) ([#433](https://github.com/batonogov/pine/issues/433)) ([2cd2bc9](https://github.com/batonogov/pine/commit/2cd2bc9fe153edb55eb184f8dfe80d7cbaa22c0f))
* strip trailing whitespace on save ([#427](https://github.com/batonogov/pine/issues/427)) ([3c6b3c2](https://github.com/batonogov/pine/commit/3c6b3c235156389ac5451eb4e82277aff05cb9a8))


### Bug Fixes

* re-highlight syntax after external file changes ([#451](https://github.com/batonogov/pine/issues/451)) ([5ab6c0b](https://github.com/batonogov/pine/commit/5ab6c0bfbdd4d45c6a6ab8b00ed4259f7010555d))
* reset cosmetic xcstrings changes after build ([#434](https://github.com/batonogov/pine/issues/434)) ([61c7bcb](https://github.com/batonogov/pine/commit/61c7bcbad9b2147a3a6050f37c8c2b9d244563b6))

## [1.9.2](https://github.com/batonogov/pine/compare/v1.9.1...v1.9.2) (2026-03-22)


### Bug Fixes

* align line number baseline with editor text baseline ([#395](https://github.com/batonogov/pine/issues/395)) ([99e7d58](https://github.com/batonogov/pine/commit/99e7d58da204a34f525627a810730bfe551c56d9))

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
