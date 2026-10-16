import Foundation

/// 編輯器可選用的文字編碼。
///
/// 原版用 Mozilla UniversalDetector 猜編碼；macOS 內建
/// `NSString.stringEncoding(for:...)` 就有同等能力，省掉第三方相依。
public struct TextEncoding: Hashable, Identifiable, Sendable {
    public let name: String
    public let encoding: String.Encoding

    public var id: String { name }

    public static let utf8 = TextEncoding(name: "UTF-8", encoding: .utf8)

    public static let all: [TextEncoding] = [
        .utf8,
        TextEncoding(name: "UTF-16LE", encoding: .utf16LittleEndian),
        TextEncoding(name: "UTF-16BE", encoding: .utf16BigEndian),
        TextEncoding(name: "Big5", encoding: cf(.big5_HKSCS_1999)),
        TextEncoding(name: "GB18030", encoding: cf(.GB_18030_2000)),
        TextEncoding(name: "Shift_JIS", encoding: .shiftJIS),
        TextEncoding(name: "EUC-KR", encoding: cf(.EUC_KR)),
        TextEncoding(name: "ISO-8859-1", encoding: .isoLatin1),
        TextEncoding(name: "Windows-1252", encoding: .windowsCP1252),
    ]

    private static func cf(_ value: CFStringEncodings) -> String.Encoding {
        String.Encoding(rawValue: CFStringConvertEncodingToNSStringEncoding(CFStringEncoding(value.rawValue)))
    }

    public static func named(_ name: String) -> TextEncoding? {
        all.first { $0.name.caseInsensitiveCompare(name) == .orderedSame }
    }
}

public enum TextCodec {
    /// 偵測編碼並解碼。純 ASCII 一律視為 UTF-8（原版 `normalizeDetectedTextEncoding` 的規則）。
    public static func decode(_ data: Data) -> (text: String, encoding: TextEncoding) {
        if data.isEmpty { return ("", .utf8) }
        if let text = String(data: data, encoding: .utf8) { return (text, .utf8) }

        var converted: NSString?
        let raw = NSString.stringEncoding(
            for: data,
            encodingOptions: [
                .suggestedEncodingsKey: TextEncoding.all.map { NSNumber(value: $0.encoding.rawValue) },
                .allowLossyKey: false,
            ],
            convertedString: &converted,
            usedLossyConversion: nil)
        if let converted, raw != 0 {
            let match = TextEncoding.all.first { $0.encoding.rawValue == raw }
                ?? TextEncoding(name: String.localizedName(of: String.Encoding(rawValue: raw)),
                                encoding: String.Encoding(rawValue: raw))
            return (converted as String, match)
        }
        // 什麼都猜不到：以寬鬆 UTF-8 解碼保底（無效位元組顯示為 �）
        return (String(decoding: data, as: UTF8.self), .utf8)
    }

    public static func decode(_ data: Data, as encoding: TextEncoding) -> String? {
        String(data: data, encoding: encoding.encoding)
    }

    /// 無損編碼：原編碼表示不了新輸入的字元時改存 UTF-8，絕不以 `?` 取代
    /// （原版 `encodeTextLosslessly`）。回傳實際使用的編碼與是否升級。
    public static func encodeLosslessly(_ text: String, preferred: TextEncoding) -> (data: Data, encoding: TextEncoding, upgraded: Bool) {
        if let data = text.data(using: preferred.encoding, allowLossyConversion: false) {
            return (data, preferred, false)
        }
        return (Data(text.utf8), .utf8, preferred != .utf8)
    }
}
