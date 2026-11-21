import AppKit
import CoreText

/// The editor's font: a monospaced family (nil for the system's, SF Mono), a size in points,
/// and whether code ligatures (`!=` as ≠, `->` as an arrow) are drawn.
public struct EditorFont: Equatable, Sendable {
    public var name: String?
    public var size: CGFloat
    public var ligatures: Bool

    public init(name: String? = nil, size: CGFloat = EditorFont.defaultSize, ligatures: Bool = false) {
        self.name = name
        self.size = size
        self.ligatures = ligatures
    }

    public static let defaultSize: CGFloat = 13
    public static let sizes: ClosedRange<CGFloat> = 8...40

    /// The families that come with Vie (in the app's Resources/Fonts), besides SF Mono.
    public static let bundled = ["JetBrains Mono", "Terminus (TTF)"]

    /// How a family is named in menus.
    public static func displayName(_ name: String?) -> String {
        switch name {
        case nil: "SF Mono"
        case "Terminus (TTF)": "Terminus TTF"
        case let name?: name
        }
    }

    /// Whether `name` is a family this process can use (installed, or bundled with the app).
    public static func isAvailable(_ name: String) -> Bool {
        (CTFontManagerCopyAvailableFontFamilyNames() as? [String])?.contains(name) == true
    }

    /// Monospaced families installed on this Mac, other than SF Mono and the bundled ones, by name.
    @MainActor public static func installedMonospacedFamilies() -> [String] {
        let manager = NSFontManager.shared
        var families = Set<String>()
        for name in manager.availableFontNames(with: .fixedPitchFontMask) ?? [] {
            guard let family = NSFont(name: name, size: 12)?.familyName, !family.hasPrefix(".") else { continue }
            families.insert(family)
        }
        families.subtract(bundled + ["SF Mono"])
        return families.sorted { $0.localizedStandardCompare($1) == .orderedAscending }
    }

    /// The regular, bold and italic faces. A family that isn't available falls back to SF Mono;
    /// one without a bold or italic face uses its regular one.
    public func faces() -> (regular: CTFont, bold: CTFont, italic: CTFont) {
        var base: CTFontDescriptor
        if let name, Self.isAvailable(name) {
            base = CTFontDescriptorCreateWithAttributes([kCTFontFamilyNameAttribute: name] as CFDictionary)
        } else {
            base = CTFontCopyFontDescriptor(NSFont.monospacedSystemFont(ofSize: size, weight: .regular) as CTFont)
        }
        if !ligatures {
            // Code ligatures live in contextual alternates (calt) as well as liga.
            let off = ["calt", "liga"].map { [kCTFontOpenTypeFeatureTag: $0, kCTFontOpenTypeFeatureValue: 0] as [CFString: Any] }
            base = CTFontDescriptorCreateCopyWithAttributes(base, [kCTFontFeatureSettingsAttribute: off] as CFDictionary)
        }
        let regular = CTFontCreateWithFontDescriptor(base, size, nil)
        func styled(_ traits: CTFontSymbolicTraits) -> CTFont {
            guard let d = CTFontDescriptorCreateCopyWithSymbolicTraits(base, traits, traits) else { return regular }
            let font = CTFontCreateWithFontDescriptor(d, size, nil)
            return CTFontGetSymbolicTraits(font).contains(traits) ? font : regular
        }
        return (regular, styled(.traitBold), styled(.traitItalic))
    }
}
