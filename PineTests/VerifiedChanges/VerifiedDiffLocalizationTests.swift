//
//  VerifiedDiffLocalizationTests.swift
//  PineTests
//
//  Locale-complete plural coverage for prepared inverse review counts.
//

import Foundation
import Testing

@testable import Pine

@Suite("Prepared Inverse Preview Localization")
struct VerifiedDiffLocalizationTests {
    @Test("Operation and byte plurals cover 0, 1, 2, and 5 in every locale")
    func localizedPluralCounts() {
        let expectations: [PluralExpectation] = [
            PluralExpectation(
                locale: "de",
                operations: [
                    "0 Vorgänge", "1 Vorgang", "2 Vorgänge", "5 Vorgänge",
                ],
                bytes: ["0 Byte", "1 Byte", "2 Byte", "5 Byte"]
            ),
            PluralExpectation(
                locale: "en",
                operations: [
                    "0 operations", "1 operation", "2 operations",
                    "5 operations",
                ],
                bytes: ["0 bytes", "1 byte", "2 bytes", "5 bytes"]
            ),
            PluralExpectation(
                locale: "es",
                operations: [
                    "0 operaciones", "1 operación", "2 operaciones",
                    "5 operaciones",
                ],
                bytes: ["0 bytes", "1 byte", "2 bytes", "5 bytes"]
            ),
            PluralExpectation(
                locale: "fr",
                operations: [
                    "0 opération", "1 opération", "2 opérations",
                    "5 opérations",
                ],
                bytes: ["0 octet", "1 octet", "2 octets", "5 octets"]
            ),
            PluralExpectation(
                locale: "ja",
                operations: [
                    "0 件の操作", "1 件の操作", "2 件の操作", "5 件の操作",
                ],
                bytes: [
                    "0 バイト", "1 バイト", "2 バイト", "5 バイト",
                ]
            ),
            PluralExpectation(
                locale: "ko",
                operations: [
                    "작업 0개", "작업 1개", "작업 2개", "작업 5개",
                ],
                bytes: ["0바이트", "1바이트", "2바이트", "5바이트"]
            ),
            PluralExpectation(
                locale: "pt-BR",
                operations: [
                    "0 operação", "1 operação", "2 operações",
                    "5 operações",
                ],
                bytes: ["0 byte", "1 byte", "2 bytes", "5 bytes"]
            ),
            PluralExpectation(
                locale: "ru",
                operations: [
                    "0 операций", "1 операция", "2 операции", "5 операций",
                ],
                bytes: ["0 байтов", "1 байт", "2 байта", "5 байтов"]
            ),
            PluralExpectation(
                locale: "zh-Hans",
                operations: [
                    "0 个操作", "1 个操作", "2 个操作", "5 个操作",
                ],
                bytes: ["0 字节", "1 字节", "2 字节", "5 字节"]
            ),
        ]
        let counts = [0, 1, 2, 5]

        for expectation in expectations {
            let locale = Locale(identifier: expectation.locale)
            #expect(
                counts.map {
                    Strings.verifiedDiffOperationCount(
                        $0,
                        locale: locale
                    )
                } == expectation.operations,
                "Operation plurals for \(expectation.locale)"
            )
            #expect(
                counts.map {
                    Strings.verifiedDiffByteCount($0, locale: locale)
                } == expectation.bytes,
                "Byte plurals for \(expectation.locale)"
            )
        }
    }

    @Test("Metadata wording covers every supported locale")
    func localizedMetadataWording() {
        let expectations: [MetadataExpectation] = [
            MetadataExpectation(
                locale: "de",
                metadataAlsoChanges:
                    "Dateimetadaten werden ebenfalls geändert",
                exactRestore:
                    "Stellt den vollständig erfassten Dateizustand wieder her."
            ),
            MetadataExpectation(
                locale: "en",
                metadataAlsoChanges: "File metadata also changes",
                exactRestore: "Restores the complete captured file state."
            ),
            MetadataExpectation(
                locale: "es",
                metadataAlsoChanges:
                    "Los metadatos del archivo también cambian",
                exactRestore:
                    "Restaura el estado completo capturado del archivo."
            ),
            MetadataExpectation(
                locale: "fr",
                metadataAlsoChanges:
                    "Les métadonnées du fichier changent également",
                exactRestore:
                    "Restaure l’état complet capturé du fichier."
            ),
            MetadataExpectation(
                locale: "ja",
                metadataAlsoChanges:
                    "ファイルのメタデータも変更されます",
                exactRestore:
                    "キャプチャされた完全なファイル状態を復元します。"
            ),
            MetadataExpectation(
                locale: "ko",
                metadataAlsoChanges: "파일 메타데이터도 변경됩니다",
                exactRestore: "캡처된 전체 파일 상태를 복원합니다."
            ),
            MetadataExpectation(
                locale: "pt-BR",
                metadataAlsoChanges:
                    "Os metadados do arquivo também são alterados",
                exactRestore:
                    "Restaura o estado completo capturado do arquivo."
            ),
            MetadataExpectation(
                locale: "ru",
                metadataAlsoChanges:
                    "Метаданные файла также изменяются",
                exactRestore:
                    "Восстанавливает полное зафиксированное состояние файла."
            ),
            MetadataExpectation(
                locale: "zh-Hans",
                metadataAlsoChanges: "文件元数据也会更改",
                exactRestore: "恢复已捕获的完整文件状态。"
            ),
        ]

        for expectation in expectations {
            let locale = Locale(identifier: expectation.locale)
            #expect(
                Strings.verifiedDiffMetadataAlsoChanges(locale: locale)
                    == expectation.metadataAlsoChanges
            )
            #expect(
                Strings.verifiedDiffDetailRestoreExactFile(locale: locale)
                    == expectation.exactRestore
            )
        }
    }
}

private struct PluralExpectation {
    let locale: String
    let operations: [String]
    let bytes: [String]
}

private struct MetadataExpectation {
    let locale: String
    let metadataAlsoChanges: String
    let exactRestore: String
}
