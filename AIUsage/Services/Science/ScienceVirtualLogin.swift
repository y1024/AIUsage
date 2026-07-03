import Foundation
import CryptoKit
import os.log

// MARK: - Science Virtual Login (本地虚拟 OAuth 伪造器)
// 在独立 data-dir 的 auth_dir 里写一套本地自造、绝不联网的登录凭证，让 Claude Science 认为已登录
// （aiusage@cslocal.invalid），推理经 ANTHROPIC_BASE_URL 导去本项目复用的 QuotaServer 代理。
// 全程零 Anthropic 接触、零真实凭证。
//
// 令牌字节格式（node/rust/swift 三方对拍钉死）：
//   - 令牌文件 `<auth_dir>/.oauth-tokens/<account_uuid>.enc`（目录里恰好一个 .enc）
//   - 内容 v2 格式：`"v2:" + base64( IV(12) ‖ AES-256-GCM(密文) ‖ authTag(16) )`
//     derivedKey = HKDF-SHA256(ikm=base64Decode(OAUTH_ENCRYPTION_KEY), salt=空, info="operon:aes-256-gcm:oauth", 32)
//     AAD = "v2:oauth"；明文 = JSON(tokenBlob)
//   - `encryption.key`：换行分隔 `KEY=base64(≥16B)`；过期设远期 → 绝不触发联网刷新
//   - `active-org.json`：`{ "org_uuid": ... }`（Science 只校验 org_uuid 是合法 UUID）
//
// 铁律护栏：**绝不写真实凭证目录**（唯一致命的就是误写真实 `~/.claude-science`）；
// 另加假账号（email 必须以 `.invalid` 保留顶级域结尾）、写前拒符号链接、O_EXCL 临时文件 + rename + 0600。

private let forgeLog = Logger(subsystem: "com.aiusage.desktop", category: "ScienceVirtualLogin")

enum ScienceLoginAction: Equatable {
    case reused    // 现有登录完整自洽，原样复用，未写任何文件
    case repaired  // 部分损坏，重写但沿用原 org（旧对话不丢）
    case created   // 真首次，铸全新 org
}

struct ScienceForgeResult: Equatable {
    let authDir: String
    let accountUUID: String
    let orgUUID: String
    let encFile: String
    let action: ScienceLoginAction
}

enum ScienceLoginError: LocalizedError {
    case refusedRealCredDir(String)
    case refusedOutsideSandbox(String, String)
    case refusedEmail(String)
    case refusedSymlink(String)
    case cryptoFailed(String)
    case io(String)
    case ambiguousMultiOrg(String)

    var errorDescription: String? {
        switch self {
        case .refusedRealCredDir(let p):
            return AppSettings.shared.t(
                "Refused: the sandbox auth directory resolves inside the real Claude Science directory (\(p)); this is forbidden by the safety rules.",
                "拒绝：沙箱 auth 目录解析到真实 Claude Science 目录（\(p)）之内，铁律禁止触碰。"
            )
        case .refusedOutsideSandbox(let resolved, let root):
            return AppSettings.shared.t(
                "Refused: the auth directory resolves outside the sandbox root (\(resolved) is not under \(root)); a symlink redirect is suspected.",
                "拒绝：auth 目录解析到沙箱根之外（\(resolved) 不在 \(root) 下），疑似符号链接重定向。"
            )
        case .refusedEmail(let email):
            return AppSettings.shared.t(
                "Refused: the email must end with .invalid (got \(email)) to guarantee a non-routable fake account.",
                "拒绝：email 必须以 .invalid 结尾（当前 \(email)），确保是不可路由的假账号。"
            )
        case .refusedSymlink(let p):
            return AppSettings.shared.t("Refused: \(p) is a symlink and will never be followed for writes.", "拒绝：\(p) 是符号链接，绝不跟随写入。")
        case .cryptoFailed(let m):
            return AppSettings.shared.t("Virtual login crypto failed: \(m)", "虚拟登录加解密失败：\(m)")
        case .io(let m):
            return AppSettings.shared.t("Virtual login file I/O failed: \(m)", "虚拟登录文件写入失败：\(m)")
        case .ambiguousMultiOrg(let dir):
            return AppSettings.shared.t(
                "Multiple historical organizations found but the active one can't be determined; aborted to avoid orphaning old conversations. Data is under \(dir)/orgs/.",
                "检测到多个历史组织但无法确定活动组织，为避免旧对话被孤儿化已中止。数据在 \(dir)/orgs/。"
            )
        }
    }
}

