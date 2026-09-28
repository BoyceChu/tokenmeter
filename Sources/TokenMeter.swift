// TokenMeter — 這台 Mac 上所有 Claude 用量的系統列監控工具
// 自動掃描 Claude Code（終端機、VS Code、JetBrains）、Claude 桌面版（Code／Cowork）、Agent SDK 的本機記錄。
// 編譯：swiftc -O -parse-as-library TokenMeter.swift -o TokenMeter   （需要 macOS 13 以上）

import SwiftUI
import AppKit
import WebKit
import ServiceManagement

// MARK: - 格式化

func fmt(_ n: Double) -> String {
    let a = abs(n)
    if a >= 1e9 { return String(format: "%.2fB", n / 1e9) }
    if a >= 1e6 { return String(format: a >= 1e7 ? "%.1fM" : "%.2fM", n / 1e6) }
    if a >= 1e3 { return String(format: a >= 1e4 ? "%.0fk" : "%.1fk", n / 1e3) }
    return String(Int(n.rounded()))
}
func fmt(_ n: Int) -> String { fmt(Double(n)) }
func pct(_ x: Double) -> String { String(format: "%.0f%%", x * 100) }

/// 由文字長度估算 token：英數約 3.8 字元一個，中日韓約一字一個
func estTok(_ s: String) -> Int {
    var ascii = 0, wide = 0
    for u in s.utf8 {
        if u < 0x80 { ascii += 1 } else if u >= 0xC0 { wide += 1 }
    }
    return Int(Double(ascii) / 3.8 + Double(wide) * 0.95)
}

/// claude-opus-5-5 → Opus 5.5；claude-3-5-sonnet-20241022 → Sonnet 3.5
func modelName(_ id: String) -> String {
    let parts = id.lowercased().split(whereSeparator: { $0 == "-" || $0 == "[" || $0 == "]" }).map(String.init)
    let families = ["opus", "sonnet", "haiku", "fable", "mythos"]
    guard let fam = parts.first(where: { families.contains($0) }) else { return id.isEmpty ? "未知模型" : id }
    let nums = parts.filter { Int($0) != nil && $0.count <= 2 }
    let ver = nums.prefix(2).joined(separator: ".")
    return ver.isEmpty ? fam.capitalized : "\(fam.capitalized) \(ver)"
}

// MARK: - 方案額度（Claude Code 登入後可查詢的 5 小時／每週使用率）

struct PlanLimit: Identifiable {
    let id: String
    let label: String
    let used: Double        // 0–100
    let resetsAt: Date?
    var remaining: Double { max(0, 100 - used) }
}

struct PlanFetch {
    var limits: [PlanLimit] = []
    var plan: String? = nil
    var error: String? = nil
    var keepOld = false
}

/// 查詢端點是 Claude Code 的 /usage 指令在用的，尚未公開文件化，日後可能變動
enum PlanUsageClient {
    static let endpoint = URL(string: "https://api.anthropic.com/api/oauth/usage")!

    /// 讀取 Claude Code 存在鑰匙圈（或 ~/.claude/.credentials.json）的登入資料，只在本機讀取
    static func readCredentials() -> (token: String?, expires: Date?, plan: String?) {
        var raw: Data? = nil
        let p = Process()
        p.executableURL = URL(fileURLWithPath: "/usr/bin/security")
        p.arguments = ["find-generic-password", "-s", "Claude Code-credentials", "-w"]
        let pipe = Pipe()
        p.standardOutput = pipe
        p.standardError = Pipe()
        if (try? p.run()) != nil {
            let d = pipe.fileHandleForReading.readDataToEndOfFile()
            p.waitUntilExit()
            if p.terminationStatus == 0 { raw = d }
        }
        if raw == nil {
            let f = FileManager.default.homeDirectoryForCurrentUser.appendingPathComponent(".claude/.credentials.json")
            raw = try? Data(contentsOf: f)
        }
        guard let data = raw,
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let oauth = obj["claudeAiOauth"] as? [String: Any] else { return (nil, nil, nil) }
        let token = oauth["accessToken"] as? String
        let exp = (oauth["expiresAt"] as? NSNumber).map { Date(timeIntervalSince1970: $0.doubleValue / 1000) }
        let plan = oauth["subscriptionType"] as? String
        return (token, exp, plan)
    }

    static func fetch() async -> PlanFetch {
        let cred = readCredentials()
        var out = PlanFetch()
        out.plan = cred.plan.map { $0.prefix(1).uppercased() + String($0.dropFirst()) }
        guard let token = cred.token, !token.isEmpty else {
            out.error = "找不到 Claude Code 的登入資料。請在終端機執行 claude，用你的訂閱帳號登入一次。"
            return out
        }
        if let e = cred.expires, e < Date() {
            out.error = "Claude Code 的登入已過期。開啟 Claude Code 使用一下，它會自動更新登入，這裡就會恢復。"
            return out
        }
        var req = URLRequest(url: endpoint, timeoutInterval: 15)
        req.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")
        req.setValue("oauth-2025-04-20", forHTTPHeaderField: "anthropic-beta")
        req.setValue("application/json", forHTTPHeaderField: "Accept")
        req.setValue("TokenMeter/1.1", forHTTPHeaderField: "User-Agent")
        do {
            let (data, resp) = try await URLSession.shared.data(for: req)
            let code = (resp as? HTTPURLResponse)?.statusCode ?? 0
            if code == 401 || code == 403 {
                out.error = "Claude Code 的登入已過期。開啟 Claude Code 使用一下，它會自動更新登入。"
                return out
            }
            if code == 429 { out.error = "查詢太頻繁，稍後會自動重試。"; out.keepOld = true; return out }
            guard code == 200, let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
                out.error = "暫時無法取得方案額度（HTTP \(code)）。"; out.keepOld = true; return out
            }
            out.limits = parse(obj)
            if out.limits.isEmpty { out.error = "這個帳號沒有回傳額度資料（API 金鑰計費的帳號沒有方案額度）。" }
        } catch {
            out.error = "連不上 Anthropic，稍後會自動重試。"; out.keepOld = true
        }
        return out
    }

    private static let iso: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter(); f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]; return f
    }()
    private static func date(_ v: Any?) -> Date? {
        guard let s = v as? String else { return nil }
        return iso.date(from: s) ?? ISO8601DateFormatter().date(from: s)
    }

    static let labels: [String: String] = [
        "five_hour": "目前工作階段（5 小時）",
        "seven_day": "本週 · 所有模型",
        "seven_day_opus": "本週 · Opus",
        "seven_day_sonnet": "本週 · Sonnet",
        "seven_day_omelette": "本週 · Claude Design",
        "seven_day_oauth_apps": "本週 · 第三方應用",
    ]

    static func parse(_ obj: [String: Any]) -> [PlanLimit] {
        var out: [PlanLimit] = []
        // 新格式：limits 陣列（含各模型分開的每週額度）
        if let arr = obj["limits"] as? [[String: Any]], !arr.isEmpty {
            for (i, l) in arr.enumerated() {
                guard let pct = (l["percent"] as? NSNumber)?.doubleValue ?? (l["utilization"] as? NSNumber)?.doubleValue else { continue }
                let kind = l["kind"] as? String ?? "limit\(i)"
                let scope = (l["scope"] as? [String: Any])?["model"] as? [String: Any]
                let name = scope?["display_name"] as? String
                let label: String
                switch kind {
                case "session": label = "目前工作階段（5 小時）"
                case "weekly_all": label = "本週 · 所有模型"
                case "weekly_scoped": label = "本週 · \(name ?? "特定模型")"
                default: label = name.map { "\(kind) · \($0)" } ?? kind
                }
                out.append(PlanLimit(id: kind + (name ?? "") + "\(i)", label: label, used: pct, resetsAt: date(l["resets_at"])))
            }
            if !out.isEmpty { return out }
        }
        // 舊格式：five_hour／seven_day／seven_day_opus… 各自一個物件
        let order = ["five_hour", "seven_day", "seven_day_opus", "seven_day_sonnet"]
        let keys = obj.keys.sorted { a, b in
            let ia = order.firstIndex(of: a) ?? 99, ib = order.firstIndex(of: b) ?? 99
            return ia == ib ? a < b : ia < ib
        }
        for k in keys {
            guard let d = obj[k] as? [String: Any],
                  let u = (d["utilization"] as? NSNumber)?.doubleValue else { continue }
            out.append(PlanLimit(id: k, label: labels[k] ?? k, used: u, resetsAt: date(d["resets_at"])))
        }
        return out
    }
}

