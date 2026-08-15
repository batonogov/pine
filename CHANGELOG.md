# Changelog

## [2.3.5](https://github.com/batonogov/pine/compare/v2.3.4...v2.3.5) (2026-08-15)


### Bug Fixes

* **release:** skip incomplete previous releases ([#1468](https://github.com/batonogov/pine/issues/1468)) ([2bfb191](https://github.com/batonogov/pine/commit/2bfb191d5b12f3c9986430c4d112754a5d3fb725))

## [2.3.4](https://github.com/batonogov/pine/compare/v2.3.3...v2.3.4) (2026-08-14)


### Bug Fixes

* **release:** publish the smoke feed port without reverse DNS ([#1466](https://github.com/batonogov/pine/issues/1466)) ([44add88](https://github.com/batonogov/pine/commit/44add886ac86372a9383807626dd82a52d2c2cf8))

## [2.3.3](https://github.com/batonogov/pine/compare/v2.3.2...v2.3.3) (2026-08-14)


### Bug Fixes

* restore sidebar and quit persistence ([#1464](https://github.com/batonogov/pine/issues/1464)) ([2e11d52](https://github.com/batonogov/pine/commit/2e11d5212ba1b9071a8ac920c16bdf022e41c636))

## [2.3.2](https://github.com/batonogov/pine/compare/v2.3.1...v2.3.2) (2026-08-13)


### Bug Fixes

* **ci:** canonicalize SourceKit-LSP toolchain paths ([#1454](https://github.com/batonogov/pine/issues/1454)) ([1a09ac8](https://github.com/batonogov/pine/commit/1a09ac89fbc65e3c365dabbd209e2783029b4409))
* make descriptor path recovery sanitizer-safe ([#1451](https://github.com/batonogov/pine/issues/1451)) ([a52b384](https://github.com/batonogov/pine/commit/a52b384cdb2412eb127c740d8ca156b37d76016e))
* suspend background project editor services ([#1447](https://github.com/batonogov/pine/issues/1447)) ([1279ef8](https://github.com/batonogov/pine/commit/1279ef89c576b8a868169955691aa922bd6ebc5d))
* **terminal:** wire Quick Terminal agents into detection and Agent Inbox ([#1449](https://github.com/batonogov/pine/issues/1449)) ([ef54da3](https://github.com/batonogov/pine/commit/ef54da397f2219ee0d632c15876c8492b7ba0fcd))


### Documentation

* codify issue swarm review flow ([#1445](https://github.com/batonogov/pine/issues/1445)) ([f234c3a](https://github.com/batonogov/pine/commit/f234c3a391b1f067dda7530c849471ec327bc4d4))

## [2.3.1](https://github.com/batonogov/pine/compare/v2.3.0...v2.3.1) (2026-08-12)


### Bug Fixes

* disambiguate concurrent agent inbox sessions ([#1434](https://github.com/batonogov/pine/issues/1434)) ([e968e4c](https://github.com/batonogov/pine/commit/e968e4c7cb2ff138ee7f1da08754a52c4a1b1f11))
* keep CPU-flat agent waits non-actionable ([#1428](https://github.com/batonogov/pine/issues/1428)) ([69b8564](https://github.com/batonogov/pine/commit/69b8564557b731e815a51af53bf196c6b574e2dd))
* keep terminal destination routing current ([#1431](https://github.com/batonogov/pine/issues/1431)) ([ab3103f](https://github.com/batonogov/pine/commit/ab3103f4fb1bee4a10494822991213087a8366c5))
* preserve agent generation during start uncertainty ([#1430](https://github.com/batonogov/pine/issues/1430)) ([055a97e](https://github.com/batonogov/pine/commit/055a97e022e3b8d18fe83659724bebd686e0d415))
* reopen background projects before inbox recovery ([#1426](https://github.com/batonogov/pine/issues/1426)) ([66a7992](https://github.com/batonogov/pine/commit/66a79921d0e304cc31fdbbedafbe8af49ee9e9dc))
* restore configured cursor after terminal reset ([#1435](https://github.com/batonogov/pine/issues/1435)) ([87dccb8](https://github.com/batonogov/pine/commit/87dccb8f09f76a4730e6eafae6e8eade63fee56c))
* retain agent ownership through foreground children ([#1427](https://github.com/batonogov/pine/issues/1427)) ([f15faf6](https://github.com/batonogov/pine/commit/f15faf6b0c77094fb7f10873389a40274e655315))
* scope agent activity to project terminals ([#1433](https://github.com/batonogov/pine/issues/1433)) ([7b1dd53](https://github.com/batonogov/pine/commit/7b1dd535d3f2dc048c3a7872ffbd5f12a4b2db07))

## [2.3.0](https://github.com/batonogov/pine/compare/v2.2.2...v2.3.0) (2026-08-11)


### Features

* add terminal cursor settings ([#1413](https://github.com/batonogov/pine/issues/1413)) ([4961648](https://github.com/batonogov/pine/commit/496164877fb2f66c646ad2823a3a4dd6174470a8))


### Bug Fixes

* **sidebar:** prevent flicker during deep tree refresh ([#1415](https://github.com/batonogov/pine/issues/1415)) ([70d0d6b](https://github.com/batonogov/pine/commit/70d0d6bc5d3178890f8517411c2be304e6491faa))

## [2.2.2](https://github.com/batonogov/pine/compare/v2.2.1...v2.2.2) (2026-08-10)


### Bug Fixes

* keep terminal work alive on window close ([#1412](https://github.com/batonogov/pine/issues/1412)) ([057b328](https://github.com/batonogov/pine/commit/057b328c2c9b07ed06385d53260efa56569f57ae))
* recover Open Folder ownership with active agents ([#1410](https://github.com/batonogov/pine/issues/1410)) ([60b9b83](https://github.com/batonogov/pine/commit/60b9b8385b6806160b12552a2d661e824a14a49f))

## [2.2.1](https://github.com/batonogov/pine/compare/v2.2.0...v2.2.1) (2026-08-10)


### Bug Fixes

* **agent:** preserve notification transitions ([#1394](https://github.com/batonogov/pine/issues/1394)) ([1e4fc1c](https://github.com/batonogov/pine/commit/1e4fc1c572483122cfd3ba1627a7200198ff19de))
* bound quit failure alert recovery ([#1395](https://github.com/batonogov/pine/issues/1395)) ([33cbd72](https://github.com/batonogov/pine/commit/33cbd726ee0a3610b16114665d646443a9d0d6f9))
* **editor:** fence saves against external changes ([#1397](https://github.com/batonogov/pine/issues/1397)) ([2b3b691](https://github.com/batonogov/pine/commit/2b3b6916b1663d7ef0aa2b7a4de96549cfee9de9))
* **editor:** show gutter markers for unsaved changes ([#1403](https://github.com/batonogov/pine/issues/1403)) ([3003269](https://github.com/batonogov/pine/commit/3003269003e01dd86a5fe25449a2429c5399ffac))
* **lsp:** clarify filtered Problems state ([#1393](https://github.com/batonogov/pine/issues/1393)) ([6533300](https://github.com/batonogov/pine/commit/653330055991595e7aa0047576e13f05a7fc00c6))
* **search:** enforce result boundaries ([#1392](https://github.com/batonogov/pine/issues/1392)) ([b4ff874](https://github.com/batonogov/pine/commit/b4ff874e844091dda014faecde4afd549add2bad))
* **sidebar:** retry row focus after layout ([#1405](https://github.com/batonogov/pine/issues/1405)) ([f246abd](https://github.com/batonogov/pine/commit/f246abdd1ec38e7253408c42d763c753d53a76b7))
* **terminal:** draw Metal recovery frames immediately ([#1401](https://github.com/batonogov/pine/issues/1401)) ([606caf4](https://github.com/batonogov/pine/commit/606caf4ecee790e6f0d9466d1bfb3ca8fb19b904))


### Performance Improvements

* **editor:** move format-on-save off main actor ([#1398](https://github.com/batonogov/pine/issues/1398)) ([1f6ba70](https://github.com/batonogov/pine/commit/1f6ba70157bc990d5caf99539d357ded28f81e17))

## [2.2.0](https://github.com/batonogov/pine/compare/v2.1.1...v2.2.0) (2026-08-10)


### Features

* **help:** add contextual recovery routes ([#1383](https://github.com/batonogov/pine/issues/1383)) ([554c27b](https://github.com/batonogov/pine/commit/554c27bb4aa3de9e3087d0f9ade5c46b0e8dd83e))


### Bug Fixes

* **agent:** close Pine 2.0 workflow regressions ([#1368](https://github.com/batonogov/pine/issues/1368)) ([9a5e035](https://github.com/batonogov/pine/commit/9a5e03501fa52ef91b530971fd61b411140cd67e))
* **agent:** polish native Pine 2.0 UX ([#1373](https://github.com/batonogov/pine/issues/1373)) ([8c37907](https://github.com/batonogov/pine/commit/8c37907b8958dc7ead25fb26cea59ecc3d2c65fe))
* **help:** add native task-based search and contextual help ([#1381](https://github.com/batonogov/pine/issues/1381)) ([da92717](https://github.com/batonogov/pine/commit/da927177a55930e9175edbd59f0cbc5b65c72f49))
* **marketing:** hide terminal screenshot fixture ([#1378](https://github.com/batonogov/pine/issues/1378)) ([8e63a90](https://github.com/batonogov/pine/commit/8e63a90eee8896ca5ff67ebb06eaa57b1f8c4c61))
* **marketing:** stabilize terminal screenshot prompt ([#1376](https://github.com/batonogov/pine/issues/1376)) ([77a5c9a](https://github.com/batonogov/pine/commit/77a5c9aa1212e7e062032cc17272ce2c1874cc84))

## [2.1.1](https://github.com/batonogov/pine/compare/v2.1.0...v2.1.1) (2026-08-09)


### Bug Fixes

* **agent:** surface background agent work via Dock badge, guard, and foreground banners ([#1360](https://github.com/batonogov/pine/issues/1360)) ([463355d](https://github.com/batonogov/pine/commit/463355df5e154b0b3ad8cc1bf2fa49c5e0c7b002))
* aggregate quit confirmation across projects ([#1363](https://github.com/batonogov/pine/issues/1363)) ([1729579](https://github.com/batonogov/pine/commit/172957955a9aa6db8bfbd033852f0b3e1db57550))
* make application quit bounded, atomic, and user-visible ([#1364](https://github.com/batonogov/pine/issues/1364)) ([15c1296](https://github.com/batonogov/pine/commit/15c12969fdc71c2865b1ac6dc03c68428bfa5cc4))

## [2.1.0](https://github.com/batonogov/pine/compare/v2.0.1...v2.1.0) (2026-08-07)


### Features

* **agent:** add Agent Inbox toolbar button with attention badge ([#1337](https://github.com/batonogov/pine/issues/1337)) ([#1353](https://github.com/batonogov/pine/issues/1353)) ([4320b16](https://github.com/batonogov/pine/commit/4320b1699b96068cae508b585a56c9129de0fc8a))
* **terminal:** add "Digital Rain" phosphor-green theme ([#1351](https://github.com/batonogov/pine/issues/1351)) ([fc42dd1](https://github.com/batonogov/pine/commit/fc42dd177fca1771bd0e87d2880e0526dd4d2c3c))


### Bug Fixes

* **terminal:** authorize bulk close and quit by stable agent identity ([#1356](https://github.com/batonogov/pine/issues/1356)) ([dbc4058](https://github.com/batonogov/pine/commit/dbc4058d47fadc4fd8ad1390e81e0b566ba991b6))

## [2.0.1](https://github.com/batonogov/pine/compare/v2.0.0...v2.0.1) (2026-08-05)


### Bug Fixes

* **agent:** add CPU-time hysteresis to stop waiting-input flip-flop ([#1341](https://github.com/batonogov/pine/issues/1341)) ([d177c94](https://github.com/batonogov/pine/commit/d177c949ac039827749efd483a8b53adfda23806))
* **agent:** Agent Inbox window polish — focus ring, duplicate title, RU label ([#1340](https://github.com/batonogov/pine/issues/1340)) ([e5e02b2](https://github.com/batonogov/pine/commit/e5e02b26bbe49c4892859ec0c34d3311252461d5))
* **agent:** stabilize Agent Inbox row order against polling-driven timestamps ([#1342](https://github.com/batonogov/pine/issues/1342)) ([675a7ac](https://github.com/batonogov/pine/commit/675a7acc87e81a2d267e9a5c984a41782b978f72)), closes [#1336](https://github.com/batonogov/pine/issues/1336)
* **editor:** wait for dialog owner before Open Folder panel ([#1344](https://github.com/batonogov/pine/issues/1344)) ([#1345](https://github.com/batonogov/pine/issues/1345)) ([7cec7aa](https://github.com/batonogov/pine/commit/7cec7aa24c79f2fefae9993eaf070848a3904f0f))
* **terminal:** close-tab confirmation robustness for agent tabs ([#1343](https://github.com/batonogov/pine/issues/1343)) ([9ec88a2](https://github.com/batonogov/pine/commit/9ec88a22ea3ba63dce725493a67c4d1be3a81217))


### Documentation

* establish agent-terminal tagline ([#1333](https://github.com/batonogov/pine/issues/1333)) ([a17df51](https://github.com/batonogov/pine/commit/a17df51d7b131d2fb94f07cf2febe1ec858c56e6))
* showcase Pine 2.0 release ([#1332](https://github.com/batonogov/pine/issues/1332)) ([9dc672c](https://github.com/batonogov/pine/commit/9dc672cba6b509937478249c496ecced8d7d3769))

## [2.0.0](https://github.com/batonogov/pine/compare/v1.38.1...v2.0.0) (2026-08-04)


### Features

* add polished branded DMG installer ([#1300](https://github.com/batonogov/pine/issues/1300)) ([d2b01a8](https://github.com/batonogov/pine/commit/d2b01a8e5efc1c44897eab6bc225f3f930b067c6))
* **agent:** add actionable task notifications ([#1322](https://github.com/batonogov/pine/issues/1322)) ([f3c9c14](https://github.com/batonogov/pine/commit/f3c9c147ef1f24c04de35d11899ba5825ec1d792))
* **agent:** add cross-project Agent Inbox ([#1324](https://github.com/batonogov/pine/issues/1324)) ([a3669ee](https://github.com/batonogov/pine/commit/a3669ee7af0a355c13a02f0acd9ea4fd8e28979c))
* **agent:** add durable cross-project agent tasks ([#1302](https://github.com/batonogov/pine/issues/1302)) ([#1313](https://github.com/batonogov/pine/issues/1313)) ([dc272b0](https://github.com/batonogov/pine/commit/dc272b031a7fa1aa8587844aadfe24ad67bac6e7))
* **agent:** add evidence-based completion briefs ([#1325](https://github.com/batonogov/pine/issues/1325)) ([3cac544](https://github.com/batonogov/pine/commit/3cac54427055988d377028d9bb341ea070faa9ec))
* **agent:** add first-party compatibility matrix ([#1321](https://github.com/batonogov/pine/issues/1321)) ([9e73901](https://github.com/batonogov/pine/commit/9e739010da4843dc558d077e9f5a0a974f847dbb))
* **agent:** add five first-party detection adapters ([#1328](https://github.com/batonogov/pine/issues/1328)) ([9085385](https://github.com/batonogov/pine/commit/9085385121ba6fe6a56ebd2ee88a37469ed62fcd))
* **agent:** add isolated worktree workflows ([#1326](https://github.com/batonogov/pine/issues/1326)) ([3702e58](https://github.com/batonogov/pine/commit/3702e58c6c351664a67df3a781d98b632addad84))
* **agent:** add safe agent task recovery ([#1323](https://github.com/batonogov/pine/issues/1323)) ([e649f46](https://github.com/batonogov/pine/commit/e649f46e7dec3bba447f6d7de9f46f23ffb6d207))
* **agent:** add vendor-neutral adapter core ([#1303](https://github.com/batonogov/pine/issues/1303)) ([#1314](https://github.com/batonogov/pine/issues/1314)) ([a9a0180](https://github.com/batonogov/pine/commit/a9a0180051244918cd964e5b4fee1f885ebf4ae9))
* refresh app icon for Pine 2.0 ([#1315](https://github.com/batonogov/pine/issues/1315)) ([3b299c5](https://github.com/batonogov/pine/commit/3b299c5ab2b9848fa3ca57b43656f60c510470af))


### Miscellaneous

* prepare Pine 2.0 release candidate ([#1329](https://github.com/batonogov/pine/issues/1329)) ([13e7091](https://github.com/batonogov/pine/commit/13e709130ca846905c14af1f1409b348b45c7f00))

## [1.38.1](https://github.com/batonogov/pine/compare/v1.38.0...v1.38.1) (2026-07-31)


### Bug Fixes

* consolidate editor preferences in settings ([#1295](https://github.com/batonogov/pine/issues/1295)) ([cd9aef0](https://github.com/batonogov/pine/commit/cd9aef04908fd5e7c804e4416382789846c960f4))
* show native keybinding glyphs in settings ([#1297](https://github.com/batonogov/pine/issues/1297)) ([eec4391](https://github.com/batonogov/pine/commit/eec43916a2367281d988120be3551fcb82748208))
* show state in view menu ([#1298](https://github.com/batonogov/pine/issues/1298)) ([1057386](https://github.com/batonogov/pine/commit/1057386c12dd67e8e2dd3e56ff8e0a682a4de64f))
* use native ellipsis in app menu ([#1296](https://github.com/batonogov/pine/issues/1296)) ([0ec1145](https://github.com/batonogov/pine/commit/0ec1145f9a4750ba0f01799d7425d6fcbd17f1f2))

## [1.38.0](https://github.com/batonogov/pine/compare/v1.37.1...v1.38.0) (2026-07-31)


### Features

* **agent:** complete keyboard, detail, and localization flows ([#1264](https://github.com/batonogov/pine/issues/1264)) ([4ca043c](https://github.com/batonogov/pine/commit/4ca043c840170910de09964a4ebac0f56487ca71))
* **macos:** restore native File and Window menu semantics ([#1262](https://github.com/batonogov/pine/issues/1262)) ([f5bdf3f](https://github.com/batonogov/pine/commit/f5bdf3fd9d1fb632aea9e458dfca80d861d57f68))
* **nav:** replace document-modal sheets with command overlays ([#1258](https://github.com/batonogov/pine/issues/1258)) ([764ba95](https://github.com/batonogov/pine/commit/764ba95a7ad9c8aaa5f07f81a30dd950bf3c1d18))
* **settings:** adopt immediate-apply LSP configuration ([#1255](https://github.com/batonogov/pine/issues/1255)) ([c3b381c](https://github.com/batonogov/pine/commit/c3b381cc185c11ea3ffb40d0a5cb326007d6534a))
* **settings:** consolidate existing global preferences ([#1267](https://github.com/batonogov/pine/issues/1267)) ([1ba3d80](https://github.com/batonogov/pine/commit/1ba3d8084f9fe58b31b34b525eb22255e79d687e))
* **sidebar:** add Finder-style keyboard and VoiceOver navigation ([#1257](https://github.com/batonogov/pine/issues/1257)) ([9cc8106](https://github.com/batonogov/pine/commit/9cc8106dc3b1df4d7daa9ccd59b81180ec115763))
* **tabs:** add visual global MRU switcher ([#1261](https://github.com/batonogov/pine/issues/1261)) ([cb6ec14](https://github.com/batonogov/pine/commit/cb6ec14efaa07591f398483a6bc007c1ee9c178d))
* **tasks:** surface execution progress, output, and failures ([#1269](https://github.com/batonogov/pine/issues/1269)) ([9e5ef94](https://github.com/batonogov/pine/commit/9e5ef9498836022749861bfade6349d49258a42a))
* **terminal:** add selectable terminal themes with light/dark pairs ([#1259](https://github.com/batonogov/pine/issues/1259)) ([3eb8623](https://github.com/batonogov/pine/commit/3eb8623a24bf20ef8013b5769c94c2bb7dc352b2))
* **terminal:** complete Quick Terminal settings and project context ([#1265](https://github.com/batonogov/pine/issues/1265)) ([0a7c00c](https://github.com/batonogov/pine/commit/0a7c00ca9ebd3c1f71cc9e1725f531cba259291f))
* **updates:** embed the Sparkle update flow in Pine ([#1268](https://github.com/batonogov/pine/issues/1268)) ([750c9ff](https://github.com/batonogov/pine/commit/750c9ffaceaa55c278a67c46b8e3b5c5e37d027c))
* **workspace:** start new projects in a focused terminal ([#1256](https://github.com/batonogov/pine/issues/1256)) ([251c739](https://github.com/batonogov/pine/commit/251c739678e5f0346c7d1ec093060c8167d8ced5))


### Bug Fixes

* **agent-history:** make verified undo reachable and close preview TOCTOU ([#1279](https://github.com/batonogov/pine/issues/1279)) ([2710275](https://github.com/batonogov/pine/commit/271027524e8010d165998a942f4a85046569f600))
* **agent:** integrate verified undo review into Agent History ([#1263](https://github.com/batonogov/pine/issues/1263)) ([329f412](https://github.com/batonogov/pine/commit/329f412acdfb26e07b299473109c5e2f4303c557))
* **git:** harden command process lifecycle ([#1280](https://github.com/batonogov/pine/issues/1280)) ([19d891f](https://github.com/batonogov/pine/commit/19d891f6263929bae7ff04aad1c9e92545a7d036))
* **i18n:** complete localization catalog coverage ([#1285](https://github.com/batonogov/pine/issues/1285)) ([f4f71d8](https://github.com/batonogov/pine/commit/f4f71d8c5fcaa7eba0cd27942b91a562d1e79fb8))
* localize consolidated settings ([#1287](https://github.com/batonogov/pine/issues/1287)) ([37b481b](https://github.com/batonogov/pine/commit/37b481b9072cc5eb0056c9a8e06c5dfa6e445ce6))
* **lsp:** wire Problems panel into editor chrome ([#1260](https://github.com/batonogov/pine/issues/1260)) ([f93dc3d](https://github.com/batonogov/pine/commit/f93dc3dabf80c45436dbf7d2c6a05626a097e990))
* **macos:** finish native File and Window menu semantics ([#1283](https://github.com/batonogov/pine/issues/1283)) ([6ea758f](https://github.com/batonogov/pine/commit/6ea758f1ccddeef790bb08163bad8c31d112be18))
* **macos:** restore Open Folder menu routing ([#1289](https://github.com/batonogov/pine/issues/1289)) ([827de7c](https://github.com/batonogov/pine/commit/827de7c17adbb378b97c4bfb8e04f002e1e7c5dd))
* **settings:** restore terminal and Quick Terminal controls ([#1278](https://github.com/batonogov/pine/issues/1278)) ([0e077ae](https://github.com/batonogov/pine/commit/0e077ae4c04171dbca61e47b0e997b52ac349165))
* **sidebar:** preserve position during keyboard navigation ([#1293](https://github.com/batonogov/pine/issues/1293)) ([866ccdf](https://github.com/batonogov/pine/commit/866ccdf12b0f8e2c7db1015f833f880485ba4fb6))
* **tabs:** wire and harden the visual global MRU switcher ([#1282](https://github.com/batonogov/pine/issues/1282)) ([eb012ca](https://github.com/batonogov/pine/commit/eb012ca9b8e66c47365d4e33f16cdc7d670e75d1))
* **updates:** keep a single standard Sparkle runtime ([#1281](https://github.com/batonogov/pine/issues/1281)) ([b9da0ac](https://github.com/batonogov/pine/commit/b9da0ace7295a829d6d593d8c6dc5688e5ff153a))
* **ux:** make toast notifications nonblocking and accessible ([#1254](https://github.com/batonogov/pine/issues/1254)) ([211a5ae](https://github.com/batonogov/pine/commit/211a5aef2b3ea889aabe38f38c92ae5e40aa954c))


### Code Refactoring

* **macos:** scope document dialogs to their project window ([#1266](https://github.com/batonogov/pine/issues/1266)) ([4e6a45d](https://github.com/batonogov/pine/commit/4e6a45df59fab8c508ae81ffa1e52cce6d418d7d))


### Documentation

* **help:** expand Pine Help Book into task-based documentation ([#1253](https://github.com/batonogov/pine/issues/1253)) ([0bdfd40](https://github.com/batonogov/pine/commit/0bdfd4005121629206f4bc8930b79070d0ae0f0b))
* **install:** use one-command Homebrew cask installation ([#1252](https://github.com/batonogov/pine/issues/1252)) ([42b5dcc](https://github.com/batonogov/pine/commit/42b5dcca778b7d1b8189cd4d0c45183ca73d0c42))
* record native sidebar navigation flow ([#1294](https://github.com/batonogov/pine/issues/1294)) ([9c2c622](https://github.com/batonogov/pine/commit/9c2c6222c22ab975e14d1ca6396b37b5ba0242c8))

## [1.37.1](https://github.com/batonogov/pine/compare/v1.37.0...v1.37.1) (2026-07-27)


### Bug Fixes

* synchronize YAML fold rendering ([#1234](https://github.com/batonogov/pine/issues/1234)) ([3c021c3](https://github.com/batonogov/pine/commit/3c021c31399d8388b73d1925eba65cb486033ee7))


### Documentation

* require issues before implementation ([#1233](https://github.com/batonogov/pine/issues/1233)) ([e1770a7](https://github.com/batonogov/pine/commit/e1770a745bb59cce03641aafef8f7ed0d914b5ee))

## [1.37.0](https://github.com/batonogov/pine/compare/v1.36.0...v1.37.0) (2026-07-27)


### Features

* add YAML indentation folding ([#1226](https://github.com/batonogov/pine/issues/1226)) ([582bcb9](https://github.com/batonogov/pine/commit/582bcb94572ec1cbba3d6db32ec24ca0bc4504e6))


### Bug Fixes

* restore native sidebar keyboard focus ([#1228](https://github.com/batonogov/pine/issues/1228)) ([25f1187](https://github.com/batonogov/pine/commit/25f1187e7e0ad6fa13b52596e9e29b35358dce1e))
* **terminal:** prevent black panes after terminal reparent ([#1230](https://github.com/batonogov/pine/issues/1230)) ([24b424b](https://github.com/batonogov/pine/commit/24b424bbd0cacad90079e70dc699655e9740b909))

## [1.36.0](https://github.com/batonogov/pine/compare/v1.35.0...v1.36.0) (2026-07-26)


### Features

* **agent:** add opt-in read-only context handoff ([34b195d](https://github.com/batonogov/pine/commit/34b195dc564f00e0e47d991b0d434ca66cdf92d1))
* **agent:** add opt-in read-only context handoff ([30953ed](https://github.com/batonogov/pine/commit/30953edd848e1854bd7ad42c01bbc16860d3da8f))
* **agent:** add secure provenance event store ([3e05bda](https://github.com/batonogov/pine/commit/3e05bda4a601780720d11fac68064ed2919bb2e0))
* **agent:** add secure provenance event store ([585d016](https://github.com/batonogov/pine/commit/585d016d517093310a9a2331dc327ce0ae6ba5af))
* **agent:** add trusted event provenance envelope ([#1204](https://github.com/batonogov/pine/issues/1204)) ([f714704](https://github.com/batonogov/pine/commit/f714704b20bbd5ca96b62d2613b2d189f1893cc5))
* **agent:** add verified patch core ([32e58d8](https://github.com/batonogov/pine/commit/32e58d8f9da15a7c8bebe3d7e1af9ad45ec59b36))
* **agent:** add verified patch engine ([ef2817b](https://github.com/batonogov/pine/commit/ef2817b5bac72406b707943817baa5e97f9c1ac1))
* **agent:** filter Activity Panel by attribution evidence ([#933](https://github.com/batonogov/pine/issues/933)) ([#1220](https://github.com/batonogov/pine/issues/1220)) ([96169a8](https://github.com/batonogov/pine/commit/96169a889c869838fcd1d3edf886fa7dabc16d4f))
* **agent:** session staleness tracking ([#933](https://github.com/batonogov/pine/issues/933)) ([#1218](https://github.com/batonogov/pine/issues/1218)) ([eec518f](https://github.com/batonogov/pine/commit/eec518fd347b50df4c091a72485810f219884a3b))
* **agent:** verified diff preview UI for Agent History ([#933](https://github.com/batonogov/pine/issues/933)) ([#1219](https://github.com/batonogov/pine/issues/1219)) ([d6e2cc1](https://github.com/batonogov/pine/commit/d6e2cc1f696028222bc01ef9ab20fbc436fd0ef6))
* **editor:** complete structural intelligence providers ([39519e0](https://github.com/batonogov/pine/commit/39519e0c69ac1c510c2813b6b689c2e1dc27e7d4))
* **editor:** LSP-first structural folding ([8d3a618](https://github.com/batonogov/pine/commit/8d3a618e59f96317859fc8ca7ad0c18bff8fb57d))
* **editor:** LSP-first structural folding ([2e8ad65](https://github.com/batonogov/pine/commit/2e8ad65233d484aba146254a84cd8f479b23b960)), closes [#1008](https://github.com/batonogov/pine/issues/1008)
* **extensibility:** add command palette foundation ([34ebb93](https://github.com/batonogov/pine/commit/34ebb931677df2a5fbe12ae94b655abd9a92e329))
* **extensibility:** complete command palette and registry ([a954b6d](https://github.com/batonogov/pine/commit/a954b6d6bdcfeafc422682e9881f86e27df6aca9))
* **extensibility:** complete command palette and registry ([#1117](https://github.com/batonogov/pine/issues/1117)) ([b21d5ed](https://github.com/batonogov/pine/commit/b21d5edd724534f5d42c0cb0fc5a50b7df814529))
* **extensibility:** keybinding override suppression, config reload, and error UI ([#1117](https://github.com/batonogov/pine/issues/1117) slice) ([#1203](https://github.com/batonogov/pine/issues/1203)) ([99c4236](https://github.com/batonogov/pine/commit/99c4236dcc1eed1eb005ee807637562133589d26))
* **tabs:** complete unified interaction restoration ([#1210](https://github.com/batonogov/pine/issues/1210)) ([cea2560](https://github.com/batonogov/pine/commit/cea2560e72b303e5431f9e0a0f70cce148421df0))
* **tabs:** transient preview tabs and MRU switcher ([#1202](https://github.com/batonogov/pine/issues/1202)) ([406ad62](https://github.com/batonogov/pine/commit/406ad623929f0e11d429e2454c8c4c188b755f20))


### Bug Fixes

* **agent:** bound verified patch planning ([31160dc](https://github.com/batonogov/pine/commit/31160dcdf9cc91784ca5c8d7ba21f9697d3f4a2a))
* **agent:** cap patch revalidation work ([6b51f09](https://github.com/batonogov/pine/commit/6b51f0933b87881a21efe8437447f919a5dde896))
* **agent:** checked undo engine for verified Agent History entries ([#1183](https://github.com/batonogov/pine/issues/1183)) ([5cc6d75](https://github.com/batonogov/pine/commit/5cc6d759b6bbc10328d8e81267227a6a882cf04e))
* **agent:** harden patch mapping and version chains ([eeb4365](https://github.com/batonogov/pine/commit/eeb43659ca479242210955adc9e82bd8ff8d6754))
* **agent:** harden session liveness polling ([#1224](https://github.com/batonogov/pine/issues/1224)) ([684bb86](https://github.com/batonogov/pine/commit/684bb869a17bddbfb3371f0db635fc4f2c4b41a2))
* **agent:** harden verified checked undo ([#1183](https://github.com/batonogov/pine/issues/1183)) ([241ef53](https://github.com/batonogov/pine/commit/241ef53dd6e88dca9aad0becdc941dd63f545d7d))
* **agent:** harden verified patch boundaries ([e858c7d](https://github.com/batonogov/pine/commit/e858c7defdc0f489f99f2833637e72b494b02c80))
* **agent:** harden verified patch preparation ([a88fb76](https://github.com/batonogov/pine/commit/a88fb76cdb9ce2141c096753d99f63159101ec2c))
* **agent:** keep ambiguous activity unattributed ([#1208](https://github.com/batonogov/pine/issues/1208)) ([3ba521e](https://github.com/batonogov/pine/commit/3ba521e89be7b9dea0f0e9a3756a7d50c6e70ac5))
* **agent:** make prepared undo previews byte- and mode-truthful ([#1223](https://github.com/batonogov/pine/issues/1223)) ([e95796a](https://github.com/batonogov/pine/commit/e95796a4f1fff6bd4babc3a3f102a541b87acaec))
* **concurrency:** clear residual Xcode warnings ([#1212](https://github.com/batonogov/pine/issues/1212)) ([8714697](https://github.com/batonogov/pine/commit/87146977c9f9a10bf726b0e25b0bcc2fdb9014e9))
* **editor:** complete structural folding fallbacks ([184601c](https://github.com/batonogov/pine/commit/184601c9b403f3c8a666524735a5eb9bf4074988))
* **editor:** make LSP folding revision-safe ([66c8285](https://github.com/batonogov/pine/commit/66c8285a7374006d95ecc82a4dbef2db4e800a27))
* **isolation:** align structural providers with MainActor default ([4caa81c](https://github.com/batonogov/pine/commit/4caa81ced9f7d949d3b23448eb8ded33bba71466))
* **localization:** make symbol labels locale-deterministic ([bc1983c](https://github.com/batonogov/pine/commit/bc1983c3dc81366e76e55b892fb889678a530a55))

## [1.35.0](https://github.com/batonogov/pine/compare/v1.34.0...v1.35.0) (2026-07-24)


### Features

* add exact tab insertion targets ([#1186](https://github.com/batonogov/pine/issues/1186)) ([2806efc](https://github.com/batonogov/pine/commit/2806efc8136093be9d3e6ad79ef981c996663700))
* **lsp:** add language server settings ([#1198](https://github.com/batonogov/pine/issues/1198)) ([d3e4920](https://github.com/batonogov/pine/commit/d3e49200db61c82c37d9b36dbcd65f7fff426238))
* **tabs:** stabilize drag geometry and auto-scroll ([#1199](https://github.com/batonogov/pine/issues/1199)) ([acb6720](https://github.com/batonogov/pine/commit/acb67209acfbe161a608c5375e14043a55116cdc))


### Bug Fixes

* avoid synchronous main hops in syntax highlighting ([#1184](https://github.com/batonogov/pine/issues/1184)) ([577ec84](https://github.com/batonogov/pine/commit/577ec84d314cb99a20c65c04fc7eeef59e07e061))
* disable unsafe heuristic agent history undo ([#1187](https://github.com/batonogov/pine/issues/1187)) ([5cc0334](https://github.com/batonogov/pine/commit/5cc03348a6da92bafcfd87daf2fa363093324cb0))
* **extensibility:** validate configuration reloads atomically ([#1192](https://github.com/batonogov/pine/issues/1192)) ([a23b644](https://github.com/batonogov/pine/commit/a23b6440eb69535f311071db5b20092e0cb3e5b2))
* **lsp:** harden streaming transport framing ([#1188](https://github.com/batonogov/pine/issues/1188)) ([349e071](https://github.com/batonogov/pine/commit/349e071baebd6988a983a9fc0c98a2174f06aa93))
* **tabs:** bound destination focus retries ([#1190](https://github.com/batonogov/pine/issues/1190)) ([56e1a19](https://github.com/batonogov/pine/commit/56e1a19222f2cf041d2f1d4d599e5c465576ba83))


### Code Refactoring

* **agent:** define verified undo authority contract ([#1194](https://github.com/batonogov/pine/issues/1194)) ([7f35e69](https://github.com/batonogov/pine/commit/7f35e69d19be221614c2ee003e0b9b1138625358))


### Documentation

* choose structural intelligence providers ([#1193](https://github.com/batonogov/pine/issues/1193)) ([f6bb2f2](https://github.com/batonogov/pine/commit/f6bb2f2e28559f71566186e9f5badd53ac7138c2))
* refresh landing page positioning ([#1175](https://github.com/batonogov/pine/issues/1175)) ([2510af9](https://github.com/batonogov/pine/commit/2510af905ee5aebfb95d9d61449690b6128cb87a))

## [1.34.0](https://github.com/batonogov/pine/compare/v1.33.4...v1.34.0) (2026-07-22)


### Features

* add native Pine help book ([#1173](https://github.com/batonogov/pine/issues/1173)) ([fbb0d3a](https://github.com/batonogov/pine/commit/fbb0d3a6b05a61cdd288f6611baabe6e3416b361))


### Bug Fixes

* **editor:** unify the editor canvas background ([#1166](https://github.com/batonogov/pine/issues/1166)) ([c61d3ef](https://github.com/batonogov/pine/commit/c61d3ef5c476d14af499b9d6872ae7309a1f6f09))
* preserve tab state across pane interactions ([#1170](https://github.com/batonogov/pine/issues/1170)) ([5e4a936](https://github.com/batonogov/pine/commit/5e4a936af64c119660edebaf6d8a024cc6e85668))

## [1.33.4](https://github.com/batonogov/pine/compare/v1.33.3...v1.33.4) (2026-07-22)


### Bug Fixes

* make tab dragging reliable ([#1162](https://github.com/batonogov/pine/issues/1162)) ([517eef1](https://github.com/batonogov/pine/commit/517eef11d0e453c0d85533801ab3775233ed8325))

## [1.33.3](https://github.com/batonogov/pine/compare/v1.33.2...v1.33.3) (2026-07-21)


### Bug Fixes

* **editor:** compile notification observers with Xcode 27 ([d900b6a](https://github.com/batonogov/pine/commit/d900b6a5753e3ad501a692c80338de47bd0cd256))
* **editor:** restore Python declaration highlighting ([#1144](https://github.com/batonogov/pine/issues/1144)) ([3d3d615](https://github.com/batonogov/pine/commit/3d3d615a9225c64e91f298c676b6cd6964433c4c))
* **lsp:** parse bare code action commands ([#1142](https://github.com/batonogov/pine/issues/1142)) ([8839537](https://github.com/batonogov/pine/commit/883953735ea5bc5c7a608e763e7f513a724fde5a))
* **lsp:** reject invalid workspace edit ranges ([#1154](https://github.com/batonogov/pine/issues/1154)) ([a119185](https://github.com/batonogov/pine/commit/a11918544d48145a773d47df42f6373346d606bc))
* **tasks:** close dangerous command validator bypasses ([#1155](https://github.com/batonogov/pine/issues/1155)) ([b9d8fdd](https://github.com/batonogov/pine/commit/b9d8fdd2084ff31334d8c93cb6d334a4f96be154))
* **terminal:** improve light ANSI palette contrast ([#1153](https://github.com/batonogov/pine/issues/1153)) ([322f598](https://github.com/batonogov/pine/commit/322f598d7116384c2ffb1dedb68508d74f4ee7e8))
* **terminal:** recover blank tab after delayed first output ([2246ee7](https://github.com/batonogov/pine/commit/2246ee7dffa3418bba04049045d165db4f6f6c8e))

## [1.33.2](https://github.com/batonogov/pine/compare/v1.33.1...v1.33.2) (2026-07-15)


### Bug Fixes

* prevent black Metal terminal frames ([#1129](https://github.com/batonogov/pine/issues/1129)) ([c924d8f](https://github.com/batonogov/pine/commit/c924d8f83a907dbcc4ae6cfce635e45beac8e7d3))

## [1.33.1](https://github.com/batonogov/pine/compare/v1.33.0...v1.33.1) (2026-07-14)


### Bug Fixes

* **terminal:** bump SwiftTerm to 1.14.0 to fix Metal cursor + TUI scroll artifacts ([#1125](https://github.com/batonogov/pine/issues/1125)) ([d2ac2ba](https://github.com/batonogov/pine/commit/d2ac2ba30c9d07f0b8a24e90b93bb0c488329582))

## [1.33.0](https://github.com/batonogov/pine/compare/v1.32.4...v1.33.0) (2026-07-14)


### Features

* **agent:** per-tab status glyphs + global attention indicator ([#1120](https://github.com/batonogov/pine/issues/1120)) ([b8bcd8f](https://github.com/batonogov/pine/commit/b8bcd8fac0f3e5e1ccabd0712c9fd91a8ce508ea))
* **terminal:** global hotkey drop-down (quick) terminal ([#1121](https://github.com/batonogov/pine/issues/1121)) ([e73eb05](https://github.com/batonogov/pine/commit/e73eb05fc26933dd6cace30e71edcd351c12650a))
* **terminal:** opt into SwiftTerm Metal renderer to eliminate black-screen class ([#1118](https://github.com/batonogov/pine/issues/1118)) ([06c6d38](https://github.com/batonogov/pine/commit/06c6d387815a8ec79515fefd9a8182407d35177b))
* **terminal:** OSC 8 hyperlinks + file:// reveal-in-Finder ([#1122](https://github.com/batonogov/pine/issues/1122)) ([e5ab3ea](https://github.com/batonogov/pine/commit/e5ab3ea839297d375093d5197b90734f45d04f77))
* **terminal:** zoom-to-fullscreen pane toggle ([#1123](https://github.com/batonogov/pine/issues/1123)) ([6010012](https://github.com/batonogov/pine/commit/601001227bf1a32b338eef89b624da6dccf19da9))

## [1.32.4](https://github.com/batonogov/pine/compare/v1.32.3...v1.32.4) (2026-07-10)


### Bug Fixes

* **terminal:** stop clearing layer.contents outside forceFullRedraw in appearance apply ([#1109](https://github.com/batonogov/pine/issues/1109)) ([4bdf3e3](https://github.com/batonogov/pine/commit/4bdf3e38950f8f90e9f649e3266edfd5dee8cc18))

## [1.32.3](https://github.com/batonogov/pine/compare/v1.32.2...v1.32.3) (2026-07-10)


### Bug Fixes

* **sidebar:** preserve loaded children across tree refresh ([#1104](https://github.com/batonogov/pine/issues/1104)) ([b77d33d](https://github.com/batonogov/pine/commit/b77d33d43f15e0a41101201ea73959a11d5dc640))

## [1.32.2](https://github.com/batonogov/pine/compare/v1.32.1...v1.32.2) (2026-07-09)


### Bug Fixes

* **terminal:** recover terminal backing store on occlusion/hide/minimize ([#1101](https://github.com/batonogov/pine/issues/1101)) ([2badccd](https://github.com/batonogov/pine/commit/2badccd13db99894b97bbe16087f48c639122d9f))

## [1.32.1](https://github.com/batonogov/pine/compare/v1.32.0...v1.32.1) (2026-07-06)


### Bug Fixes

* prevent sidebar flicker during deep expansion ([#1098](https://github.com/batonogov/pine/issues/1098)) ([8d45848](https://github.com/batonogov/pine/commit/8d458480959821d194b3f2ba4a0a760ae1ad7be6))

## [1.32.0](https://github.com/batonogov/pine/compare/v1.31.2...v1.32.0) (2026-07-05)


### Features

* **a11y:** VoiceOver labels, differentiate-without-color, reduce-motion ([#1003](https://github.com/batonogov/pine/issues/1003)) ([#1081](https://github.com/batonogov/pine/issues/1081)) ([360fc78](https://github.com/batonogov/pine/commit/360fc781d55bc4d0acac14c29fd956e7a899037b))
* **agent:** Agent Activity Panel ([#1072](https://github.com/batonogov/pine/issues/1072)) ([#1074](https://github.com/batonogov/pine/issues/1074)) ([f237048](https://github.com/batonogov/pine/commit/f2370485c42c497c6ba21a3e105a43fb5706f210))
* **agent:** Agent History & Undo ([#1073](https://github.com/batonogov/pine/issues/1073)) ([#1075](https://github.com/batonogov/pine/issues/1075)) ([bd2219f](https://github.com/batonogov/pine/commit/bd2219fbfeb1944479d39005a77f976782d169cc))
* lightweight extensibility — user grammars, tasks, keybindings ([#1009](https://github.com/batonogov/pine/issues/1009)) ([#1083](https://github.com/batonogov/pine/issues/1083)) ([83a894d](https://github.com/batonogov/pine/commit/83a894df3f3b344280d7639a17aaa55563a31f58))
* **lsp:** Phase 1 — Diagnostics (LSP client foundation) ([#1010](https://github.com/batonogov/pine/issues/1010)) ([#1082](https://github.com/batonogov/pine/issues/1082)) ([ea9893d](https://github.com/batonogov/pine/commit/ea9893d993752376377be4ffd8f9329c002ab08c))
* **lsp:** Phase 2 — Hover + Go-to-Definition ([#1011](https://github.com/batonogov/pine/issues/1011)) ([#1084](https://github.com/batonogov/pine/issues/1084)) ([4167def](https://github.com/batonogov/pine/commit/4167deffb8570019494b28015a7925bf87cd2966))
* **lsp:** Phase 3 — Completion ([#1012](https://github.com/batonogov/pine/issues/1012)) ([#1086](https://github.com/batonogov/pine/issues/1086)) ([b4233be](https://github.com/batonogov/pine/commit/b4233be18e26161febf849c806490d38feb4818a))
* **lsp:** Phase 4 — Code actions + Rename ([#1013](https://github.com/batonogov/pine/issues/1013)) ([#1087](https://github.com/batonogov/pine/issues/1087)) ([294ed8a](https://github.com/batonogov/pine/commit/294ed8addadcffa1ef0041e6976b438a23801b0c))
* **lsp:** UI integration — hover, go-to-definition, code actions, rename ([#1088](https://github.com/batonogov/pine/issues/1088)) ([#1091](https://github.com/batonogov/pine/issues/1091)) ([d7618cc](https://github.com/batonogov/pine/commit/d7618ccbb0cbbb21a9757c85c1b692eecb6817c2))


### Bug Fixes

* add security validation layer to UserTaskRunner ([#1088](https://github.com/batonogov/pine/issues/1088)) ([#1089](https://github.com/batonogov/pine/issues/1089)) ([ebf14f2](https://github.com/batonogov/pine/commit/ebf14f20dd010ee48dcf2b9061d2b788dc251327))
* **agent:** detect interpreter-wrapped agent CLIs (node/python/bun/…) ([#1078](https://github.com/batonogov/pine/issues/1078)) ([51deafb](https://github.com/batonogov/pine/commit/51deafbd799fa24dbd2c5a8d84a69212c78c771f))
* **i18n:** add localizations for a11y labels, Go-to-Line, and Problems panel ([#1093](https://github.com/batonogov/pine/issues/1093)) ([b7a70d5](https://github.com/batonogov/pine/commit/b7a70d58cdf96dfc319de933a25ecda22afdf3a3))
* **i18n:** add missing localizations for Tasks, Agent Activity, and rename-error ([#1092](https://github.com/batonogov/pine/issues/1092)) ([2b7d54c](https://github.com/batonogov/pine/commit/2b7d54c4d68c0343a658dfa47acc82ea1de82b1b))
* **terminal:** fix root cause of black screen — setNeedsDisplay race condition ([#1094](https://github.com/batonogov/pine/issues/1094)) ([#1095](https://github.com/batonogov/pine/issues/1095)) ([bdce6b1](https://github.com/batonogov/pine/commit/bdce6b1d22af1dc7fd2a857ddd7b5340932dc14f))

## [1.31.2](https://github.com/batonogov/pine/compare/v1.31.1...v1.31.2) (2026-06-29)


### Bug Fixes

* **agent:** break MainActor-isolated timer handler causing crash on project open ([#1069](https://github.com/batonogov/pine/issues/1069)) ([d129fb9](https://github.com/batonogov/pine/commit/d129fb9ac0e8a7f709e519831a123ea18d956b51))

## [1.31.1](https://github.com/batonogov/pine/compare/v1.31.0...v1.31.1) (2026-06-29)


### Bug Fixes

* **agent:** boot detection coordinator on first terminal creation ([#1064](https://github.com/batonogov/pine/issues/1064)) ([29ae9c4](https://github.com/batonogov/pine/commit/29ae9c4d19715b21c38fffb9636d6c00b09f7c2b))
* **editor:** break save-path reentrancy causing macOS exclusivity abort ([#1066](https://github.com/batonogov/pine/issues/1066)) ([#1067](https://github.com/batonogov/pine/issues/1067)) ([dae439c](https://github.com/batonogov/pine/commit/dae439c858219a130ecc3096d71db5002fe946e5))

## [1.31.0](https://github.com/batonogov/pine/compare/v1.30.1...v1.31.0) (2026-06-25)


### Features

* **agent:** add agent status summary to status bar ([#1055](https://github.com/batonogov/pine/issues/1055)) ([4899973](https://github.com/batonogov/pine/commit/4899973b9427c2dd0b83da4fd48cca4623bf3880))


### Bug Fixes

* **editor:** break fold-observer reentrancy causing macOS exclusivity abort ([#1056](https://github.com/batonogov/pine/issues/1056)) ([#1057](https://github.com/batonogov/pine/issues/1057)) ([80a35a7](https://github.com/batonogov/pine/commit/80a35a74e693873215f884a6a456c2bf54e01363))
* **editor:** break menu-save reentrancy causing macOS exclusivity abort ([#1058](https://github.com/batonogov/pine/issues/1058)) ([#1059](https://github.com/batonogov/pine/issues/1059)) ([837ffa5](https://github.com/batonogov/pine/commit/837ffa52ba09701d57f63440ad81292545d3f147))


### Documentation

* require green CI before merge (branch protection) ([#1062](https://github.com/batonogov/pine/issues/1062)) ([26222c2](https://github.com/batonogov/pine/commit/26222c230dd3564cf6b586878f6c19931c727922))

## [1.30.1](https://github.com/batonogov/pine/compare/v1.30.0...v1.30.1) (2026-06-24)


### Bug Fixes

* **editor:** break @State reentrancy in .onReceive handlers ([#1051](https://github.com/batonogov/pine/issues/1051)) ([#1052](https://github.com/batonogov/pine/issues/1052)) ([e35fc7c](https://github.com/batonogov/pine/commit/e35fc7c1f518d0c3935c0fc88e91510ad5e31109))


### Miscellaneous

* update screenshots ([#1049](https://github.com/batonogov/pine/issues/1049)) ([19bce3a](https://github.com/batonogov/pine/commit/19bce3a886792ad15803378f5ccaf83dd0d3c00a))

## [1.30.0](https://github.com/batonogov/pine/compare/v1.29.0...v1.30.0) (2026-06-23)


### Features

* **agent:** add AgentDetector for process-name detection ([#1036](https://github.com/batonogov/pine/issues/1036)) ([08c0b63](https://github.com/batonogov/pine/commit/08c0b63cb3c9f6b9903bf3c71227607af538996a))
* **agent:** show agent badge and color coding on terminal tabs ([#1048](https://github.com/batonogov/pine/issues/1048)) ([bb90df7](https://github.com/batonogov/pine/commit/bb90df7d8f8b03b5d6c05cd1f39f2cb83e98be76))


### Bug Fixes

* checkout main in screenshots workflow to avoid detached HEAD ([#1037](https://github.com/batonogov/pine/issues/1037)) ([fbf656e](https://github.com/batonogov/pine/commit/fbf656e340ae43e571008f4eae6a1aa4fb5a41e5))
* **editor:** break @Observable reentrancy causing macOS 27 exclusivity abort ([#1047](https://github.com/batonogov/pine/issues/1047)) ([c2334e4](https://github.com/batonogov/pine/commit/c2334e407e2754f0f4c3ddd34caa2d3cf685992b))
* **sidebar:** force tree re-render after external refresh ([#1043](https://github.com/batonogov/pine/issues/1043)) ([7bd80bd](https://github.com/batonogov/pine/commit/7bd80bd64f3c59175830750db069ea2c747f7753))


### Code Refactoring

* **panes:** remove dead close-routing helpers from [#1024](https://github.com/batonogov/pine/issues/1024) ([#1046](https://github.com/batonogov/pine/issues/1046)) ([14af3cc](https://github.com/batonogov/pine/commit/14af3ccb81f34c2809c86afecef7a42b9e855400))


### Miscellaneous

* **build:** align macOS deployment target to 26.0 ([#1040](https://github.com/batonogov/pine/issues/1040)) ([266795f](https://github.com/batonogov/pine/commit/266795f33b36d99adca0aa13b12cb04741437104))
* ignore .pi agent artifacts and group agent ignores ([#1033](https://github.com/batonogov/pine/issues/1033)) ([4165087](https://github.com/batonogov/pine/commit/4165087b88c6dd9affc4aa4c546cb91b4dbb33bc))

## [1.29.0](https://github.com/batonogov/pine/compare/v1.28.1...v1.29.0) (2026-06-20)


### Features

* **perf:** Instruments template + OSSignposter tracing + input-latency rig ([#1023](https://github.com/batonogov/pine/issues/1023)) ([eef658b](https://github.com/batonogov/pine/commit/eef658b3d4f541f700137e247f0ebf663c2bfec4)), closes [#1005](https://github.com/batonogov/pine/issues/1005)


### Bug Fixes

* **ci:** repair screenshots.yml + add failure notification ([#1019](https://github.com/batonogov/pine/issues/1019)) ([66e430a](https://github.com/batonogov/pine/commit/66e430a5a8c30da540cba8be47f7dc21a480aea7))
* **concurrency:** cancel outstanding highlight work in Coordinator.deinit ([#1016](https://github.com/batonogov/pine/issues/1016)) ([e48bd84](https://github.com/batonogov/pine/commit/e48bd84782a1909c39d9037ebda6d70f14983226)), closes [#1007](https://github.com/batonogov/pine/issues/1007)
* **perf:** move shallow loadTree off main thread in refreshFileTree ([#1022](https://github.com/batonogov/pine/issues/1022)) ([ff17ec9](https://github.com/batonogov/pine/commit/ff17ec9676a3bfd1433166aa7eef8a44e61eeb78))
* **split-pane:** route commands through active pane + fix TabManager leak ([#1024](https://github.com/batonogov/pine/issues/1024)) ([c0bd8da](https://github.com/batonogov/pine/commit/c0bd8dae4e1c167a51c3de1b0445aa27c8482183))


### Documentation

* sync AGENTS.md drift (debounce, snapshot count, thresholds) ([#1017](https://github.com/batonogov/pine/issues/1017)) ([6af03d5](https://github.com/batonogov/pine/commit/6af03d5e5c04bc4c72d99b6abc3d93064ffb8822)), closes [#1004](https://github.com/batonogov/pine/issues/1004)


### Miscellaneous

* **ci:** remove Claude Code workflows ([#1025](https://github.com/batonogov/pine/issues/1025)) ([4a2d5ec](https://github.com/batonogov/pine/commit/4a2d5ec9e0898243fbacba34aec3a9187287f7a6))

## [1.28.1](https://github.com/batonogov/pine/compare/v1.28.0...v1.28.1) (2026-06-18)


### Bug Fixes

* **terminal:** accumulate residual delta for alternate-screen arrow-key scroll ([#991](https://github.com/batonogov/pine/issues/991)) ([508bb1f](https://github.com/batonogov/pine/commit/508bb1f356083906f4e32a5b42a4ed2499b4cd95))
* **terminal:** flush residual delta on scroll gesture phase boundaries ([#992](https://github.com/batonogov/pine/issues/992)) ([53020ec](https://github.com/batonogov/pine/commit/53020ecd3eeffb98c2d254b1deb40c93ef7aaede))
* **terminal:** pixel-precise mouse forwarding for TUI scroll ([#989](https://github.com/batonogov/pine/issues/989)) ([9c1d8d2](https://github.com/batonogov/pine/commit/9c1d8d2e816d07aaeb7541a5b5994e1358a8d0a8))


### Documentation

* document milestone-driven subagent orchestration workflow ([#993](https://github.com/batonogov/pine/issues/993)) ([50f7885](https://github.com/batonogov/pine/commit/50f7885af8114b40a9aa781fa479c6403885b489))
* move CLAUDE.md to AGENTS.md and document maintainer workflow ([#988](https://github.com/batonogov/pine/issues/988)) ([0e358c8](https://github.com/batonogov/pine/commit/0e358c8dc46c3ebaec100a62234a328824054e81))

## [1.28.0](https://github.com/batonogov/pine/compare/v1.27.2...v1.28.0) (2026-06-17)


### Features

* **git:** add branch switch command ([#977](https://github.com/batonogov/pine/issues/977)) ([65ab725](https://github.com/batonogov/pine/commit/65ab725f21f00dd2a19ca295d56e0d63d6409620))
* **terminal:** make file:line references clickable in terminal output ([#949](https://github.com/batonogov/pine/issues/949)) ([#983](https://github.com/batonogov/pine/issues/983)) ([7be53ba](https://github.com/batonogov/pine/commit/7be53bafa198509840a58c4f052d85b618100f13))


### Bug Fixes

* **keyboard:** make global shortcuts independent of keyboard layout ([#981](https://github.com/batonogov/pine/issues/981)) ([94b7e53](https://github.com/batonogov/pine/commit/94b7e537ab949df97809b4aeab81980268e514ab))
* **terminal:** confirm before stopping foreground processes ([#970](https://github.com/batonogov/pine/issues/970)) ([#982](https://github.com/batonogov/pine/issues/982)) ([a66f89e](https://github.com/batonogov/pine/commit/a66f89e26bc89426bffbe817c8afdb876f8504a0))


### Code Refactoring

* **tabs:** split TabManager.swift (900 LOC) into focused modules ([#961](https://github.com/batonogov/pine/issues/961)) ([76cbea3](https://github.com/batonogov/pine/commit/76cbea3e519d302cf2c358e35cbdf2cbcccff39a))


### Documentation

* correct branch protection rules (no up-to-date gate, no merge queue) ([#987](https://github.com/batonogov/pine/issues/987)) ([8c724b0](https://github.com/batonogov/pine/commit/8c724b0db61efc58c0cb4e9628691237dad25f5f))

## [1.27.2](https://github.com/batonogov/pine/compare/v1.27.1...v1.27.2) (2026-06-11)


### Miscellaneous

* trigger release for terminal redraw fix ([#966](https://github.com/batonogov/pine/issues/966)) ([#967](https://github.com/batonogov/pine/issues/967)) ([64259da](https://github.com/batonogov/pine/commit/64259daf86f99390700c3d028eb5f6e3628ce3a0))

## [1.27.1](https://github.com/batonogov/pine/compare/v1.27.0...v1.27.1) (2026-06-09)


### Bug Fixes

* **terminal:** dampen scrollback scroll speed to prevent runaway momentum ([#965](https://github.com/batonogov/pine/issues/965)) ([e4167e6](https://github.com/batonogov/pine/commit/e4167e65222ecdc4b28d18799c682f4afc6bdba8))


### Code Refactoring

* **config:** remove dead code, extract shared logic, fix race condition ([#959](https://github.com/batonogov/pine/issues/959)) ([13dcb39](https://github.com/batonogov/pine/commit/13dcb39dac776ce7c1812594c236892cda9b43dc))


### Documentation

* trim CLAUDE.md — remove duplication, add missing CI details ([#964](https://github.com/batonogov/pine/issues/964)) ([34be3ef](https://github.com/batonogov/pine/commit/34be3ef0db5419f0b71c6965456a14a83cc1501e))


### Miscellaneous

* **deps:** bump Sparkle 2.9.2 → 2.9.3, swift-argument-parser 1.7.1 → 1.8.2 ([#963](https://github.com/batonogov/pine/issues/963)) ([2261747](https://github.com/batonogov/pine/commit/226174783cb37693030de7991dc8689a26606683))

## [1.27.0](https://github.com/batonogov/pine/compare/v1.26.3...v1.27.0) (2026-06-06)


### Features

* **editor:** Shell script format-on-save via shfmt ([#855](https://github.com/batonogov/pine/issues/855)) ([85023a5](https://github.com/batonogov/pine/commit/85023a5ea8fa3321512227924c73f774429f9ffa))
* **syntax:** improve Python grammar — f-strings, prefixes, builtins, exceptions ([#958](https://github.com/batonogov/pine/issues/958)) ([0324c39](https://github.com/batonogov/pine/commit/0324c39892d9d89c06c49afa3ef0d7a9c3ec5507))


### Bug Fixes

* **syntax:** thin out facade, fix encapsulation, break circular dependency ([#955](https://github.com/batonogov/pine/issues/955)) ([#960](https://github.com/batonogov/pine/issues/960)) ([4a9cd51](https://github.com/batonogov/pine/commit/4a9cd51d05b794edc18a4f82cce0e978410950ff))


### Code Refactoring

* **config:** split ConfigValidator.swift (798 LOC) into per-language files ([522e894](https://github.com/batonogov/pine/commit/522e8940ceb5d4b299769b2ac39c1c65a56dcacf))
* **git:** split GitStatusProvider.swift (959 LOC) into focused modules ([#946](https://github.com/batonogov/pine/issues/946)) ([8f9dac0](https://github.com/batonogov/pine/commit/8f9dac0aca028df55c2a53808a17748a24007e07))
* introduce AlertTemplate builder to deduplicate NSAlert boilerplate ([8055bed](https://github.com/batonogov/pine/commit/8055bedf89b366ad8943b8093ec1f979b59a13ac))
* **syntax:** split SyntaxHighlighter.swift (1266 LOC) into 5 focused modules + facade ([61fab81](https://github.com/batonogov/pine/commit/61fab816482ee8c9e3d3bcad1ff2ef781f7d21f7))

## [1.26.3](https://github.com/batonogov/pine/compare/v1.26.2...v1.26.3) (2026-06-01)


### Bug Fixes

* **ci:** screenshot extraction via xcresulttool get test-results ([#939](https://github.com/batonogov/pine/issues/939)) ([dca495b](https://github.com/batonogov/pine/commit/dca495b77d9647300420c417b777b54a744fbf6f))

## [1.26.2](https://github.com/batonogov/pine/compare/v1.26.1...v1.26.2) (2026-05-27)


### Bug Fixes

* **terminal:** auto-focus terminal after Cmd+T ([#941](https://github.com/batonogov/pine/issues/941)) ([d7ded33](https://github.com/batonogov/pine/commit/d7ded330048b4c5164800f310683cc634261acc8))


### Documentation

* add missing sections to CLAUDE.md ([#938](https://github.com/batonogov/pine/issues/938)) ([5652b11](https://github.com/batonogov/pine/commit/5652b1138b63e660a27ac05654be96a6865e4e04))

## [1.26.1](https://github.com/batonogov/pine/compare/v1.26.0...v1.26.1) (2026-05-24)


### Bug Fixes

* **editor:** cursor jumps to wrong position after pressing Enter ([#935](https://github.com/batonogov/pine/issues/935)) ([a946eac](https://github.com/batonogov/pine/commit/a946eac53274219b151752c4d89f5027e72fdefa))
* **editor:** eliminate syntax highlighting flicker on Enter ([#863](https://github.com/batonogov/pine/issues/863)) ([#936](https://github.com/batonogov/pine/issues/936)) ([aeba6de](https://github.com/batonogov/pine/commit/aeba6de778588e437fd437af33e83fd9bc8acc2c))

## [1.26.0](https://github.com/batonogov/pine/compare/v1.25.8...v1.26.0) (2026-05-24)


### Features

* **editor:** YAML format-on-save via prettier ([#929](https://github.com/batonogov/pine/issues/929)) ([215a64d](https://github.com/batonogov/pine/commit/215a64d15b91285bf8c2c461f58d55720a775466))
* **terminal:** light theme for system light appearance ([#931](https://github.com/batonogov/pine/issues/931)) ([#932](https://github.com/batonogov/pine/issues/932)) ([e80a2d3](https://github.com/batonogov/pine/commit/e80a2d33106573f65d964c05560f8b77f330c2a4))

## [1.25.8](https://github.com/batonogov/pine/compare/v1.25.7...v1.25.8) (2026-05-19)


### Miscellaneous

* update Sparkle to 2.9.2 ([#927](https://github.com/batonogov/pine/issues/927)) ([7cda971](https://github.com/batonogov/pine/commit/7cda9712fd650179bc00a749cab61bf4bbea705b))

## [1.25.7](https://github.com/batonogov/pine/compare/v1.25.6...v1.25.7) (2026-05-13)


### Miscellaneous

* update swift-markdown to 0.8.0 ([#925](https://github.com/batonogov/pine/issues/925)) ([9f67b26](https://github.com/batonogov/pine/commit/9f67b26dd8e732a5bca0e557b75cb853c01a874b))

## [1.25.6](https://github.com/batonogov/pine/compare/v1.25.5...v1.25.6) (2026-05-08)


### Bug Fixes

* **terminal:** redraw and SIGWINCH on re-parent for TUI alternate screen ([#923](https://github.com/batonogov/pine/issues/923)) ([05b3717](https://github.com/batonogov/pine/commit/05b3717b9b9e63465b156e325dd379fed7bd6b12))

## [1.25.5](https://github.com/batonogov/pine/compare/v1.25.4...v1.25.5) (2026-05-04)


### Bug Fixes

* **terminal:** start PTY and redraw when adding second tab in same pane ([#921](https://github.com/batonogov/pine/issues/921)) ([db58615](https://github.com/batonogov/pine/commit/db58615ffa43f8fd57b5aa374c92c8e4b78727a6))


### Code Refactoring

* remove ProcessRunning protocol, force defaults, contentPreparedForSave overload ([#902](https://github.com/batonogov/pine/issues/902)) ([#907](https://github.com/batonogov/pine/issues/907)) ([249bdcf](https://github.com/batonogov/pine/commit/249bdcf9dbc6a987564209d86166746c882d8d5c))


### Documentation

* update CLAUDE.md with recent features and fixes ([#875](https://github.com/batonogov/pine/issues/875)) ([729ba15](https://github.com/batonogov/pine/commit/729ba1563f585ad082bef1710b24b48ba2e637ea))

## [1.25.4](https://github.com/batonogov/pine/compare/v1.25.3...v1.25.4) (2026-05-04)


### Bug Fixes

* **terminal:** auto-scroll scrollback when dragging selection past view bounds ([#915](https://github.com/batonogov/pine/issues/915)) ([#916](https://github.com/batonogov/pine/issues/916)) ([37078b7](https://github.com/batonogov/pine/commit/37078b76862b13e5bc876d93e8d848fe3cce390d))

## [1.25.3](https://github.com/batonogov/pine/compare/v1.25.2...v1.25.3) (2026-04-28)


### Bug Fixes

* **editor:** align blank-line indent guides ([#893](https://github.com/batonogov/pine/issues/893)) ([f249226](https://github.com/batonogov/pine/commit/f2492268d6f255a415a87f9ea9ed57b10343a9af))


### Code Refactoring

* add runOnBackground helper, migrate withCheckedContinuation call-sites ([#898](https://github.com/batonogov/pine/issues/898)) ([#908](https://github.com/batonogov/pine/issues/908)) ([16b078d](https://github.com/batonogov/pine/commit/16b078d97de08ab99c4233dd92ee8f76472d8a20))
* extract UITimings constants for delays and debounces ([#899](https://github.com/batonogov/pine/issues/899)) ([#906](https://github.com/batonogov/pine/issues/906)) ([de5b36d](https://github.com/batonogov/pine/commit/de5b36d46695f6b003a1c20c662da38437d89333))


### Miscellaneous

* remove dead notifications and unused accessibility IDs ([#896](https://github.com/batonogov/pine/issues/896)) ([#905](https://github.com/batonogov/pine/issues/905)) ([54ea351](https://github.com/batonogov/pine/commit/54ea351fd6975089d8f8110650dfbc438663b853))

## [1.25.2](https://github.com/batonogov/pine/compare/v1.25.1...v1.25.2) (2026-04-27)


### Bug Fixes

* **editor:** align indent guides with pixel-snapped font metrics ([#878](https://github.com/batonogov/pine/issues/878)) ([42c1474](https://github.com/batonogov/pine/commit/42c14743b9bb3337fa107bfdcff89f10733ccaaf))

## [1.25.1](https://github.com/batonogov/pine/compare/v1.25.0...v1.25.1) (2026-04-24)


### Bug Fixes

* **sidebar:** suppress progress indicator flicker during incremental file tree refresh ([#877](https://github.com/batonogov/pine/issues/877)) ([#879](https://github.com/batonogov/pine/issues/879)) ([d526722](https://github.com/batonogov/pine/commit/d526722b0869fa2bdc604bb7be741dbc7054810b))
* **workspace:** clean up ProgressTracker operations on cancelled loads ([#882](https://github.com/batonogov/pine/issues/882)) ([e3c5156](https://github.com/batonogov/pine/commit/e3c51563121cdf85831387f850ce834f766c11d6))

## [1.25.0](https://github.com/batonogov/pine/compare/v1.24.0...v1.25.0) (2026-04-21)


### Features

* **editor:** external formatter infrastructure ([#860](https://github.com/batonogov/pine/issues/860)) ([8d4dab4](https://github.com/batonogov/pine/commit/8d4dab4d476f6706a4a58f932b3e119f481bf84a))
* **editor:** HCL/Terraform format-on-save with OpenTofu fallback ([#869](https://github.com/batonogov/pine/issues/869)) ([9a0f900](https://github.com/batonogov/pine/commit/9a0f90095739bca09ba575b9c041076dc73e68f3))


### Bug Fixes

* **editor:** dispatch ExternalFileFormatter to background queue ([#874](https://github.com/batonogov/pine/issues/874)) ([1159ede](https://github.com/batonogov/pine/commit/1159ede4b25120c21ff3b1477dfd0e5cf05a7a0c))
* **terminal:** force needsDisplay after re-parenting to prevent blank terminal ([#871](https://github.com/batonogov/pine/issues/871)) ([579a37a](https://github.com/batonogov/pine/commit/579a37ac23d21dbd10e5630e32140f2337dbfae7))

## [1.24.0](https://github.com/batonogov/pine/compare/v1.23.2...v1.24.0) (2026-04-18)


### Features

* **editor:** wire SmartListContinuation into GutterTextView.insertNewline ([#856](https://github.com/batonogov/pine/issues/856)) ([e390c46](https://github.com/batonogov/pine/commit/e390c463322633ddfe8e190bcd16a6f05e7c4032))


### Bug Fixes

* **editor:** refresh syntax highlighting after format-on-save ([#859](https://github.com/batonogov/pine/issues/859)) ([830e98f](https://github.com/batonogov/pine/commit/830e98fda1df81db80bcf381b6a7015bf2ef3356))
* enable PinePerformanceTests in scheme to fix nightly CI ([#850](https://github.com/batonogov/pine/issues/850)) ([66aaf9b](https://github.com/batonogov/pine/commit/66aaf9bb4c29c9475ca797eac5dda20622ef7c1a))
* use suggestedHumanReadableName for screenshot manifest parsing ([#849](https://github.com/batonogov/pine/issues/849)) ([3e1f25f](https://github.com/batonogov/pine/commit/3e1f25f6a4ebde0a877a9018b8f824caba330440))


### Code Refactoring

* **workspace:** rewrite loadDirectoryContentsAsync on pure Swift Concurrency ([#841](https://github.com/batonogov/pine/issues/841)) ([5f70ae7](https://github.com/batonogov/pine/commit/5f70ae7dbe4a810e3fa1a18d6fec75d670e4ca10))

## [1.23.2](https://github.com/batonogov/pine/compare/v1.23.1...v1.23.2) (2026-04-17)


### Bug Fixes

* **workspace:** restore external file change detection and sidebar refresh ([#840](https://github.com/batonogov/pine/issues/840)) ([24921cf](https://github.com/batonogov/pine/commit/24921cfd83668d00bf44aa75423393c050eecf9d)), closes [#838](https://github.com/batonogov/pine/issues/838) [#839](https://github.com/batonogov/pine/issues/839)


### Miscellaneous

* update Xcode project settings for Xcode 26.4 ([#845](https://github.com/batonogov/pine/issues/845)) ([fa4c0e0](https://github.com/batonogov/pine/commit/fa4c0e06744e62e7e24685d2ee3ca69c1b7228e6))

## [1.23.1](https://github.com/batonogov/pine/compare/v1.23.0...v1.23.1) (2026-04-14)


### Bug Fixes

* **terminal:** normalize embedded terminal env ([#834](https://github.com/batonogov/pine/issues/834)) ([1bd8f4c](https://github.com/batonogov/pine/commit/1bd8f4cb94c4d1fe640c223ef9015f43ee66f9cb))
* **test:** replace polling with CheckedContinuation in LayoutStabilityTests ([#824](https://github.com/batonogov/pine/issues/824)) ([015a3fb](https://github.com/batonogov/pine/commit/015a3fb7220b458516237084c2586e98039c1046))

## [1.23.0](https://github.com/batonogov/pine/compare/v1.22.0...v1.23.0) (2026-04-13)


### Features

* **editor:** nested syntax highlighting inside fenced code blocks ([#813](https://github.com/batonogov/pine/issues/813)) ([e2f80ac](https://github.com/batonogov/pine/commit/e2f80ac61453766e8b523b3f63ad98348b2e8e4e))


### Bug Fixes

* **terminal:** use One Dark background for proper TUI contrast ([#819](https://github.com/batonogov/pine/issues/819)) ([4c640e4](https://github.com/batonogov/pine/commit/4c640e4fde1a8248741ad91232b89bb2ef17b2e8))
* **test:** increase LayoutStabilityTests timeout to 60s for CI ([#821](https://github.com/batonogov/pine/issues/821)) ([#822](https://github.com/batonogov/pine/issues/822)) ([78e307a](https://github.com/batonogov/pine/commit/78e307a0bd53782d981391fc15fc48c36dae7a61))

## [1.22.0](https://github.com/batonogov/pine/compare/v1.21.0...v1.22.0) (2026-04-13)


### Features

* **editor:** insert final newline on save ([#799](https://github.com/batonogov/pine/issues/799)) ([5cc2f5d](https://github.com/batonogov/pine/commit/5cc2f5d4d1eb0be9540618683e28e1faed0761a4))
* **terminal:** add terminal theme picker with 6 built-in palettes ([#817](https://github.com/batonogov/pine/issues/817)) ([b165ae2](https://github.com/batonogov/pine/commit/b165ae253e9b6a7b34376bc96211f5ba34bc1e12))


### Bug Fixes

* **editor:** constrain diagnostic icon to fixed rect to prevent overlap ([#811](https://github.com/batonogov/pine/issues/811)) ([528997d](https://github.com/batonogov/pine/commit/528997dca462eb3fb6b7d1c509b3068f7928f5e4))
* **editor:** force diff gutter refresh via diffVersion counter ([#810](https://github.com/batonogov/pine/issues/810)) ([39df7ab](https://github.com/batonogov/pine/commit/39df7abfba77f293d352521a558dd566331f592b))
* **test:** resolve flaky LayoutStabilityTests on CI ([#818](https://github.com/batonogov/pine/issues/818)) ([7996d3f](https://github.com/batonogov/pine/commit/7996d3ffe95adcf88adb770cdb3fbb89b48b4df6))

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