// MARK: - Forge

/// 纯逻辑的虚拟登录伪造器；无 UI / 无全局状态依赖，便于复用与推理。
enum ScienceVirtualLogin {
    private static let keyNames = [
        "ANTHROPIC_API_KEY_ENCRYPTION_KEY",
        "OAUTH_ENCRYPTION_KEY",
        "JWT_SIGNING_SECRET",
        "USER_SECRET_ENCRYPTION_KEY",
    ]
    private static let hkdfInfo = Data("operon:aes-256-gcm:oauth".utf8)
    private static let aad = Data("v2:oauth".utf8)

    /// 幂等虚拟登录：完整自洽→复用；部分损坏→修复但保 org；真首次→铸新。
    /// - Parameters:
    ///   - authDir: 目标 auth 目录（= 独立 data-dir HOME/.claude-science）。
    ///   - email: 假账号邮箱（必须以 `.invalid` 保留顶级域结尾）。
    ///   - sandboxRoot: 隔离根（auth_dir 必须解析在其之下，挡符号链接重定向）。
    static func ensure(authDir: String, email: String, sandboxRoot: String) throws -> ScienceForgeResult {
        let realCredDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-science")
        let resolved = try resolveGuarded(authDir: authDir, email: email, sandboxRoot: sandboxRoot, realCredDir: realCredDir)

        // 完整自洽 → 原样复用，不碰任何文件（Science 可能正在读）。
        if let intact = readIntactLogin(resolved: resolved, email: email) {
            forgeLog.info("Virtual login intact; reusing")
            return ScienceForgeResult(authDir: resolved, accountUUID: intact.account, orgUUID: intact.org, encFile: intact.enc, action: .reused)
        }

        // 组织来源优先级（绝不静默新铸）：active-org.json → 可解 token → orgs/ 目录。
        let priorOrg: String?
        let action: ScienceLoginAction
        if let o = readActiveOrg(resolved) {
            priorOrg = o; action = .repaired
        } else if let o = readTokenOrg(resolved) {
            priorOrg = o; action = .repaired
        } else {
            let dirs = scanOrgDirs(resolved)
            switch dirs.count {
            case 0: priorOrg = nil; action = .created
            case 1: priorOrg = dirs[0]; action = .repaired
            default: throw ScienceLoginError.ambiguousMultiOrg(resolved)
            }
        }
        let priorAccount = readPriorAccount(resolved)
        let written = try writeLogin(resolved: resolved, email: email, preferOrg: priorOrg, preferAccount: priorAccount)
        forgeLog.info("Virtual login written (action=\(String(describing: action), privacy: .public))")
        return ScienceForgeResult(authDir: resolved, accountUUID: written.account, orgUUID: written.org, encFile: written.enc, action: action)
    }

    /// 只读判定：沙箱里的虚拟登录当前是否「完整自洽」（可直接复用）。绝不写任何文件。
    static func isIntact(authDir: String, email: String, sandboxRoot: String) -> Bool {
        let realCredDir = (NSHomeDirectory() as NSString).appendingPathComponent(".claude-science")
        guard let resolved = try? resolveGuarded(authDir: authDir, email: email, sandboxRoot: sandboxRoot, realCredDir: realCredDir) else {
            return false
        }
        return readIntactLogin(resolved: resolved, email: email) != nil
    }

    // MARK: - v2 GCM（与 oauth_forge.rs 的 encrypt_token_v2 / decrypt_token_v2 字节一致）

    private static func deriveKey(oauthKeyB64: String) throws -> SymmetricKey {
        guard let ikm = Data(base64Encoded: oauthKeyB64.trimmingCharacters(in: .whitespacesAndNewlines)) else {
            throw ScienceLoginError.cryptoFailed("OAUTH_ENCRYPTION_KEY 非法 base64")
        }
        // salt 空（= Node hkdfSync 的 Buffer.alloc(0)）。
        return HKDF<SHA256>.deriveKey(
            inputKeyMaterial: SymmetricKey(data: ikm),
            salt: Data(),
            info: hkdfInfo,
            outputByteCount: 32
        )
    }