func resetText(_ d: Date?) -> String {
    guard let d = d else { return "" }
    let mins = Int(d.timeIntervalSinceNow / 60)
    let f = DateFormatter()
    f.locale = Locale(identifier: "zh_TW")
    if mins <= 0 { return "即將重置" }
    if mins < 60 { return "\(mins) 分鐘後重置" }
    if mins < 24 * 60 {
        f.dateFormat = "HH:mm"
        return "\(mins / 60) 小時 \(mins % 60) 分後重置（\(f.string(from: d))）"
    }
    f.dateFormat = "M/d（EEEEE）HH:mm"
    return "\(f.string(from: d)) 重置"
}

// MARK: - 資料模型

struct ToolUse {
    let id: String
    let name: String
    let target: String
    let filePath: String?
    let hasLimit: Bool
    let writeTok: Int
    var res: Int = 0      // 工具結果大小（估算）
    var resend: Int = 0   // 之後被重送的輪數
    var carried: Int { res * resend }
}

struct Step {
    var ts: Date
    var model: String = ""
    var inp: Int = 0
    var cw: Int = 0
    var cr: Int = 0
    var out: Int = 0
    var tools: [ToolUse] = []
    var compacted: Bool = false
    var round: Int = 0
    var textTok: Int = 0          // 這次呼叫中回覆文字的估算 token
    var hasToolUse: Bool = false
    var textPreview: String = ""
    /// 結果輸出：沒有呼叫工具的那次回覆，其文字部分算「結果」，其餘輸出（思考、工具呼叫）算「過程」
    var resultOut: Int { hasToolUse ? 0 : min(out, textTok) }
    var ctx: Int { inp + cw + cr }
    var total: Int { ctx + out }
}

struct Session {
    let key: String
    let project: String
    let cwd: String
    let source: String
    let rootID: String
    let sidechain: Bool
    var steps: [Step]
    var rounds: [Round] = []
    var start: Date { steps.first?.ts ?? .distantPast }
    var end: Date { steps.last?.ts ?? .distantPast }
    var total: Int { steps.reduce(0) { $0 + $1.total } }
}

/// 一回合：你送出一則訊息，到 Claude 做完回覆
struct Round {
    let ts: Date
    let prompt: String
    var first: Int = -1
    var last: Int = -1
    var finalText: String = ""
}

struct Entry {
    enum Kind { case call, result, prompt }
    let kind: Kind
    let key: String
    let cwd: String?
    let sidechain: Bool
    let ts: Date
    var entrypoint: String? = nil
    var source: String = ""
    var rootID: String = ""
    var msgId: String = ""
    var model: String = ""
    var inp: Int = 0
    var cw: Int = 0
    var cr: Int = 0
    var out: Int = 0
    var tools: [ToolUse] = []
    var toolUseId: String = ""
    var tok: Int = 0
    var text: String = ""
    var textTok: Int = 0
    var hasToolUse: Bool = false
}

/// 一個會被掃描的位置
struct Root {
    let id: String
    let label: String
    let url: URL?
    let recursive: Bool     // 深層搜尋（桌面版的資料夾結構不固定）
    let trackable: Bool
    let note: String
}

struct RootStat {
    let root: Root
    var exists = false
    var files = 0
}

struct ScanResult {
    var sessions: [Session] = []
    var roots: [RootStat] = []
}

struct Issue: Identifiable {
    let id: String
    let title: String
    let detail: String
    let fix: String
    let impact: Double
    var sev: Int = 0   // 2 優先、1 建議、0 小幅
}

struct DayTotal {
    let day: Date
    let total: Int
}

struct SourceTotal: Identifiable {
    let name: String
    let total: Int
    var id: String { name }
}

struct Snapshot {
    var inp = 0
    var cw = 0
    var cr = 0
    var out = 0
    var steps = 0
    var sessions = 0
    var todayTotal = 0
    var daily: [DayTotal] = []
    var bySource: [SourceTotal] = []
    var byModel: [SourceTotal] = []
    var issues: [Issue] = []
    var active: Session? = nil
    var total: Int { inp + cw + cr + out }
    var weighted: Double { Double(inp) + Double(cw) * 1.25 + Double(cr) * 0.1 + Double(out) * 5 }
    var hit: Double {
        let d = inp + cw + cr
        return d > 0 ? Double(cr) / Double(d) : 0
    }
}

// MARK: - 找出所有 Claude 記錄

final class LogScanner: @unchecked Sendable {
    private struct Cached {
        let mtime: Date
        let size: Int
        let entries: [Entry]
    }
    private var cache: [String: Cached] = [:]
    private let lock = NSLock()
    private let isoFrac: ISO8601DateFormatter = {
        let f = ISO8601DateFormatter()
        f.formatOptions = [.withInternetDateTime, .withFractionalSeconds]
        return f
    }()
    private let isoPlain = ISO8601DateFormatter()

    /// 深層搜尋時略過的資料夾（瀏覽器快取、虛擬機映像等，不會有對話記錄）
    private static let skipDirs: Set<String> = [
        "Cache", "Code Cache", "GPUCache", "DawnCache", "DawnGraphiteCache", "DawnWebGPUCache",
        "GrShaderCache", "ShaderCache", "IndexedDB", "Local Storage", "Session Storage",
        "blob_storage", "Crashpad", "Service Worker", "WebStorage", "Shared Dictionary",
        "shared_proto_db", "VideoDecodeStats", "databases", "Partitions", "node_modules",
        "vm_bundles", "sentry", "Dictionaries", "logs", "extensions", "Claude Extensions",
    ]

    static var roots: [Root] {
        let home = FileManager.default.homeDirectoryForCurrentUser
        var r: [Root] = []
        if let env = ProcessInfo.processInfo.environment["CLAUDE_CONFIG_DIR"], !env.isEmpty {
            r.append(Root(id: "env", label: "Claude Code（自訂設定資料夾）",
                          url: URL(fileURLWithPath: env).appendingPathComponent("projects"),
                          recursive: false, trackable: true, note: ""))
        }
        r.append(Root(id: "code", label: "Claude Code",
                      url: home.appendingPathComponent(".claude/projects"),
                      recursive: false, trackable: true, note: ""))
        r.append(Root(id: "xdg", label: "Claude Code（.config）",
                      url: home.appendingPathComponent(".config/claude/projects"),
                      recursive: false, trackable: true, note: ""))
        r.append(Root(id: "desktop", label: "Claude 桌面版（Code／Cowork）",
                      url: home.appendingPathComponent("Library/Application Support/Claude"),
                      recursive: true, trackable: true, note: ""))
        r.append(Root(id: "chat", label: "claude.ai 聊天",
                      url: nil, recursive: false, trackable: false,
                      note: "網頁與桌面版的一般聊天存在雲端，本機沒有 Token 記錄"))
        return r
    }

