import Foundation
import Darwin

public enum SVNBadge: String, Codable, Sendable {
    case modified, added, unversioned, conflict, deleted
    public var priority: Int {
        switch self { case .conflict: return 100; case .modified: return 60; case .deleted: return 50; case .added: return 40; case .unversioned: return 20 }
    }
    public var title: String {
        switch self { case .modified: return "SVN：已修改"; case .added: return "SVN：待新增"; case .unversioned: return "SVN：未跟踪"; case .conflict: return "SVN：有冲突"; case .deleted: return "SVN：待删除" }
    }
    public static func from(_ entry: SVNEntry) -> SVNBadge? {
        if entry.isConflict { return .conflict }
        switch entry.status {
        case "ignored", "external": return nil
        case "added": return .added
        case "unversioned": return .unversioned
        case "deleted", "missing": return .deleted
        case "obstructed", "incomplete": return .conflict
        default: return entry.isChanged ? .modified : nil
        }
    }
}
public struct FinderRootState: Codable, Sendable {
    public let path: String
    public let available: Bool
    public let badges: [String: SVNBadge]
    public init(path: String, entries: [SVNEntry]?, available: Bool = true) {
        self.path = URL(fileURLWithPath: path).standardizedFileURL.path
        self.available = available && entries != nil
        var result: [String: SVNBadge] = [:]
        for entry in entries ?? [] {
            guard let badge = SVNBadge.from(entry) else { continue }
            let file = URL(fileURLWithPath: self.path).appendingPathComponent(entry.path).standardizedFileURL
            guard FinderSnapshot.contains(file.path, in: self.path) else { continue }
            func apply(_ value: SVNBadge, to path: String) {
                if (result[path]?.priority ?? -1) < value.priority { result[path] = value }
            }
            apply(badge, to: file.path)
            var parent = file.deletingLastPathComponent()
            while FinderSnapshot.contains(parent.path, in: self.path) {
                apply(badge == .conflict ? .conflict : .modified, to: parent.path)
                if parent.path == self.path { break }
                parent.deleteLastPathComponent()
            }
        }
        self.badges = result
    }
}
public struct FinderSnapshot: Codable, Sendable {
    public let generatedAt: Date
    public let roots: [FinderRootState]
    public init(roots: [FinderRootState], generatedAt: Date = Date()) { self.roots = roots; self.generatedAt = generatedAt }
    public static func contains(_ path: String, in root: String) -> Bool { path == root || path.hasPrefix(root.hasSuffix("/") ? root : root + "/") }
    public func badge(for path: String, now: Date = Date()) -> SVNBadge? {
        guard now.timeIntervalSince(generatedAt) <= 20, now.timeIntervalSince(generatedAt) >= -5 else { return nil }
        let normalized = URL(fileURLWithPath: path).standardizedFileURL.path
        guard let root = roots.filter({ Self.contains(normalized, in: $0.path) }).max(by: { $0.path.count < $1.path.count }), root.available else { return nil }
        return root.badges[normalized]
    }
    public static var storeDirectory: URL {
        // 扩展沙箱中的 homeDirectory 指向容器，这里取得登录用户的真实目录。
        let home = getpwuid(getuid()).map { String(cString: $0.pointee.pw_dir) } ?? NSHomeDirectory()
        let name = Bundle.main.object(forInfoDictionaryKey: "SVNDeskFinderStoreName") as? String ?? "SVN Desk"
        return URL(fileURLWithPath: home).appendingPathComponent("Library/Application Support/\(name)/Finder", isDirectory: true)
    }
    public static var storeURL: URL { storeDirectory.appendingPathComponent("state.json") }
    public func write(to url: URL = Self.storeURL) throws {
        try FileManager.default.createDirectory(at: url.deletingLastPathComponent(), withIntermediateDirectories: true, attributes: [.posixPermissions: 0o700])
        try JSONEncoder().encode(self).write(to: url, options: .atomic)
        try FileManager.default.setAttributes([.posixPermissions: 0o600], ofItemAtPath: url.path)
    }
    public static func read(from url: URL = Self.storeURL) throws -> Self { try JSONDecoder().decode(Self.self, from: Data(contentsOf: url)) }
}

public struct FinderRequest: Sendable {
    public static var scheme: String { Bundle.main.object(forInfoDictionaryKey: "SVNDeskURLScheme") as? String ?? "svndesk" }
    public let action: String
    public let paths: [String]
    public static let actions: Set<String> = ["open", "diff", "commit", "update", "log", "refresh", "browser"]
    public init(action: String, paths: [String]) { self.action = action; self.paths = paths }
    public var url: URL? {
        guard Self.actions.contains(action) else { return nil }
        var components = URLComponents(); components.scheme = Self.scheme; components.host = "finder"
        components.queryItems = [URLQueryItem(name: "action", value: action)] + paths.prefix(100).map { URLQueryItem(name: "path", value: $0) }
        return components.url
    }
    public static func parse(_ url: URL) -> Self? {
        guard url.scheme == Self.scheme, url.host == "finder", let components = URLComponents(url: url, resolvingAgainstBaseURL: false),
              let action = components.queryItems?.first(where: { $0.name == "action" })?.value, actions.contains(action) else { return nil }
        let paths = components.queryItems?.filter { $0.name == "path" }.compactMap(\.value) ?? []
        guard paths.count <= 100, paths.allSatisfy({ $0.hasPrefix("/") && !$0.contains("\0") }) else { return nil }
        return Self(action: action, paths: paths.map { URL(fileURLWithPath: $0).standardizedFileURL.path })
    }
}