    /// 加密：返回 `"v2:" + base64(IV ‖ 密文 ‖ tag)`。
    static func encryptTokenV2(_ plaintext: Data, oauthKeyB64: String) throws -> String {
        let key = try deriveKey(oauthKeyB64: oauthKeyB64)
        let iv = try randomBytes(12)
        do {
            let nonce = try AES.GCM.Nonce(data: iv)
            let sealed = try AES.GCM.seal(plaintext, using: key, nonce: nonce, authenticating: aad)
            var framed = iv
            framed.append(sealed.ciphertext)
            framed.append(sealed.tag)
            return "v2:" + framed.base64EncodedString()
        } catch {
            throw ScienceLoginError.cryptoFailed("aes-gcm 加密失败：\(error.localizedDescription)")
        }
    }

    /// 解密 `"v2:..."`，校验 tag；失败（含篡改/密钥不符）抛错。
    static func decryptTokenV2(_ body: String, oauthKeyB64: String) throws -> Data {
        guard body.hasPrefix("v2:"), let raw = Data(base64Encoded: String(body.dropFirst(3))) else {
            throw ScienceLoginError.cryptoFailed("缺 v2: 前缀或体非法 base64")
        }
        guard raw.count >= 12 + 16 else { throw ScienceLoginError.cryptoFailed("v2 密文过短") }
        let iv = raw.prefix(12)
        let rest = raw.dropFirst(12)
        let tag = rest.suffix(16)
        let ct = rest.dropLast(16)
        let key = try deriveKey(oauthKeyB64: oauthKeyB64)
        do {
            let box = try AES.GCM.SealedBox(nonce: try AES.GCM.Nonce(data: iv), ciphertext: ct, tag: tag)
            return try AES.GCM.open(box, using: key, authenticating: aad)
        } catch {
            throw ScienceLoginError.cryptoFailed("aes-gcm 解密/验签失败")
        }
    }

    // MARK: - 写入一套虚拟登录

    private struct WrittenLogin { let account: String; let org: String; let enc: String }

    private static func writeLogin(resolved: String, email: String, preferOrg: String?, preferAccount: String?) throws -> WrittenLogin {
        try createDir(resolved, mode: 0o700)

        // —— encryption.key：复用已存在的（保持旧 .enc 可解），否则新造 ——
        let keyFile = (resolved as NSString).appendingPathComponent("encryption.key")
        try assertNotSymlink(keyFile)
        var keys: [String: String] = [:]
        if FileManager.default.fileExists(atPath: keyFile),
           let txt = try? String(contentsOfFile: keyFile, encoding: .utf8) {
            for line in txt.split(separator: "\n") {
                guard let eq = line.firstIndex(of: "=") else { continue }
                let k = String(line[..<eq]).trimmingCharacters(in: .whitespaces)
                let v = String(line[line.index(after: eq)...]).trimmingCharacters(in: .whitespaces)
                if !k.isEmpty, !v.isEmpty { keys[k] = v }
            }
        }
        // 复用的 OAUTH_ENCRYPTION_KEY 必须能 base64 解出 ≥16 字节，否则丢弃重造。
        let oauthUsable = keys["OAUTH_ENCRYPTION_KEY"].flatMap { Data(base64Encoded: $0.trimmingCharacters(in: .whitespaces)) }.map { $0.count >= 16 } ?? false
        if !oauthUsable { keys.removeValue(forKey: "OAUTH_ENCRYPTION_KEY") }
        for k in keyNames where keys[k] == nil {
            keys[k] = try randomBytes(32).base64EncodedString()
        }
        let keyBlob = keyNames.map { "\($0)=\(keys[$0] ?? "")" }.joined(separator: "\n") + "\n"
        try safeWrite(keyFile, Data(keyBlob.utf8), mode: 0o600)

        // —— 令牌 blob（字段对齐 Science 的 _tryOauthToken）——
        let accountUUID = preferAccount ?? uuidV4()
        let orgUUID = preferOrg ?? uuidV4()
        let access = "sk-ant-virtual-" + (try randomBytes(24).map { String(format: "%02x", $0) }.joined())
        let blob: [String: Any] = [
            "access_token": access,     // 代理会剥离，值任意
            "refresh_token": "",
            "api_key": NSNull(),
            "token_expires_at": "2099-01-01T00:00:00.000Z", // 远期 → 绝不联网刷新
            "provider": "claude_ai",
            "scopes": "user:inference user:file_upload user:profile user:mcp_servers user:plugins",
            "email": email,
            "account_uuid": accountUUID,
            "subscription_type": "max",
            "rate_limit_tier": NSNull(),
            "seat_tier": NSNull(),
            "org_uuid": orgUUID,
            "billing_type": NSNull(),
            "has_extra_usage_enabled": false,
        ]
        let plaintext: Data
        do {
            plaintext = try JSONSerialization.data(withJSONObject: blob, options: [])
        } catch {
            throw ScienceLoginError.cryptoFailed("序列化 token blob 失败")
        }
        guard let oauthKey = keys["OAUTH_ENCRYPTION_KEY"] else {
            throw ScienceLoginError.cryptoFailed("缺 OAUTH_ENCRYPTION_KEY")
        }
        let encBody = try encryptTokenV2(plaintext, oauthKeyB64: oauthKey)

        // —— 写 .oauth-tokens/<account>.enc；先清其它 .enc 保证唯一 ——
        let tokDir = (resolved as NSString).appendingPathComponent(".oauth-tokens")
        try assertNotSymlink(tokDir)
        try createDir(tokDir, mode: 0o700)
        if let entries = try? FileManager.default.contentsOfDirectory(atPath: tokDir) {
            for name in entries where (name as NSString).pathExtension == "enc" {
                let p = (tokDir as NSString).appendingPathComponent(name)
                try assertNotSymlink(p)
                do {
                    try FileManager.default.removeItem(atPath: p)
                } catch {
                    throw ScienceLoginError.io("删除旧令牌 \(p) 失败（需目录内恰好一个 .enc）")
                }
            }
        }
        let userId = String(accountUUID.unicodeScalars.filter { CharacterSet.alphanumerics.contains($0) || $0 == "_" || $0 == "-" })
        let encFile = (tokDir as NSString).appendingPathComponent("\(userId).enc")
        try safeWrite(encFile, Data(encBody.utf8), mode: 0o600)

        // —— 自校验：用同样逻辑解密回读 ——
        let roundtrip = try decryptTokenV2(encBody, oauthKeyB64: oauthKey)
        guard let rt = try? JSONSerialization.jsonObject(with: roundtrip) as? [String: Any],
              rt["email"] as? String == email else {
            throw ScienceLoginError.cryptoFailed("自校验失败：解密回读的 email 不符")
        }

        // —— active-org.json ——
        let orgJSONData = try JSONSerialization.data(withJSONObject: ["org_uuid": orgUUID], options: [.prettyPrinted])
        var orgOut = orgJSONData
        orgOut.append(0x0A) // 末尾换行，与 rust 一致
        try safeWrite((resolved as NSString).appendingPathComponent("active-org.json"), orgOut, mode: 0o600)

        return WrittenLogin(account: accountUUID, org: orgUUID, enc: encFile)
    }