    func scan(since: Date) -> ScanResult {
        lock.lock()
        defer { lock.unlock() }
        let fm = FileManager.default
        var all: [Entry] = []
        var seenPaths = Set<String>()
        var stats: [RootStat] = []
        let keys: [URLResourceKey] = [.contentModificationDateKey, .fileSizeKey, .isDirectoryKey]

        for root in Self.roots {
            var st = RootStat(root: root)
            guard let url = root.url else { stats.append(st); continue }
            var isDir: ObjCBool = false
            st.exists = fm.fileExists(atPath: url.path, isDirectory: &isDir) && isDir.boolValue
            guard st.exists,
                  let en = fm.enumerator(at: url, includingPropertiesForKeys: keys, options: [.skipsPackageDescendants])
            else { stats.append(st); continue }
            let baseDepth = url.pathComponents.count

            for case let f as URL in en {
                let vals = try? f.resourceValues(forKeys: Set(keys))
                if vals?.isDirectory == true {
                    let depth = f.pathComponents.count - baseDepth
                    if root.recursive && (Self.skipDirs.contains(f.lastPathComponent) || depth > 12) {
                        en.skipDescendants()
                    }
                    continue
                }
                guard f.pathExtension == "jsonl" else { continue }
                let path = f.resolvingSymlinksInPath().path
                if seenPaths.contains(path) { continue }   // 不同位置指向同一個檔案時只算一次
                guard let m = vals?.contentModificationDate, m >= since else { continue }
                seenPaths.insert(path)
                let size = vals?.fileSize ?? 0
                let entries: [Entry]
                if let c = cache[path], c.mtime == m, c.size == size {
                    entries = c.entries
                } else {
                    entries = parse(f, root: root, path: path)
                    cache[path] = Cached(mtime: m, size: size, entries: entries)
                }
                if !entries.isEmpty { st.files += 1 }
                all.append(contentsOf: entries)
            }
            stats.append(st)
        }
        cache = cache.filter { seenPaths.contains($0.key) }
        return ScanResult(sessions: build(all), roots: stats)
    }

    private func date(_ s: String?) -> Date? {
        guard let s = s else { return nil }
        return isoFrac.date(from: s) ?? isoPlain.date(from: s)
    }

    private func num(_ v: Any?) -> Int { (v as? NSNumber)?.intValue ?? 0 }

    static func sourceName(entrypoint: String?, root: Root, path: String) -> String {
        if root.id == "desktop" {
            let p = path.lowercased()
            if p.contains("agent-mode") || p.contains("cowork") { return "Claude 桌面版 · Cowork" }
            return "Claude 桌面版 · Code"
        }
        guard let ep = entrypoint?.lowercased(), !ep.isEmpty else { return "Claude Code" }
        if ep.contains("vscode") { return "Claude Code · VS Code" }
        if ep.contains("jetbrains") || ep.contains("intellij") { return "Claude Code · JetBrains" }
        if ep.contains("desktop") { return "Claude 桌面版 · Code" }
        if ep.contains("sdk") { return "Agent SDK" }
        if ep == "cli" { return "Claude Code · 終端機" }
        return "Claude Code · " + ep
    }

    private func parse(_ url: URL, root: Root, path: String) -> [Entry] {
        guard let data = try? Data(contentsOf: url, options: .mappedIfSafe) else { return [] }
        var out: [Entry] = []
        var fileEntrypoint: String? = nil
        for line in data.split(separator: 0x0A) {
            // 快速略過不含用量或工具結果的行，減少 JSON 解析量
            guard let any = try? JSONSerialization.jsonObject(with: Data(line)),
                  let obj = any as? [String: Any],
                  let type = obj["type"] as? String,
                  type == "assistant" || type == "user",
                  let msg = obj["message"] as? [String: Any],
                  let ts = date(obj["timestamp"] as? String) else { continue }
            if fileEntrypoint == nil, let ep = obj["entrypoint"] as? String { fileEntrypoint = ep }
            let sid = obj["sessionId"] as? String ?? url.deletingPathExtension().lastPathComponent
            let side = obj["isSidechain"] as? Bool ?? false
            let agent = obj["agentId"] as? String ?? ""
            let key = side ? sid + ":sub:" + agent : sid
            let cwd = obj["cwd"] as? String

            if type == "assistant", let u = msg["usage"] as? [String: Any] {
                let model = msg["model"] as? String ?? ""
                if model == "<synthetic>" { continue }
                var e = Entry(kind: .call, key: key, cwd: cwd, sidechain: side, ts: ts)
                e.msgId = msg["id"] as? String ?? (obj["uuid"] as? String ?? UUID().uuidString)
                e.model = model
                e.inp = num(u["input_tokens"])
                e.cw = num(u["cache_creation_input_tokens"])
                e.cr = num(u["cache_read_input_tokens"])
                e.out = num(u["output_tokens"])
                if let content = msg["content"] as? [[String: Any]] {
                    for b in content where (b["type"] as? String) == "text" {
                        let t = b["text"] as? String ?? ""
                        e.textTok += estTok(t)
                        if e.text.isEmpty { e.text = String(t.prefix(240)) }
                    }
                    e.hasToolUse = content.contains { ($0["type"] as? String) == "tool_use" }
                    for b in content where (b["type"] as? String) == "tool_use" {
                        let input = b["input"] as? [String: Any] ?? [:]
                        let name = b["name"] as? String ?? "?"
                        let wt = name == "Write" ? estTok(input["content"] as? String ?? "") : 0
                        e.tools.append(ToolUse(
                            id: b["id"] as? String ?? UUID().uuidString,
                            name: name,
                            target: Self.target(input),
                            filePath: input["file_path"] as? String,
                            hasLimit: input["limit"] != nil || input["offset"] != nil,
                            writeTok: wt))
                    }
                }
                out.append(e)
            } else if type == "user", (obj["isMeta"] as? Bool) != true, (obj["isCompactSummary"] as? Bool) != true,
                      let prompt = Self.promptText(msg["content"]) {
                var e = Entry(kind: .prompt, key: key, cwd: cwd, sidechain: side, ts: ts)
                e.text = prompt
                out.append(e)
            } else if type == "user", let content = msg["content"] as? [[String: Any]] {
                for b in content where (b["type"] as? String) == "tool_result" {
                    var e = Entry(kind: .result, key: key, cwd: cwd, sidechain: side, ts: ts)
                    e.toolUseId = b["tool_use_id"] as? String ?? ""
                    e.tok = Self.resultTok(b["content"])
                    out.append(e)
                }
            }
        }
        // 不含任何用量的 .jsonl（桌面版的其他記錄檔）直接忽略
        guard out.contains(where: { $0.kind == .call }) else { return [] }
        let src = Self.sourceName(entrypoint: fileEntrypoint, root: root, path: path)
        for i in out.indices {
            out[i].source = src
            out[i].rootID = root.id
        }
        return out
    }

    /// 從使用者訊息取出你實際輸入的文字；工具結果、系統附帶內容不算
    static func promptText(_ c: Any?) -> String? {
        var parts: [String] = []
        var images = 0
        if let s = c as? String {
            parts = [s]
        } else if let arr = c as? [[String: Any]] {
            if arr.contains(where: { ($0["type"] as? String) == "tool_result" }) { return nil }
            for b in arr {
                let ty = b["type"] as? String
                if ty == "text" { parts.append(b["text"] as? String ?? "") }
                else if ty == "image" { images += 1 }
            }
        } else { return nil }
        var kept: [String] = []
        for raw in parts {
            let t = raw.trimmingCharacters(in: .whitespacesAndNewlines)
            if t.isEmpty { continue }
            if let r = t.range(of: "<command-name>"), let e = t.range(of: "</command-name>") , r.upperBound <= e.lowerBound {
                var cmd = String(t[r.upperBound..<e.lowerBound])
                if let a = t.range(of: "<command-args>"), let b = t.range(of: "</command-args>"), a.upperBound <= b.lowerBound {
                    let args = t[a.upperBound..<b.lowerBound].trimmingCharacters(in: .whitespaces)
                    if !args.isEmpty { cmd += " " + args }
                }
                kept.append(cmd)
                continue
            }
            let skipPrefixes = ["<ide_", "<system-reminder>", "<local-command", "<command-message>", "<command-stdout>",
                                "[Request interrupted", "Caveat:", "<bash-stdout>", "<bash-stderr>"]
            if skipPrefixes.contains(where: { t.hasPrefix($0) }) { continue }
            kept.append(t)
        }
        if kept.isEmpty && images == 0 { return nil }
        var text = kept.joined(separator: " ").replacingOccurrences(of: "\n", with: " ")
        if images > 0 { text = "［\(images) 張圖片］" + (text.isEmpty ? "" : " " + text) }
        return String(text.prefix(300))
    }

