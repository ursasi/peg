import AppKit

/// Checks GitHub for a newer release and swaps it in when asked.
///
/// Peg is signed ad-hoc and lives outside the App Store, so there is no updater
/// framework to lean on. The release zip is downloaded and unpacked next to the
/// running bundle, then a small shell script waits for this process to exit,
/// replaces `/Applications/Peg.app` and opens the new one.
///
/// This is the only network traffic Peg makes, and only when asked to.
@MainActor
final class Updater {
    static let shared = Updater()

    enum Failure: LocalizedError {
        case network(String)
        case noRelease
        case noAsset
        case badBundle

        var errorDescription: String? {
            switch self {
            case .network(let why): return "连接 GitHub 失败：\(why)"
            case .noRelease: return "GitHub 上还没有可用的版本"
            case .noAsset: return "这个版本没有可下载的 zip"
            case .badBundle: return "下载下来的包不完整"
            }
        }
    }

    struct Release {
        let version: String
        let notes: String
        let zip: URL
    }

    private let api = URL(string: "https://api.github.com/repos/ursasi/peg/releases/latest")!

    var currentVersion: String {
        Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "0"
    }

    // MARK: - Check

    func check(interactive: Bool) {
        Task { @MainActor in
            do {
                let release = try await latest()
                guard isNewer(release.version, than: currentVersion) else {
                    DebugLog.log("update: \(currentVersion) is current (remote \(release.version))")
                    if interactive { inform("已是最新版本",
                                            "当前 \(currentVersion)，GitHub 上也是 \(release.version)。") }
                    return
                }
                DebugLog.log("update: \(release.version) available (have \(currentVersion))")
                if interactive { ask(release) }
            } catch {
                DebugLog.log("update: check failed — \(error.localizedDescription)")
                if interactive { inform("检查更新失败", error.localizedDescription) }
            }
        }
    }

    /// The API is the nice path — it carries the release notes — but it is rate
    /// limited per IP, and a shared address runs out quickly. `/releases/latest`
    /// answers with a redirect to the tag, which is not rate limited, and the
    /// asset name has been `Peg-<version>.zip` for every release so far.
    private func latest() async throws -> Release {
        if let release = try? await latestFromAPI() { return release }
        return try await latestFromRedirect()
    }

    private func latestFromRedirect() async throws -> Release {
        var request = URLRequest(url: URL(string: "https://github.com/ursasi/peg/releases/latest")!)
        request.timeoutInterval = 20
        request.setValue("Peg-\(currentVersion)", forHTTPHeaderField: "User-Agent")
        let session = URLSession(configuration: .ephemeral, delegate: NoRedirects(), delegateQueue: nil)
        let (_, response) = try await session.data(for: request)
        guard let http = response as? HTTPURLResponse,
              let location = http.value(forHTTPHeaderField: "Location"),
              let tag = location.split(separator: "/").last.map(String.init),
              tag.hasPrefix("v")
        else { throw Failure.noRelease }
        let version = String(tag.dropFirst())
        guard let zip = URL(string: "https://github.com/ursasi/peg/releases/download/\(tag)/Peg-\(version).zip")
        else { throw Failure.noAsset }
        DebugLog.log("update: redirect says \(tag), asset \(zip.lastPathComponent)")
        return Release(version: tag, notes: "", zip: zip)
    }

    private func latestFromAPI() async throws -> Release {
        var request = URLRequest(url: api)
        request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
        // GitHub rejects API calls without one.
        request.setValue("Peg-\(currentVersion)", forHTTPHeaderField: "User-Agent")
        request.timeoutInterval = 20
        let data: Data
        let response: URLResponse
        do {
            (data, response) = try await URLSession.shared.data(for: request)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        let status = (response as? HTTPURLResponse)?.statusCode ?? -1
        guard status == 200 else {
            DebugLog.log("update: HTTP \(status) — \(String(data: data.prefix(200), encoding: .utf8) ?? "")")
            throw Failure.network("GitHub 返回 \(status)")
        }
        guard let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            throw Failure.noRelease
        }

        let tag = (json["tag_name"] as? String) ?? ""
        let notes = (json["body"] as? String) ?? ""
        let assets = (json["assets"] as? [[String: Any]]) ?? []
        guard let asset = assets.first(where: { ($0["name"] as? String)?.hasSuffix(".zip") == true }),
              let raw = asset["browser_download_url"] as? String,
              let zip = URL(string: raw)
        else { throw Failure.noAsset }
        return Release(version: tag, notes: notes, zip: zip)
    }

    /// `v0.6.1` is newer than `0.5.0`; anything unparsable counts as equal, so a
    /// odd tag can never trigger a downgrade.
    func isNewer(_ remote: String, than local: String) -> Bool {
        func parts(_ text: String) -> [Int] {
            text.trimmingCharacters(in: CharacterSet(charactersIn: "vV"))
                .split(separator: ".")
                .map { Int($0.prefix(while: \.isNumber)) ?? 0 }
        }
        let a = parts(remote), b = parts(local)
        guard !a.isEmpty else { return false }
        for index in 0..<max(a.count, b.count) {
            let lhs = index < a.count ? a[index] : 0
            let rhs = index < b.count ? b[index] : 0
            if lhs != rhs { return lhs > rhs }
        }
        return false
    }

