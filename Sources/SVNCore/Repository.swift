import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

private final class RepositoryXML: NSObject, XMLParserDelegate {
    var items: [SVNRepositoryItem] = []
    var text = "", kind = "", name = "", size = 0, revision = "", author = "", date = ""
    func parser(_ parser: XMLParser, didStartElement element: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String]) {
        text = ""
        if element == "entry" { kind = attributes["kind"] ?? "file"; name = ""; size = 0; revision = ""; author = ""; date = "" }
        if element == "commit" { revision = attributes["revision"] ?? "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { text += string }
    func parser(_ parser: XMLParser, didEndElement element: String, namespaceURI: String?, qualifiedName: String?) {
        switch element {
        case "name": name = text
        case "size": size = Int(text) ?? 0
        case "author": author = text
        case "date": date = text
        case "entry": items.append(.init(name: name, kind: kind, size: size, revision: revision, author: author, date: date))
        default: break
        }
        text = ""
    }
}
public enum SVNRepository {
    public static func displayURL(_ url: URL) -> String {
        let value = url.absoluteString, result = NSMutableString(string: value)
        // 只解码非 ASCII 字节；保留 %23、%25、%2F 等，避免编辑后改变路径含义。
        let pattern = try! NSRegularExpression(pattern: "(?:%[89A-Fa-f][0-9A-Fa-f])+")
        for match in pattern.matches(in: value, range: NSRange(location: 0, length: result.length)).reversed() {
            let encoded = (value as NSString).substring(with: match.range)
            if let decoded = encoded.removingPercentEncoding { result.replaceCharacters(in: match.range, with: decoded) }
        }
        return result as String
    }
    public static func validate(_ value: String) throws -> URL {
        let bytes = Array(value.trimmingCharacters(in: .whitespacesAndNewlines).utf8)
        let allowed = Set("ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-._~:/?#[]@!$&'()*+,;=".utf8)
        var encoded = "", index = 0
        func isHex(_ value: UInt8) -> Bool { (48...57).contains(value) || (65...70).contains(value) || (97...102).contains(value) }
        // 中文与已有转义混合输入时，先编码原始字节，避免 Foundation 把 % 再次编码。
        while index < bytes.count {
            let byte = bytes[index]
            if byte == 37, index + 2 < bytes.count, isHex(bytes[index + 1]), isHex(bytes[index + 2]) {
                encoded += String(decoding: bytes[index...index + 2], as: UTF8.self); index += 3
            } else {
                encoded += allowed.contains(byte) ? String(UnicodeScalar(byte)) : String(format: "%%%02X", byte)
                index += 1
            }
        }
        guard let url = URL(string: encoded),
              ["http", "https", "svn", "svn+ssh", "file"].contains(url.scheme ?? ""),
              url.user == nil, url.password == nil, url.query == nil, url.fragment == nil,
              url.scheme == "file" || !(url.host ?? "").isEmpty else {
            throw SVNFailure("请输入完整的 SVN 仓库 URL。特殊路径字符需要 URL 编码，账号密码请使用登录设置。")
        }
        return url
    }
    public static func revision(_ value: String) throws -> String {
        let clean = value.trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
        guard clean == "HEAD" || !clean.isEmpty && clean.allSatisfy(\.isNumber) && Int(clean) != nil else { throw SVNFailure("版本请输入 HEAD 或非负版本号。") }
        return clean
    }
    public static func target(_ url: URL, revision: String) -> String { url.absoluteString + "@" + revision }
    public static func creationRecord(for url: URL, revision: String, client: SVNClient, executable: String? = nil, credentials: SVNCredentials = .init()) async throws -> SVNLog? {
        let version = try Self.revision(revision)
        guard version != "HEAD" else { throw SVNFailure("读取创建时间需要固定的浏览版本。") }
        let data = try await client.run(["log", "--xml", "--quiet", "--stop-on-copy", "--limit", "1", "-r", "1:\(version)", "--", target(url, revision: version)], executable: executable, credentials: credentials)
        return try SVNParser.logs(data).first
    }
    public static func displayDate(_ value: String) -> String {
        let parser = ISO8601DateFormatter(); parser.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        var date = parser.date(from: value)
        if date == nil { parser.formatOptions = [.withInternetDateTime]; date = parser.date(from: value) }
        guard let date else { return "—" }
        let formatter = DateFormatter(); formatter.locale = Locale(identifier: "zh_CN"); formatter.timeZone = .current
        formatter.dateFormat = "yyyy-MM-dd HH:mm:ss"
        return formatter.string(from: date)
    }
    public static func parse(_ data: Data) throws -> [SVNRepositoryItem] {
        let parser = XMLParser(data: data), delegate = RepositoryXML()
        parser.delegate = delegate
        guard parser.parse() else { throw SVNFailure("仓库目录输出解析失败。") }
        return delegate.items.sorted { a, b in a.isDirectory != b.isDirectory ? a.isDirectory : a.name.localizedStandardCompare(b.name) == .orderedAscending }
    }
    public static func contains(_ url: URL, in root: URL) -> Bool {
        guard url.scheme == root.scheme, url.host == root.host, url.port == root.port else { return false }
        return url.path == root.path || url.path.hasPrefix(root.path.hasSuffix("/") ? root.path : root.path + "/")
    }
}