    static func resultTok(_ c: Any?) -> Int {
        if let s = c as? String { return estTok(s) }
        if let arr = c as? [[String: Any]] {
            var t = 0
            for b in arr {
                let ty = b["type"] as? String
                if ty == "text" { t += estTok(b["text"] as? String ?? "") }
                else if ty == "image" { t += 1600 }
            }
            return t
        }
        return 0
    }

    static func target(_ i: [String: Any]) -> String {
        for k in ["file_path", "notebook_path", "command", "pattern", "url", "query", "description", "prompt"] {
            if let s = i[k] as? String {
                return String(s.replacingOccurrences(of: "\n", with: " ").prefix(110))
            }
        }
        return ""
    }

    private func build(_ entries: [Entry]) -> [Session] {
        var groups: [String: [Entry]] = [:]
        for e in entries { groups[e.key, default: []].append(e) }

        // 依開始時間處理，同一則訊息（例如恢復對話時被複製）只算第一次
        let ordered = groups.map { ($0.key, $0.value.sorted { $0.ts < $1.ts }) }
            .sorted { ($0.1.first?.ts ?? .distantPast) < ($1.1.first?.ts ?? .distantPast) }
        var counted = Set<String>()
        var sessions: [Session] = []

        for (key, es) in ordered {
            var results: [String: Int] = [:]
            var calls: [String: Step] = [:]
            var order: [String] = []
            var cwd = "", side = false, source = "", rootID = ""
            var rounds: [Round] = []
            for e in es {
                if let c = e.cwd { cwd = c }
                if e.sidechain { side = true }
                if source.isEmpty { source = e.source; rootID = e.rootID }
                switch e.kind {
                case .prompt:
                    rounds.append(Round(ts: e.ts, prompt: e.text))
                case .result:
                    results[e.toolUseId] = e.tok
                case .call:
                    if var s = calls[e.msgId] {
                        s.inp = e.inp; s.cw = e.cw; s.cr = e.cr
                        s.out = max(s.out, e.out)
                        s.textTok += e.textTok
                        s.hasToolUse = s.hasToolUse || e.hasToolUse
                        if s.textPreview.isEmpty { s.textPreview = e.text }
                        for t in e.tools where !s.tools.contains(where: { $0.id == t.id }) { s.tools.append(t) }
                        calls[e.msgId] = s
                    } else {
                        if counted.contains(e.msgId) { continue }
                        counted.insert(e.msgId)
                        if rounds.isEmpty { rounds.append(Round(ts: e.ts, prompt: "（對話開始）")) }
                        var s = Step(ts: e.ts)
                        s.round = rounds.count - 1
                        s.textTok = e.textTok
                        s.hasToolUse = e.hasToolUse
                        s.textPreview = e.text
                        s.model = e.model
                        s.inp = e.inp; s.cw = e.cw; s.cr = e.cr; s.out = e.out
                        s.tools = e.tools
                        calls[e.msgId] = s
                        order.append(e.msgId)
                    }
                }
            }
            var steps = order.compactMap { calls[$0] }
            if steps.isEmpty { continue }

            // 脈絡驟降視為 /compact 或壓縮，之前的內容不再被重送
            var segEnd = Array(repeating: 0, count: steps.count)
            var end = steps.count - 1
            for i in stride(from: steps.count - 1, through: 0, by: -1) {
                segEnd[i] = end
                if i > 0, steps[i - 1].ctx > 20_000, Double(steps[i].ctx) < Double(steps[i - 1].ctx) * 0.55 {
                    steps[i].compacted = true
                    end = i - 1
                }
            }
            for i in steps.indices {
                for j in steps[i].tools.indices {
                    steps[i].tools[j].res = results[steps[i].tools[j].id] ?? 0
                    steps[i].tools[j].resend = max(0, segEnd[i] - i)
                }
            }
            // 回合：去掉沒有任何模型呼叫的訊息（例如 /clear），重新編號
            for (i, st) in steps.enumerated() {
                let r = st.round
                if rounds[r].first < 0 { rounds[r].first = i }
                rounds[r].last = i
                if !st.hasToolUse && !st.textPreview.isEmpty { rounds[r].finalText = st.textPreview }
            }
            var remap: [Int: Int] = [:]
            var kept: [Round] = []
            for (i, r) in rounds.enumerated() where r.first >= 0 { remap[i] = kept.count; kept.append(r) }
            for i in steps.indices { steps[i].round = remap[steps[i].round] ?? 0 }
            let project = cwd.isEmpty ? String(key.prefix(8)) : URL(fileURLWithPath: cwd).lastPathComponent
            var ses = Session(key: key, project: project, cwd: cwd,
                              source: source.isEmpty ? "Claude Code" : source,
                              rootID: rootID, sidechain: side, steps: steps)
            ses.rounds = kept
            sessions.append(ses)
        }
        return sessions.sorted { $0.end > $1.end }
    }
}

// MARK: - 分析（系統列面板用；完整儀表板在網頁裡另外計算）

enum Analyzer {
    typealias Hit = (tool: ToolUse, session: Session)