    /// Debug channel: exercise the whole network path without touching the
    /// installed bundle.
    func dryRun() {
        Task { @MainActor in
            do {
                let release = try await latest()
                DebugLog.log("update dryRun: remote=\(release.version) local=\(currentVersion) newer=\(isNewer(release.version, than: currentVersion))")
                let app = try await download(release, dryRun: true)
                DebugLog.log("update dryRun: unpacked at \(app.path)")
            } catch {
                DebugLog.log("update dryRun failed — \(error.localizedDescription)")
            }
        }
    }

    // MARK: - Install

    private func ask(_ release: Release) {
        let alert = NSAlert()
        alert.messageText = "Peg \(release.version) 可用"
        alert.informativeText = "当前 \(currentVersion)。安装后会重新打开 Peg。\n\n"
            + String(release.notes.prefix(700))
        alert.addButton(withTitle: "下载并安装")
        alert.addButton(withTitle: "稍后")
        NSApp.activate(ignoringOtherApps: true)
        guard alert.runModal() == .alertFirstButtonReturn else { return }
        Task { @MainActor in
            do {
                let app = try await download(release)
                try swap(in: app)
            } catch {
                inform("安装失败", error.localizedDescription)
            }
        }
    }

    /// Downloads and unpacks the release, returning the app bundle inside it.
    /// `dryRun` leaves the installed copy alone, which is what the debug
    /// channel uses to exercise the network path.
    func download(_ release: Release, dryRun: Bool = false) async throws -> URL {
        let dir = FileManager.default.temporaryDirectory
            .appendingPathComponent("peg-update-\(UUID().uuidString)", isDirectory: true)
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let zip = dir.appendingPathComponent("Peg.zip")
        do {
            let (data, _) = try await URLSession.shared.data(from: release.zip)
            try data.write(to: zip)
        } catch {
            throw Failure.network(error.localizedDescription)
        }
        // ditto keeps the bundle intact, unlike a naive unzip of the archive's
        // resource forks.
        try run("/usr/bin/ditto", ["-x", "-k", zip.path, dir.path])
        guard let app = try FileManager.default
            .contentsOfDirectory(at: dir, includingPropertiesForKeys: nil)
            .first(where: { $0.pathExtension == "app" })
        else { throw Failure.badBundle }
        let version = Bundle(url: app)?
            .object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        guard let version, dryRun || isNewer(version, than: currentVersion) else { throw Failure.badBundle }
        DebugLog.log("update: unpacked \(version) at \(app.path) dryRun=\(dryRun)")
        return app
    }

    /// Hands the swap to a shell script: the running bundle cannot replace
    /// itself, and the script has to wait for this process to go away.
    private func swap(in app: URL) throws {
        let script = """
        #!/bin/sh
        pid="$1"; src="$2"
        dest="/Applications/Peg.app"; backup="/Applications/.Peg.app.old"
        while kill -0 "$pid" 2>/dev/null; do sleep 0.2; done
        rm -rf "$backup"
        [ -d "$dest" ] && mv "$dest" "$backup"
        if cp -R "$src" "$dest"; then
            xattr -dr com.apple.quarantine "$dest" 2>/dev/null
            codesign --force --deep --sign - "$dest" >/dev/null 2>&1
            rm -rf "$backup"
        else
            rm -rf "$dest"
            [ -d "$backup" ] && mv "$backup" "$dest"
        fi
        open "$dest"
        """
        let url = FileManager.default.temporaryDirectory.appendingPathComponent("peg-swap.sh")
        try script.write(to: url, atomically: true, encoding: .utf8)
        try FileManager.default.setAttributes([.posixPermissions: 0o755], ofItemAtPath: url.path)
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/sh")
        process.arguments = [url.path, String(ProcessInfo.processInfo.processIdentifier), app.path]
        try process.run()
        NSApp.terminate(nil)
    }

    /// Keeps the redirect from being followed, so the tag can be read off it.
    private final class NoRedirects: NSObject, URLSessionTaskDelegate {
        func urlSession(_ session: URLSession, task: URLSessionTask,
                        willPerformHTTPRedirection response: HTTPURLResponse,
                        newRequest request: URLRequest,
                        completionHandler: @escaping (URLRequest?) -> Void) {
            completionHandler(nil)
        }
    }

    private func run(_ tool: String, _ arguments: [String]) throws {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: tool)
        process.arguments = arguments
        try process.run()
        process.waitUntilExit()
        guard process.terminationStatus == 0 else { throw Failure.badBundle }
    }

    private func inform(_ title: String, _ body: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = body
        alert.addButton(withTitle: "好")
        NSApp.activate(ignoringOtherApps: true)
        alert.runModal()
    }
}
