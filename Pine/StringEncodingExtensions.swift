//
//  StringEncodingExtensions.swift
//  Pine
//
//  Extensions for String.Encoding to support display names and encoding detection.
//

import Foundation

extension String.Encoding {
    /// Human-readable name for the encoding, suitable for display in UI.
    var displayName: String {
        switch self {
        case .utf8: return "UTF-8"
        case .utf16: return "UTF-16"
        case .utf16BigEndian: return "UTF-16 BE"
        case .utf16LittleEndian: return "UTF-16 LE"
        case .utf32: return "UTF-32"
        case .utf32BigEndian: return "UTF-32 BE"
        case .utf32LittleEndian: return "UTF-32 LE"
        case .ascii: return "ASCII"
        case .isoLatin1: return "ISO Latin 1"
        case .isoLatin2: return "ISO Latin 2"
        case .windowsCP1251: return "Windows-1251"
        case .windowsCP1252: return "Windows-1252"
        case .windowsCP1250: return "Windows-1250"
        case .windowsCP1253: return "Windows-1253"
        case .windowsCP1254: return "Windows-1254"
        case .macOSRoman: return "Mac Roman"
        case .japaneseEUC: return "EUC-JP"
        case .shiftJIS: return "Shift JIS"
        case .iso2022JP: return "ISO-2022-JP"
        default:
            return String.localizedName(of: self)
        }
    }

    /// Encodings available for the user to choose from when reopening a file.
    static let availableEncodings: [String.Encoding] = [
        .utf8,
        .utf16,
        .utf16BigEndian,
        .utf16LittleEndian,
        .ascii,
        .isoLatin1,
        .isoLatin2,
        .windowsCP1250,
        .windowsCP1251,
        .windowsCP1252,
        .windowsCP1253,
        .windowsCP1254,
        .macOSRoman,
        .japaneseEUC,
        .shiftJIS,
        .iso2022JP
    ]

    /// Detects the encoding of file data. Tries UTF-8 first, then uses
    /// NSString's encoding detection as a fallback.
    static func detect(from data: Data) -> (String, String.Encoding) {
        // Try UTF-8 first (most common for source code)
        if let string = String(data: data, encoding: .utf8) {
            return (string, .utf8)
        }

        // Use NSString's encoding detection
        var convertedString: NSString?
        var usedLossyConversion: ObjCBool = false
        let detectedRawEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: [
                    String.Encoding.utf16.rawValue,
                    String.Encoding.utf16BigEndian.rawValue,
                    String.Encoding.utf16LittleEndian.rawValue,
                    String.Encoding.isoLatin1.rawValue,
                    String.Encoding.windowsCP1251.rawValue,
                    String.Encoding.windowsCP1252.rawValue,
                    String.Encoding.macOSRoman.rawValue,
                    String.Encoding.shiftJIS.rawValue,
                    String.Encoding.japaneseEUC.rawValue
                ],
                .allowLossyKey: false
            ],
            convertedString: &convertedString,
            usedLossyConversion: &usedLossyConversion
        )

        let detected = String.Encoding(rawValue: detectedRawEncoding)
        if let converted = convertedString as String? {
            return (converted, detected)
        }

        // Last resort: try with lossy conversion
        var lossyString: NSString?
        var lossyFlag: ObjCBool = false
        let lossyEncoding = NSString.stringEncoding(
            for: data,
            encodingOptions: [.allowLossyKey: true],
            convertedString: &lossyString,
            usedLossyConversion: &lossyFlag
        )

        if let converted = lossyString as String? {
            return (converted, String.Encoding(rawValue: lossyEncoding))
        }

        // Absolute fallback
        return (String(data: data, encoding: .isoLatin1) ?? "", .isoLatin1)
    }
}