    static func snapshot(_ sessions: [Session], rangeStart: Date) -> Snapshot {
        var s = Snapshot()
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        var dayTotals: [Date: Int] = [:]
        var srcTotals: [String: Int] = [:]
        var modelTotals: [String: Int] = [:]
        var inRange: [(session: Session, idx: [Int])] = []

        for ses in sessions {
            var idx: [Int] = []
            for (i, st) in ses.steps.enumerated() {
                let d = cal.startOfDay(for: st.ts)
                dayTotals[d, default: 0] += st.total
                if d == today { s.todayTotal += st.total }
                if st.ts >= rangeStart {
                    idx.append(i)
                    s.inp += st.inp; s.cw += st.cw; s.cr += st.cr; s.out += st.out
                    srcTotals[ses.source, default: 0] += st.total
                    modelTotals[modelName(st.model), default: 0] += st.total
                }
            }
            if !idx.isEmpty { inRange.append((ses, idx)) }
        }
        s.steps = inRange.reduce(0) { $0 + $1.idx.count }
        s.sessions = inRange.count
        s.daily = (0..<7).reversed().map { k in
            let d = cal.date(byAdding: .day, value: -k, to: today) ?? today
            return DayTotal(day: d, total: dayTotals[d] ?? 0)
        }
        s.byModel = modelTotals.map { SourceTotal(name: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        s.bySource = srcTotals.map { SourceTotal(name: $0.key, total: $0.value) }.sorted { $0.total > $1.total }
        s.active = sessions.first(where: { !$0.sidechain })
        s.issues = issues(inRange)
        return s
    }

    static func short(_ t: String) -> String {
        if t.hasPrefix("/") { return URL(fileURLWithPath: t).lastPathComponent }
        return t.count > 44 ? String(t.prefix(44)) + "…" : t
    }

    static func issues(_ data: [(session: Session, idx: [Int])]) -> [Issue] {
        var tools: [Hit] = []
        for d in data {
            for i in d.idx { for t in d.session.steps[i].tools { tools.append((t, d.session)) } }
        }
        func sum(_ a: [Hit]) -> Double { Double(a.reduce(0) { $0 + $1.tool.carried }) }
        func ex(_ a: [Hit]) -> String {
            a.sorted { $0.tool.carried > $1.tool.carried }
                .prefix(2)
                .map { "\($0.session.project)：\(short($0.tool.target))（\(fmt($0.tool.res))）" }
                .joined(separator: "\n")
        }
        var out: [Issue] = []

        let bigRead = tools.filter { $0.tool.name == "Read" && $0.tool.res > 8000 && !$0.tool.hasLimit }
        if !bigRead.isEmpty {
            out.append(Issue(id: "read", title: "整份讀取大檔案 ×\(bigRead.count)", detail: ex(bigRead),
                             fix: "先用 Grep 找到行號，再用 Read 的 offset／limit 只讀需要的段落。", impact: sum(bigRead)))
        }

        var readMap: [String: [Hit]] = [:]
        for h in tools where h.tool.name == "Read" {
            if let f = h.tool.filePath { readMap[h.session.key + "|" + f, default: []].append(h) }
        }
        let repeated = readMap.values.filter { $0.count >= 3 }
        if !repeated.isEmpty {
            let extra = repeated.flatMap { Array($0.dropFirst()) }
            let names = repeated.sorted { $0.count > $1.count }.prefix(2).map {
                "\(URL(fileURLWithPath: $0[0].tool.filePath ?? "").lastPathComponent) 讀了 \($0.count) 次"
            }.joined(separator: "、")
            out.append(Issue(id: "reread", title: "同一檔案反覆讀取", detail: names,
                             fix: "把檔案結構與慣例寫進 CLAUDE.md；修改後用 Edit 的回傳確認，不必整份重讀。", impact: sum(extra)))
        }

        let bigBash = tools.filter { $0.tool.name == "Bash" && $0.tool.res > 4000 }
        if !bigBash.isEmpty {
            out.append(Issue(id: "bash", title: "指令輸出太長 ×\(bigBash.count)", detail: ex(bigBash),
                             fix: "請它加上 | tail -n 40、--silent，或把輸出寫進檔案再 grep 錯誤行。", impact: sum(bigBash)))
        }

        let extNames: Set<String> = ["WebFetch", "WebSearch", "Grep", "Glob"]
        let bigExt = tools.filter { ($0.tool.name.hasPrefix("mcp__") || extNames.contains($0.tool.name)) && $0.tool.res > 6000 }
        if !bigExt.isEmpty {
            out.append(Issue(id: "ext", title: "搜尋／網頁／MCP 回傳過大 ×\(bigExt.count)", detail: ex(bigExt),
                             fix: "Grep 改用只列檔名的模式或加 glob；MCP 查詢指定節點、欄位或筆數上限。", impact: sum(bigExt)))
        }

        let bigWrite = tools.filter { $0.tool.name == "Write" && $0.tool.writeTok > 3000 }
        if !bigWrite.isEmpty {
            let imp = Double(bigWrite.reduce(0) { $0 + $1.tool.writeTok }) * 5
            out.append(Issue(id: "write", title: "整份重寫檔案 ×\(bigWrite.count)", detail: ex(bigWrite),
                             fix: "修改既有檔案時請它用 Edit 只改需要的區塊，輸出 token 單價最高。", impact: imp))
        }

        var hiSteps = 0, hiImpact = 0.0, hiSess = Set<String>()
        var miss = 0, missIdle = 0, missImpact = 0.0
        var openCount = 0, openSum = 0, openImpact = 0.0
        for d in data {
            let st = d.session.steps
            for i in d.idx {
                if st[i].ctx > 120_000 {
                    hiSteps += 1; hiImpact += Double(st[i].ctx) * 0.1; hiSess.insert(d.session.key)
                }
                if i > 0, !st[i].compacted, st[i].ctx > 20_000, Double(st[i].cr) < Double(st[i].ctx) * 0.4 {
                    miss += 1; missImpact += Double(st[i].cw) * 1.25
                    if st[i].ts.timeIntervalSince(st[i - 1].ts) > 300 { missIdle += 1 }
                }
            }
            if !d.session.sidechain, d.idx.first == 0, st[0].ctx > 25_000 {
                openCount += 1; openSum += st[0].ctx
                openImpact += Double(st[0].ctx) * Double(st.count) * 0.1
            }
        }
        if hiSteps > 0 {
            out.append(Issue(id: "ctx", title: "脈絡超過 120k", detail: "\(hiSteps) 步在 120k 以上執行（\(hiSess.count) 個對話）",
                             fix: "一個功能做完就 /clear；同一任務還沒完成但已經很長，就 /compact 並說明要保留的重點。", impact: hiImpact))
        }
        if miss > 0 {
            let idleNote = missIdle > 0 ? "，其中 \(missIdle) 次在閒置 5 分鐘以上之後" : ""
            out.append(Issue(id: "cache", title: "快取失效 ×\(miss)", detail: "整段脈絡以較高的寫入價重新計費\(idleNote)",
                             fix: "快取約 5 分鐘過期。離開很久再回來先 /compact；對話中途別改 CLAUDE.md、換模型或開關 MCP。", impact: missImpact))
        }
        if openCount > 0 {
            out.append(Issue(id: "open", title: "開場就佔掉 \(fmt(openSum / openCount))", detail: "\(openCount) 個對話的第一步就很重：系統提示、MCP 工具說明、CLAUDE.md",
                             fix: "在 Claude Code 執行 /context 看是誰佔的，關掉這個專案用不到的 MCP server。", impact: openImpact))
        }

        out.sort { $0.impact > $1.impact }
        let mx = out.first?.impact ?? 0
        for i in out.indices {
            let v = out[i].impact
            out[i].sev = (i < 2 && v > mx * 0.35) ? 2 : (v > mx * 0.08 ? 1 : 0)
        }
        return out
    }
}

// MARK: - 轉成儀表板要的 JSON

enum Export {
    static func json(_ r: ScanResult, extra: [String: Any] = [:]) -> String {
        let ms = { (d: Date) -> Double in (d.timeIntervalSince1970 * 1000).rounded() }
        let sessions: [[String: Any]] = r.sessions.map { s in
            [
                "key": s.key, "project": s.project, "cwd": s.cwd, "source": s.source, "sidechain": s.sidechain,
                "rounds": s.rounds.map { r -> [String: Any] in
                    ["ts": ms(r.ts), "prompt": r.prompt, "finalText": r.finalText, "first": r.first, "last": r.last]
                },
                "steps": s.steps.map { p -> [String: Any] in
                    [
                        "ts": ms(p.ts), "model": p.model, "in": p.inp, "cw": p.cw, "cr": p.cr, "out": p.out,
                        "compacted": p.compacted, "r": p.round, "rOut": p.resultOut,
                        "tools": p.tools.map { t -> [String: Any] in
                            [
                                "name": t.name, "target": t.target, "filePath": (t.filePath as Any?) ?? NSNull(),
                                "hasLimit": t.hasLimit, "writeTok": t.writeTok, "res": t.res, "resend": t.resend,
                            ]
                        },
                    ]
                },
            ]
        }
        let sources: [[String: Any]] = r.roots.map { st in
            let mine = r.sessions.filter { $0.rootID == st.root.id }
            return [
                "label": st.root.label,
                "path": st.root.url.map { $0.path.replacingOccurrences(of: NSHomeDirectory(), with: "~") } ?? "",
                "fullPath": st.root.url?.path ?? "",
                "exists": st.exists, "trackable": st.root.trackable, "note": st.root.note,
                "files": st.files, "sessions": mine.count,
                "tokens": mine.reduce(0) { $0 + $1.total },
                "latest": (mine.map { ms($0.end) }.max() as Any?) ?? NSNull(),
            ]
        }
        var obj: [String: Any] = ["generatedAt": ms(Date()), "sessions": sessions, "sources": sources]
        for (k, v) in extra { obj[k] = v }
        guard let d = try? JSONSerialization.data(withJSONObject: obj),
              let s = String(data: d, encoding: .utf8) else { return "{}" }
        return s
    }
}

// MARK: - 狀態

@MainActor
final class UsageStore: ObservableObject {
    static let shared = UsageStore()

    enum Span: String, CaseIterable, Identifiable {
        case today = "今天"
        case week = "近 7 天"
        var id: String { rawValue }
    }

    @Published var span: Span = .today { didSet { recompute() } }
    @Published private(set) var snap = Snapshot()
    @Published private(set) var updated: Date? = nil
    @Published private(set) var loading = false
    @Published private(set) var roots: [RootStat] = []
    @Published private(set) var limits: [PlanLimit] = []
    @Published private(set) var limitError: String? = nil
    @Published private(set) var limitUpdated: Date? = nil
    @Published private(set) var plan: String? = nil
    private var limitsLoading = false
    @Published private(set) var launchAtLogin = false

    /// 開機自動啟動（macOS 13 以上的登入項目）
    func refreshLoginState() {
        launchAtLogin = SMAppService.mainApp.status == .enabled
    }

    func toggleLaunchAtLogin() {
        do {
            if SMAppService.mainApp.status == .enabled {
                try SMAppService.mainApp.unregister()
            } else {
                try SMAppService.mainApp.register()
            }
        } catch {
            NSLog("TokenMeter login item: \(error.localizedDescription)")
        }
        refreshLoginState()
    }

    private(set) var result = ScanResult()
    private let scanner = LogScanner()
    var onUpdate: ((ScanResult) -> Void)?

    private init() {
        refresh()
        // 每 60 秒自動更新
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 60_000_000_000)
                guard let self = self else { return }
                self.refresh()
            }
        }
        refreshLimits(force: true)
        if !UserDefaults.standard.bool(forKey: "didSetupLogin") {
            UserDefaults.standard.set(true, forKey: "didSetupLogin")
            try? SMAppService.mainApp.register()
        }
        refreshLoginState()
        // 方案額度每 5 分鐘查一次，避免太頻繁
        Task { @MainActor [weak self] in
            while true {
                try? await Task.sleep(nanoseconds: 300_000_000_000)
                guard let self = self else { return }
                self.refreshLimits(force: true)
            }
        }
    }

    func refreshLimits(force: Bool = false) {
        if limitsLoading { return }
        if !force, let u = limitUpdated, Date().timeIntervalSince(u) < 90 { return }
        limitsLoading = true
        Task { @MainActor in
            let r = await Task.detached(priority: .utility) { await PlanUsageClient.fetch() }.value
            self.limitsLoading = false
            self.plan = r.plan ?? self.plan
            self.limitError = r.error
            if !r.keepOld { self.limits = r.limits }
            if r.error == nil || !r.keepOld { self.limitUpdated = Date() }
            self.onUpdate?(self.result)
        }
    }

    var limitsPayload: [String: Any] {
        [
            "limits": limits.map { l -> [String: Any] in
                ["id": l.id, "label": l.label, "used": l.used,
                 "resetsAt": (l.resetsAt.map { ($0.timeIntervalSince1970 * 1000).rounded() } as Any?) ?? NSNull()]
            },
            "limitError": (limitError as Any?) ?? NSNull(),
            "limitUpdated": (limitUpdated.map { ($0.timeIntervalSince1970 * 1000).rounded() } as Any?) ?? NSNull(),
            "plan": (plan as Any?) ?? NSNull(),
        ]
    }

    var noLogs: Bool { !roots.isEmpty && !roots.contains { $0.exists && $0.files > 0 } }

    func refresh() {
        if loading { return }
        loading = true
        let scanner = self.scanner
        let cal = Calendar.current
        // 保留 30 天給完整儀表板；系統列面板只看今天／近 7 天
        let since = cal.date(byAdding: .day, value: -30, to: cal.startOfDay(for: Date())) ?? Date()
        Task { @MainActor in
            let r = await Task.detached(priority: .utility) { scanner.scan(since: since) }.value
            self.result = r
            self.roots = r.roots
            self.loading = false
            self.updated = Date()
            self.recompute()
            self.onUpdate?(r)
        }
    }

    func recompute() {
        let cal = Calendar.current
        let today = cal.startOfDay(for: Date())
        let start = span == .today ? today : (cal.date(byAdding: .day, value: -6, to: today) ?? today)
        snap = Analyzer.snapshot(result.sessions, rangeStart: start)
    }

    /// 系統列文字：有方案額度時顯示 5 小時工作階段的使用率，否則顯示今天的 Token 數
    var menuText: String {
        if let s = limits.first { return "\(Int(s.used.rounded()))%" }
        return fmt(snap.todayTotal)
    }

    var warn: Bool {
        if limits.contains(where: { $0.used >= 90 }) { return true }
        guard let a = snap.active, let last = a.steps.last else { return false }
        return Date().timeIntervalSince(a.end) < 1800 && last.ctx > 120_000
    }
}

