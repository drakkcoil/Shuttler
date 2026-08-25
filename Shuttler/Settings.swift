import SwiftUI

enum ListDensity: String, CaseIterable, Identifiable {
    case comfortable
    case compact
    var id: String { rawValue }
    var displayName: String { self == .comfortable ? "Comfortable" : "Compact" }
}

enum OverwriteBehavior: String, CaseIterable, Identifiable {
    case ask
    case overwrite
    case keepBoth
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ask: return "Ask"
        case .overwrite: return "Overwrite"
        case .keepBoth: return "Keep Both"
        }
    }
}

enum TransferProtocol: String, CaseIterable, Identifiable {
    case ftp
    case sftp
    case ftps

    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .ftp: return "FTP"
        case .sftp: return "SFTP"
        case .ftps: return "FTPS"
        }
    }
}

enum SortKey: String, CaseIterable, Identifiable {
    case name
    case size
    case kind
    var id: String { rawValue }
    var displayName: String {
        switch self {
        case .name: return "Name"
        case .size: return "Size"
        case .kind: return "Kind"
        }
    }
}

struct AppSettingsKeys {
    static let listDensity = "settings.listDensity"
    static let defaultProtocol = "settings.defaultProtocol"
    static let transferConcurrency = "settings.transferConcurrency"
    static let defaultDownloadFolder = "settings.defaultDownloadFolder"
    static let overwriteBehavior = "settings.overwriteBehavior"
    static let sshKeyPath = "settings.sshKeyPath"
    static let commandTimeout = "settings.commandTimeout"

    static let sortKey = "settings.sortKey"
    static let sortAscending = "settings.sortAscending"
    static let foldersFirst = "settings.foldersFirst"
    static let sidebarVisible = "settings.sidebarVisible"
}

struct SettingsModel {
    @AppStorage(AppSettingsKeys.listDensity) var listDensityRaw: String = ListDensity.comfortable.rawValue
    @AppStorage(AppSettingsKeys.defaultProtocol) var defaultProtocolRaw: String = TransferProtocol.sftp.rawValue
    @AppStorage(AppSettingsKeys.transferConcurrency) var transferConcurrency: Int = 3
    @AppStorage(AppSettingsKeys.defaultDownloadFolder) var defaultDownloadFolder: String = NSSearchPathForDirectoriesInDomains(.downloadsDirectory, .userDomainMask, true).first ?? "~/Downloads"
    @AppStorage(AppSettingsKeys.overwriteBehavior) var overwriteBehaviorRaw: String = OverwriteBehavior.ask.rawValue
    @AppStorage(AppSettingsKeys.sshKeyPath) var sshKeyPath: String = ""
    @AppStorage(AppSettingsKeys.commandTimeout) var commandTimeout: Double = 30

    @AppStorage(AppSettingsKeys.sortKey) var sortKeyRaw: String = SortKey.name.rawValue
    @AppStorage(AppSettingsKeys.sortAscending) var sortAscending: Bool = true
    @AppStorage(AppSettingsKeys.foldersFirst) var foldersFirst: Bool = true

    var listDensity: ListDensity {
        get { ListDensity(rawValue: listDensityRaw) ?? .comfortable }
        set { listDensityRaw = newValue.rawValue }
    }

    var defaultProtocol: TransferProtocol {
        get { TransferProtocol(rawValue: defaultProtocolRaw) ?? .sftp }
        set { defaultProtocolRaw = newValue.rawValue }
    }

    var overwriteBehavior: OverwriteBehavior {
        get { OverwriteBehavior(rawValue: overwriteBehaviorRaw) ?? .ask }
        set { overwriteBehaviorRaw = newValue.rawValue }
    }

    var sortKey: SortKey {
        get { SortKey(rawValue: sortKeyRaw) ?? .name }
        set { sortKeyRaw = newValue.rawValue }
    }
}

