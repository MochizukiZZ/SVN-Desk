import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

// 使用 SVN 的结构化输出，文件名中的空格、中文和换行不依赖文本列解析。
private final class SVNXML: NSObject, XMLParserDelegate {
    var entries: [SVNEntry] = []
    var logs: [SVNLog] = []
    var info: SVNInfo?
    var stack: [String] = []
    var buffer = ""
    var entryPath = "", item = "", props = "", revision = "", conflict = false
    var url = "", root = "", workingRoot = "", kind = ""
    var logRevision = "", author = "", date = "", message = "", paths: [String] = []

    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        stack.append(name); buffer = ""
        if name == "entry" { kind = attributes["kind"] ?? ""; entryPath = attributes["path"] ?? ""; revision = attributes["revision"] ?? "" }
        if name == "wc-status" {
            item = attributes["item"] ?? "none"; props = attributes["props"] ?? "none"
            revision = attributes["revision"] ?? ""; conflict = attributes["tree-conflicted"] == "true"
        }
        if name == "logentry" {
            logRevision = attributes["revision"] ?? ""; author = ""; date = ""; message = ""; paths = []
        }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { buffer += string }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        switch name {
        case "wc-status": entries.append(SVNEntry(path: entryPath, status: item, properties: props, revision: revision, treeConflict: conflict))
        case "url": url = buffer
        case "root": if stack.contains("repository") { root = buffer }
        case "wcroot-abspath": workingRoot = buffer
        case "author": if stack.contains("logentry") { author = buffer }
        case "date": if stack.contains("logentry") { date = buffer }
        case "msg": message = buffer
        case "path": if stack.contains("logentry") { paths.append(buffer) }
        case "logentry": logs.append(SVNLog(revision: logRevision, author: author, date: date, message: message, paths: paths))
        case "info": info = SVNInfo(kind: kind, url: url, root: root, revision: revision, workingRoot: workingRoot)
        default: break
        }
        _ = stack.popLast(); buffer = ""
    }
}

public enum SVNParser {
    private static func parse(_ data: Data) throws -> SVNXML {
        let delegate = SVNXML(), parser = XMLParser(data: data)
        parser.delegate = delegate
        guard parser.parse() else { throw SVNFailure("SVN 输出解析失败：\(parser.parserError?.localizedDescription ?? "无效 XML")") }
        return delegate
    }
    public static func status(_ data: Data) throws -> [SVNEntry] { try parse(data).entries }
    public static func info(_ data: Data) throws -> SVNInfo {
        guard let result = try parse(data).info, !result.url.isEmpty else { throw SVNFailure("此目录不是有效的 SVN 工作副本。") }
        return result
    }
    public static func logs(_ data: Data) throws -> [SVNLog] { try parse(data).logs }
}