// MARK: - 完整儀表板視窗

@MainActor
final class DashboardWindow {
    static let shared = DashboardWindow()
    private var window: NSWindow?
    private var web: WKWebView?
    private let bridge = MsgBridge()
    private var ready = false

    func show() {
        if window == nil { build() }
        window?.makeKeyAndOrderFront(nil)
        NSApp.activate(ignoringOtherApps: true)
        push(UsageStore.shared.result)
    }

    private func build() {
        let cfg = WKWebViewConfiguration()
        cfg.userContentController.add(bridge, name: "tm")
        let web = WKWebView(frame: .zero, configuration: cfg)
        self.web = web

        let w = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1240, height: 880),
                         styleMask: [.titled, .closable, .miniaturizable, .resizable],
                         backing: .buffered, defer: false)
        w.title = "Token 用量診斷"
        w.minSize = NSSize(width: 520, height: 480)
        w.isReleasedWhenClosed = false   // 關閉只是隱藏，下次開啟不用重新載入
        w.contentView = web
        w.center()
        w.setFrameAutosaveName("TokenMeterDashboard")
        window = w

        if let url = Self.htmlURL, let html = try? String(contentsOf: url, encoding: .utf8) {
            web.loadHTMLString(Self.wrap(html), baseURL: URL(string: "https://tokenmeter.local/"))
        } else {
            web.loadHTMLString("<p style='font:14px system-ui;padding:24px'>找不到 dashboard.html，請重新執行 install.sh。</p>", baseURL: nil)
        }
        UsageStore.shared.onUpdate = { [weak self] r in self?.push(r) }
    }

    static var htmlURL: URL? {
        if let u = Bundle.main.url(forResource: "dashboard", withExtension: "html") { return u }
        let exe = URL(fileURLWithPath: CommandLine.arguments[0]).deletingLastPathComponent()
        let local = exe.appendingPathComponent("dashboard.html")
        return FileManager.default.fileExists(atPath: local.path) ? local : nil
    }

    /// dashboard.html 是頁面片段（發佈到 claude.ai 時會自動補上外框），這裡補上完整外框
    static func wrap(_ body: String) -> String {
        """
        <!doctype html><html><head><meta charset="utf-8">
        <meta name="viewport" content="width=device-width,initial-scale=1">
        <style>[hidden]{display:none!important}img{max-width:100%}</style>
        </head><body>\(body)</body></html>
        """
    }

    func push(_ r: ScanResult) {
        guard ready, let web = web, window?.isVisible == true else { return }
        web.evaluateJavaScript("window.tmLoad(" + Export.json(r, extra: UsageStore.shared.limitsPayload) + ")", completionHandler: nil)
    }

    func handle(ready isReady: Bool, refresh: Bool, reveal: String?) {
        if isReady {
            ready = true
            push(UsageStore.shared.result)
        }
        if refresh { UsageStore.shared.refresh(); UsageStore.shared.refreshLimits() }
        if let p = reveal, !p.isEmpty {
            let full = (p as NSString).expandingTildeInPath
            NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: full)
        }
    }
}