    // MARK: - 幂等读取/校验

    private struct IntactLogin { let account: String; let org: String; let enc: String }

    private static func readIntactLogin(resolved: String, email: String) -> IntactLogin? {
        let keyFile = (resolved as NSString).appendingPathComponent("encryption.key")
        let tokDir = (resolved as NSString).appendingPathComponent(".oauth-tokens")
        let activeOrgFile = (resolved as NSString).appendingPathComponent("active-org.json")
        if isSymlink(keyFile) || isSymlink(tokDir) || isSymlink(activeOrgFile) { return nil }
        guard let key = parseOAuthKey(resolved),
              let enc = singleEnc(resolved), !isSymlink(enc),
              let activeOrg = readActiveOrg(resolved),
              let body = try? String(contentsOfFile: enc, encoding: .utf8),
              let plaintext = try? decryptTokenV2(body, oauthKeyB64: key),
              let blob = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any] else {
            return nil
        }
        let blobOrg = blob["org_uuid"] as? String
        let blobEmail = blob["email"] as? String
        let account = blob["account_uuid"] as? String
        let providerOK = (blob["provider"] as? String) == "claude_ai"
        let accessOK = (blob["access_token"] as? String).map { !$0.isEmpty } ?? false
        let expiryOK = (blob["token_expires_at"] as? String).map(tokenNotExpired) ?? false
        guard blobOrg == activeOrg,
              blobEmail == email,
              (blobEmail?.hasSuffix(".invalid") ?? false),
              let account, looksLikeUUID(account),
              providerOK, accessOK, expiryOK else {
            return nil
        }
        return IntactLogin(account: account, org: activeOrg, enc: enc)
    }

    private static func parseOAuthKey(_ resolved: String) -> String? {
        guard let txt = try? String(contentsOfFile: (resolved as NSString).appendingPathComponent("encryption.key"), encoding: .utf8) else { return nil }
        for line in txt.split(separator: "\n") {
            if line.hasPrefix("OAUTH_ENCRYPTION_KEY=") {
                let v = line.dropFirst("OAUTH_ENCRYPTION_KEY=".count).trimmingCharacters(in: .whitespaces)
                return v.isEmpty ? nil : v
            }
        }
        return nil
    }

    /// `.oauth-tokens/` 下恰好一个 `.enc` 才返回其路径；零个或多于一个都返回 nil。
    private static func singleEnc(_ resolved: String) -> String? {
        let tokDir = (resolved as NSString).appendingPathComponent(".oauth-tokens")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: tokDir) else { return nil }
        let encs = entries.filter { ($0 as NSString).pathExtension == "enc" }
        guard encs.count == 1 else { return nil }
        return (tokDir as NSString).appendingPathComponent(encs[0])
    }

    private static func readActiveOrg(_ resolved: String) -> String? {
        guard let data = FileManager.default.contents(atPath: (resolved as NSString).appendingPathComponent("active-org.json")),
              let obj = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
              let o = obj["org_uuid"] as? String, looksLikeUUID(o) else { return nil }
        return o
    }

    private static func readPriorAccount(_ resolved: String) -> String? {
        guard let key = parseOAuthKey(resolved), let enc = singleEnc(resolved),
              let body = try? String(contentsOfFile: enc, encoding: .utf8),
              let plaintext = try? decryptTokenV2(body, oauthKeyB64: key),
              let blob = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let a = blob["account_uuid"] as? String, looksLikeUUID(a) else { return nil }
        return a
    }

    private static func readTokenOrg(_ resolved: String) -> String? {
        guard let key = parseOAuthKey(resolved), let enc = singleEnc(resolved),
              let body = try? String(contentsOfFile: enc, encoding: .utf8),
              let plaintext = try? decryptTokenV2(body, oauthKeyB64: key),
              let blob = try? JSONSerialization.jsonObject(with: plaintext) as? [String: Any],
              let o = blob["org_uuid"] as? String, looksLikeUUID(o) else { return nil }
        return o
    }

    private static func scanOrgDirs(_ resolved: String) -> [String] {
        let orgsDir = (resolved as NSString).appendingPathComponent("orgs")
        guard let entries = try? FileManager.default.contentsOfDirectory(atPath: orgsDir) else { return [] }
        return entries.filter { name in
            var isDir: ObjCBool = false
            let full = (orgsDir as NSString).appendingPathComponent(name)
            return FileManager.default.fileExists(atPath: full, isDirectory: &isDir) && isDir.boolValue && looksLikeUUID(name)
        }
    }

    // MARK: - 护栏（写任何东西之前）

    private static func resolveGuarded(authDir: String, email: String, sandboxRoot: String, realCredDir: String) throws -> String {
        let resolved = realAncestor(authDir)
        // 护栏 0（铁律最高优先）：绝不落在真实 ~/.claude-science 之内或其本身。
        let realRoot = realAncestor(realCredDir)
        if resolved == realRoot || resolved.hasPrefix(realRoot + "/") {
            throw ScienceLoginError.refusedRealCredDir(realRoot)
        }
        // 护栏 1：resolved 必须落在沙箱根之下（挡住符号链接重定向）。
        let root = realAncestor(sandboxRoot)
        if resolved != root && !resolved.hasPrefix(root + "/") {
            throw ScienceLoginError.refusedOutsideSandbox(resolved, root)
        }
        // 护栏 2：假账号——必须落在 RFC 2606 保留顶级域 `.invalid`（永不可解析）。
        guard email.hasSuffix(".invalid") else {
            throw ScienceLoginError.refusedEmail(email)
        }
        return resolved
    }

    /// 逐层向上找到最近的已存在祖先并 canonicalize（看穿符号链接），再把不存在的尾巴拼回。
    private static func realAncestor(_ path: String) -> String {
        var cur = (path as NSString).standardizingPath
        var tail: [String] = []
        while !FileManager.default.fileExists(atPath: cur) {
            let name = (cur as NSString).lastPathComponent
            let parent = (cur as NSString).deletingLastPathComponent
            if parent == cur || parent.isEmpty { break }
            tail.append(name)
            cur = parent
        }
        // resolvingSymlinksInPath 会解析已存在部分的符号链接。
        var base = URL(fileURLWithPath: cur).resolvingSymlinksInPath().path
        for name in tail.reversed() {
            base = (base as NSString).appendingPathComponent(name)
        }
        return base
    }

    // MARK: - 安全文件写入

    private static func isSymlink(_ path: String) -> Bool {
        (try? FileManager.default.attributesOfItem(atPath: path)[.type] as? FileAttributeType) == .typeSymbolicLink
    }

    private static func assertNotSymlink(_ path: String) throws {
        if isSymlink(path) { throw ScienceLoginError.refusedSymlink(path) }
    }

    private static func createDir(_ path: String, mode: Int) throws {
        do {
            try FileManager.default.createDirectory(atPath: path, withIntermediateDirectories: true, attributes: [.posixPermissions: mode])
        } catch {
            // 已存在时 createDirectory 会抛错；仅在确实不存在时算失败。
            if !FileManager.default.fileExists(atPath: path) {
                throw ScienceLoginError.io("建目录 \(path) 失败：\(error.localizedDescription)")
            }
        }
    }

    /// 安全写：拒符号链接 + O_EXCL|O_NOFOLLOW 临时文件 + rename + chmod，避免跟随/竞态写到非预期目标。
    private static func safeWrite(_ path: String, _ data: Data, mode: mode_t) throws {
        try assertNotSymlink(path)
        let dir = (path as NSString).deletingLastPathComponent
        let suffix = (try randomBytes(6)).map { String(format: "%02x", $0) }.joined()
        let tmp = (dir as NSString).appendingPathComponent(".tmp-\(suffix)")
        let fd = open(tmp, O_WRONLY | O_CREAT | O_EXCL | O_NOFOLLOW, mode)
        guard fd >= 0 else { throw ScienceLoginError.io("建临时文件失败：\(String(cString: strerror(errno)))") }
        var wrote = 0
        let ok: Bool = data.withUnsafeBytes { raw -> Bool in
            guard let base = raw.baseAddress else { return data.isEmpty }
            while wrote < data.count {
                let n = write(fd, base + wrote, data.count - wrote)
                if n <= 0 { return false }
                wrote += n
            }
            return true
        }
        close(fd)
        guard ok else {
            try? FileManager.default.removeItem(atPath: tmp)
            throw ScienceLoginError.io("写临时文件失败")
        }
        do {
            if FileManager.default.fileExists(atPath: path) {
                _ = try? FileManager.default.removeItem(atPath: path)
            }
            try FileManager.default.moveItem(atPath: tmp, toPath: path)
        } catch {
            try? FileManager.default.removeItem(atPath: tmp)
            throw ScienceLoginError.io("rename 失败：\(error.localizedDescription)")
        }
        chmod(path, mode)
    }

    // MARK: - 小工具

    private static func randomBytes(_ n: Int) throws -> Data {
        var bytes = [UInt8](repeating: 0, count: n)
        let status = SecRandomCopyBytes(kSecRandomDefault, n, &bytes)
        guard status == errSecSuccess else { throw ScienceLoginError.cryptoFailed("SecRandomCopyBytes 失败 \(status)") }
        return Data(bytes)
    }

    private static func uuidV4() -> String { UUID().uuidString.lowercased() }

    /// s 形如 8-4-4-4-12 的十六进制 UUID。
    private static func looksLikeUUID(_ s: String) -> Bool {
        let b = Array(s.utf8)
        guard b.count == 36 else { return false }
        for (i, c) in b.enumerated() {
            switch i {
            case 8, 13, 18, 23:
                if c != UInt8(ascii: "-") { return false }
            default:
                if !isxdigit(Int32(c)).boolValue { return false }
            }
        }
        return true
    }

    /// token_expires_at（ISO8601）的日期部分是否 ≥ 今天（UTC），即尚未过期。
    private static func tokenNotExpired(_ expiresAt: String) -> Bool {
        guard expiresAt.count >= 10 else { return false }
        let date = String(expiresAt.prefix(10))
        let b = Array(date.utf8)
        for (i, c) in b.enumerated() {
            switch i {
            case 4, 7:
                if c != UInt8(ascii: "-") { return false }
            default:
                if !(c >= UInt8(ascii: "0") && c <= UInt8(ascii: "9")) { return false }
            }
        }
        return date >= todayUTCymd()
    }

    private static func todayUTCymd() -> String {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(identifier: "UTC") ?? .current
        let c = cal.dateComponents([.year, .month, .day], from: Date())
        return String(format: "%04d-%02d-%02d", c.year ?? 0, c.month ?? 0, c.day ?? 0)
    }
}

private extension Int32 {
    var boolValue: Bool { self != 0 }
}
