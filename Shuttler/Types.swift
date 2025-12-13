import Foundation
import SwiftUI

// 1) Typealias to unify ProtocolType and TransferProtocol
typealias ProtocolType = TransferProtocol

// 2) ListDensity enum used in ContentView and SettingsView
enum ListDensity: String, CaseIterable, Identifiable {
    case compact
    case regular
    case spacious

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .compact:
            return "Compact"
        case .regular:
            return "Regular"
        case .spacious:
            return "Spacious"
        }
    }
}

// SortKey enum used in ContentView and SettingsView
enum SortKey: String, CaseIterable, Identifiable {
    case name
    case date
    case size
    case kind

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .name:
            return "Name"
        case .date:
            return "Date"
        case .size:
            return "Size"
        case .kind:
            return "Kind"
        }
    }
}

// 3) SettingsModel struct used in SettingsView with reasonable defaults
struct SettingsModel {
    var listDensity: ListDensity = .regular
    var sortKey: SortKey = .name
    var sortAscending: Bool = true
    var foldersFirst: Bool = true
    var overwriteBehavior: OverwriteBehavior = .ask
}

// 4) OverwriteBehavior enum used in SettingsView
enum OverwriteBehavior: String, CaseIterable, Identifiable {
    case ask
    case overwrite
    case skip
    case rename

    var id: String { rawValue }

    var displayName: String {
        switch self {
        case .ask:
            return "Ask Before Overwriting"
        case .overwrite:
            return "Overwrite Existing"
        case .skip:
            return "Skip Existing"
        case .rename:
            return "Rename New"
        }
    }
}

// AppSettingsKeys struct with static string keys referenced in ContentView
struct AppSettingsKeys {
    static let listDensity = "listDensity"
    static let sortKey = "sortKey"
    static let sortAscending = "sortAscending"
    static let foldersFirst = "foldersFirst"
}