/// 接收網頁送來的訊息（重新掃描、在 Finder 顯示）
final class MsgBridge: NSObject, WKScriptMessageHandler {
    func userContentController(_ uc: WKUserContentController, didReceive message: WKScriptMessage) {
        let body = message.body as? [String: Any] ?? [:]
        let isReady = body["ready"] != nil
        let refresh = body["refresh"] != nil
        let reveal = body["reveal"] as? String
        Task { @MainActor in
            DashboardWindow.shared.handle(ready: isReady, refresh: refresh, reveal: reveal)
        }
    }
}

// MARK: - 系統列介面

extension Color {
    init(hex: UInt32) {
        self.init(red: Double((hex >> 16) & 0xFF) / 255,
                  green: Double((hex >> 8) & 0xFF) / 255,
                  blue: Double(hex & 0xFF) / 255)
    }
}

enum Pal {
    static let cacheRead = Color(hex: 0x3987E5)
    static let cacheWrite = Color(hex: 0xD95926)
    static let input = Color(hex: 0x199E70)
    static let output = Color(hex: 0xC98500)
    static let crit = Color(hex: 0xD03B3B)
    static let warn = Color(hex: 0xE09A00)
}

@main
struct TokenMeterApp: App {
    @ObservedObject private var store = UsageStore.shared

    var body: some Scene {
        MenuBarExtra {
            ContentView().environmentObject(store)
        } label: {
            MenuLabel(store: store)
        }
        .menuBarExtraStyle(.window)
    }
}

struct MenuLabel: View {
    @ObservedObject var store: UsageStore
    var body: some View {
        HStack(spacing: 3) {
            Image(systemName: store.warn ? "exclamationmark.triangle.fill" : "gauge.with.dots.needle.50percent")
            Text(store.menuText).monospacedDigit()
        }
    }
}

struct ContentView: View {
    @EnvironmentObject var store: UsageStore

