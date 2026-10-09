import Foundation

public struct SVNEntry: Identifiable, Hashable, Sendable {
    public var id: String { path }
    public let path: String
    public let status: String
    public let properties: String
    public let revision: String
    public let treeConflict: Bool
    public var isConflict: Bool { status == "conflicted" || properties == "conflicted" || treeConflict }
    public var isChanged: Bool { status != "normal" && status != "none" && status != "external" || properties == "modified" || isConflict }
    public var canCommit: Bool { isChanged && !["unversioned", "ignored", "missing", "obstructed", "incomplete", "external"].contains(status) && !isConflict }
    public var title: String {
        if isConflict { return "冲突" }
        switch status {
        case "modified": return "修改"
        case "added": return "新增"
        case "deleted": return "删除"
        case "replaced": return "替换"
        case "unversioned": return "未跟踪"
        case "missing": return "缺失"
        case "ignored": return "已忽略"
        case "obstructed": return "受阻"
        case "external": return "外部引用"
        case "incomplete": return "不完整"
        default: return properties == "modified" ? "属性修改" : "正常"
        }
    }
}

public struct SVNInfo: Sendable {
    public let kind: String
    public let url: String
    public let root: String
    public let revision: String
    public let workingRoot: String
}

public struct SVNLog: Identifiable, Sendable {
    public var id: String { revision }
    public let revision: String
    public let author: String
    public let date: String
    public let message: String
    public let paths: [String]
}

public struct SVNFailure: LocalizedError, Sendable {
    public let message: String
    public var errorDescription: String? { message }
    public init(_ message: String) { self.message = message }
}

public struct SVNRepositoryItem: Identifiable, Sendable {
    public var id: String { name }
    public let name: String
    public let kind: String
    public let size: Int
    public let revision: String
    public let author: String
    public let date: String
    public var isDirectory: Bool { kind == "dir" }
}
