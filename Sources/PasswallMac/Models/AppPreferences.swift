import SwiftUI

enum AppLanguage: String, CaseIterable, Identifiable {
    case chineseSimplified = "zh-Hans"
    case english = "en"

    var id: Self { self }

    static var systemDefault: Self {
        Locale.current.language.languageCode?.identifier == "zh"
            ? .chineseSimplified
            : .english
    }

    var shortLabel: String {
        switch self {
        case .chineseSimplified: "中文"
        case .english: "EN"
        }
    }

    var locale: Locale { Locale(identifier: rawValue) }

    func localized(_ key: String) -> String {
        let resourceName = rawValue.lowercased()
        guard let path = Self.localizationBundle.path(
            forResource: resourceName,
            ofType: "lproj"
        ),
              let bundle = Bundle(path: path) else {
            return key
        }
        return bundle.localizedString(forKey: key, value: key, table: nil)
    }

    private static var localizationBundle: Bundle {
        if let resources = Bundle.main.resourceURL,
           let installed = Bundle(
               url: resources.appendingPathComponent("Passwall_PasswallMac.bundle")
           ) {
            return installed
        }
        return .module
    }
}

enum AppAppearance: String, CaseIterable, Identifiable {
    case system
    case light
    case dark

    var id: Self { self }

    var colorScheme: ColorScheme? {
        switch self {
        case .system: nil
        case .light: .light
        case .dark: .dark
        }
    }

    var symbol: String {
        switch self {
        case .system: "circle.lefthalf.filled"
        case .light: "sun.max"
        case .dark: "moon"
        }
    }

    var titleKey: String {
        switch self {
        case .system: "System"
        case .light: "Light"
        case .dark: "Dark"
        }
    }
}