    var body: some View {
        VStack(alignment: .leading, spacing: 14) {
            header
            if store.noLogs {
                Text("這台 Mac 上還沒有找到含用量的 Claude 記錄。使用 Claude Code 或桌面版的 Code／Cowork 之後就會出現。")
                    .font(.callout).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else {
                LimitsView(limits: store.limits, error: store.limitError, plan: store.plan)
                Divider()
                totals
                CompositionBar(s: store.snap)
                if !store.snap.byModel.isEmpty { SourceList(title: "依模型", items: store.snap.byModel, color: Pal.cacheRead) }
                if store.snap.bySource.count > 1 { SourceList(title: "依來源", items: store.snap.bySource, color: Pal.cacheWrite) }
                WeekChart(days: store.snap.daily)
                if let a = store.snap.active { ActiveCard(session: a) }
                issueList
            }
            Divider()
            footer
        }
        .padding(16)
        .frame(width: 380)
        .onAppear { store.refresh(); store.refreshLimits() }
    }

    private var header: some View {
        HStack {
            Text("Token 用量").font(.headline)
            Spacer()
            Picker("範圍", selection: $store.span) {
                ForEach(UsageStore.Span.allCases) { Text($0.rawValue).tag($0) }
            }
            .pickerStyle(.segmented)
            .labelsHidden()
            .frame(width: 150)
            Button { store.refresh() } label: {
                Image(systemName: store.loading ? "hourglass" : "arrow.clockwise")
            }
            .buttonStyle(.borderless)
            .help("重新整理")
        }
    }

    private var totals: some View {
        let s = store.snap
        return HStack(alignment: .firstTextBaseline) {
            VStack(alignment: .leading, spacing: 2) {
                Text(fmt(s.total)).font(.system(size: 28, weight: .semibold, design: .monospaced))
                Text("總 Token · \(s.sessions) 個對話 · \(s.steps) 次呼叫")
                    .font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            VStack(alignment: .trailing, spacing: 2) {
                Text(fmt(s.weighted)).font(.system(size: 15, weight: .medium, design: .monospaced))
                Text("約當輸入量").font(.caption).foregroundStyle(.secondary)
            }
            VStack(alignment: .trailing, spacing: 2) {
                Text(s.total == 0 ? "—" : pct(s.hit)).font(.system(size: 15, weight: .medium, design: .monospaced))
                    .foregroundStyle(s.hit >= 0.85 || s.total == 0 ? Color.primary : Pal.warn)
                Text("快取命中").font(.caption).foregroundStyle(.secondary)
            }
        }
    }

    private var issueList: some View {
        VStack(alignment: .leading, spacing: 8) {
            Text("可以改善的地方").font(.caption).foregroundStyle(.secondary)
            if store.snap.issues.isEmpty {
                Text(store.loading ? "分析中…" : "這段期間沒有明顯的過度使用。")
                    .font(.callout).foregroundStyle(.secondary)
            } else {
                ScrollView {
                    VStack(alignment: .leading, spacing: 12) {
                        ForEach(store.snap.issues) { IssueRow(issue: $0) }
                    }
                    .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 200)
            }
        }
    }

    private var footer: some View {
        HStack(spacing: 12) {
            if let u = store.updated {
                Text("更新於 \(u.formatted(date: .omitted, time: .shortened))")
                    .font(.caption2).foregroundStyle(.secondary)
            }
            Spacer()
            Button("完整儀表板") { DashboardWindow.shared.show() }
                .buttonStyle(.borderedProminent)
                .controlSize(.small)
            Button(store.launchAtLogin ? "✓ 開機啟動" : "開機啟動") { store.toggleLaunchAtLogin() }
                .buttonStyle(.borderless)
                .help("登入 Mac 時自動開啟 TokenMeter")
            Button("結束") { NSApp.terminate(nil) }
                .buttonStyle(.borderless)
        }
        .font(.caption)
    }
}

struct SourceList: View {
    let title: String
    let items: [SourceTotal]
    let color: Color
    var body: some View {
        let mx = max(1, items.first?.total ?? 1)
        return VStack(alignment: .leading, spacing: 5) {
            Text(title).font(.caption).foregroundStyle(.secondary)
            ForEach(items) { it in
                HStack(spacing: 8) {
                    Text(it.name).font(.caption).lineLimit(1).frame(width: 150, alignment: .leading)
                    GeometryReader { g in
                        RoundedRectangle(cornerRadius: 2)
                            .fill(color)
                            .frame(width: max(2, g.size.width * CGFloat(it.total) / CGFloat(mx)))
                    }
                    .frame(height: 8)
                    Text(fmt(it.total)).font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                        .frame(width: 48, alignment: .trailing)
                }
            }
        }
    }
}

struct LimitsView: View {
    let limits: [PlanLimit]
    let error: String?
    let plan: String?

    private func color(_ u: Double) -> Color { u >= 90 ? Pal.crit : (u >= 70 ? Pal.warn : Pal.input) }

    var body: some View {
        VStack(alignment: .leading, spacing: 8) {
            HStack {
                Text("方案額度").font(.caption).foregroundStyle(.secondary)
                if let p = plan {
                    Text(p).font(.caption2.weight(.semibold))
                        .padding(.horizontal, 6).padding(.vertical, 1)
                        .background(Capsule().stroke(Color.secondary.opacity(0.5)))
                }
                Spacer()
            }
            ForEach(limits) { l in
                VStack(alignment: .leading, spacing: 3) {
                    HStack(alignment: .firstTextBaseline) {
                        Text(l.label).font(.callout)
                        Spacer()
                        Text("剩 \(Int(l.remaining.rounded()))%")
                            .font(.system(size: 14, weight: .semibold, design: .monospaced))
                            .foregroundStyle(l.used >= 70 ? color(l.used) : Color.primary)
                    }
                    ProgressView(value: min(l.used, 100), total: 100).tint(color(l.used))
                    Text("已用 \(Int(l.used.rounded()))%　\(resetText(l.resetsAt))")
                        .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            if let e = error {
                Text(e).font(.caption).foregroundStyle(limits.isEmpty ? Pal.warn : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            } else if limits.isEmpty {
                Text("查詢中…").font(.caption).foregroundStyle(.secondary)
            }
        }
    }
}

struct CompositionBar: View {
    let s: Snapshot

    private var parts: [(label: String, value: Int, color: Color)] {
        [("快取讀取", s.cr, Pal.cacheRead), ("快取寫入", s.cw, Pal.cacheWrite),
         ("輸入", s.inp, Pal.input), ("輸出", s.out, Pal.output)]
    }

    var body: some View {
        let ps = parts
        let total = max(1, s.total)
        return VStack(alignment: .leading, spacing: 6) {
            GeometryReader { g in
                HStack(spacing: 2) {
                    ForEach(0..<ps.count, id: \.self) { i in
                        if ps[i].value > 0 {
                            Rectangle().fill(ps[i].color)
                                .frame(width: max(2, (g.size.width - 6) * CGFloat(ps[i].value) / CGFloat(total)))
                        }
                    }
                    Spacer(minLength: 0)
                }
            }
            .frame(height: 10)
            .background(Color.primary.opacity(0.06))
            .clipShape(RoundedRectangle(cornerRadius: 3))
            HStack(spacing: 10) {
                ForEach(0..<ps.count, id: \.self) { i in
                    HStack(spacing: 4) {
                        Circle().fill(ps[i].color).frame(width: 7, height: 7)
                        Text("\(ps[i].label) \(fmt(ps[i].value))")
                            .font(.caption2.monospacedDigit()).foregroundStyle(.secondary)
                    }
                }
            }
        }
    }
}

struct WeekChart: View {
    let days: [DayTotal]

    static let md: DateFormatter = {
        let f = DateFormatter(); f.dateFormat = "M/d"; return f
    }()
    static let wd: DateFormatter = {
        let f = DateFormatter(); f.locale = Locale(identifier: "zh_TW"); f.dateFormat = "EEEEE"; return f
    }()

    var body: some View {
        let mx = max(1, days.map { $0.total }.max() ?? 1)
        return VStack(alignment: .leading, spacing: 4) {
            HStack {
                Text("近 7 天每日用量").font(.caption).foregroundStyle(.secondary)
                Spacer()
                if let today = days.last {
                    Text("今天 \(fmt(today.total))").font(.caption.monospacedDigit())
                }
            }
            HStack(alignment: .bottom, spacing: 6) {
                ForEach(0..<days.count, id: \.self) { i in
                    VStack(spacing: 3) {
                        Spacer(minLength: 0)
                        RoundedRectangle(cornerRadius: 3)
                            .fill(i == days.count - 1 ? Pal.cacheRead : Pal.cacheRead.opacity(0.5))
                            .frame(height: max(2, 44 * CGFloat(days[i].total) / CGFloat(mx)))
                        Text(Self.wd.string(from: days[i].day))
                            .font(.system(size: 9)).foregroundStyle(.secondary)
                    }
                    .frame(maxWidth: .infinity)
                    .contentShape(Rectangle())
                    .help("\(Self.md.string(from: days[i].day))：\(fmt(days[i].total)) Token")
                }
            }
            .frame(height: 64)
        }
    }
}

struct ActiveCard: View {
    let session: Session

    var body: some View {
        let ctx = session.steps.last?.ctx ?? 0
        let idle = Date().timeIntervalSince(session.end) / 60
        let live = idle < 30
        let barColor = ctx > 120_000 ? Pal.crit : (ctx > 80_000 ? Pal.warn : Pal.cacheRead)
        return VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 6) {
                Circle().fill(live ? Color.green : Color.secondary).frame(width: 7, height: 7)
                Text(live ? "進行中" : "最近的對話").font(.caption).foregroundStyle(.secondary)
                Text(session.project).font(.callout.weight(.semibold)).lineLimit(1)
                Spacer()
                Text("\(session.steps.count) 步").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
            }
            Text(session.source).font(.caption2).foregroundStyle(.secondary)
            if let r = session.rounds.last, r.first >= 0, r.last < session.steps.count {
                let st = session.steps[r.first...r.last]
                let tot = st.reduce(0) { $0 + $1.total }
                let res = st.reduce(0) { $0 + $1.resultOut }
                VStack(alignment: .leading, spacing: 2) {
                    Text("最近一回合：\(r.prompt)").font(.caption).lineLimit(2)
                    Text("\(fmt(tot))　過程 \(fmt(tot - res)) · 結果 \(fmt(res)) · \(st.count) 次呼叫")
                        .font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
            }
            ProgressView(value: Double(min(ctx, 200_000)), total: 200_000)
                .tint(barColor)
            HStack {
                Text("目前脈絡 \(fmt(ctx))").font(.caption.monospacedDigit())
                Spacer()
                Text("以 200k 為基準").font(.caption2).foregroundStyle(.tertiary)
            }
            if let tip = advice(ctx: ctx, idle: idle) {
                Text(tip)
                    .font(.caption)
                    .foregroundStyle(ctx > 120_000 ? Pal.crit : Color.secondary)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(10)
        .background(RoundedRectangle(cornerRadius: 8).fill(Color.primary.opacity(0.05)))
    }

    private func advice(ctx: Int, idle: Double) -> String? {
        if ctx > 120_000 {
            return "脈絡已經很長，每一步都在重送整段歷史。完成這個段落後執行 /compact，換任務就 /clear。"
        }
        if idle > 5 && idle < 720 && ctx > 50_000 {
            return "已閒置 \(Int(idle)) 分鐘，快取已過期。回來時先 /compact 再繼續會比較便宜。"
        }
        return nil
    }
}

struct IssueRow: View {
    let issue: Issue

    private var color: Color { issue.sev == 2 ? Pal.crit : (issue.sev == 1 ? Pal.warn : Pal.cacheRead) }
    private var sevText: String { issue.sev == 2 ? "優先" : (issue.sev == 1 ? "建議" : "小幅") }

    var body: some View {
        HStack(alignment: .top, spacing: 8) {
            RoundedRectangle(cornerRadius: 1.5).fill(color).frame(width: 3)
            VStack(alignment: .leading, spacing: 3) {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Text(sevText).font(.caption2.weight(.bold)).foregroundStyle(color)
                    Text(issue.title).font(.callout.weight(.semibold))
                    Spacer()
                    Text("≈\(fmt(issue.impact))").font(.caption.monospacedDigit()).foregroundStyle(.secondary)
                }
                if !issue.detail.isEmpty {
                    Text(issue.detail).font(.caption).foregroundStyle(.secondary)
                        .lineLimit(3).fixedSize(horizontal: false, vertical: true)
                }
                Text(issue.fix).font(.caption).fixedSize(horizontal: false, vertical: true)
            }
        }
        .fixedSize(horizontal: false, vertical: true)
    }
}
