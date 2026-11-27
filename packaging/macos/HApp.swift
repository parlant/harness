import AppKit
import Darwin
import Foundation

final class HAppDelegate: NSObject, NSApplicationDelegate {
    private var statusItem: NSStatusItem!
    private var statusHeaderItem: NSMenuItem!
    private var openWebItem: NSMenuItem!
    private var copyTokenItem: NSMenuItem!
    private var restartItem: NSMenuItem!
    private var quitItem: NSMenuItem!

    private var permissionWindow: NSWindow?
    private var daemonProcess: Process?
    private var ownedDaemon = false
    private var pollTimer: Timer?
    private let workQueue = DispatchQueue(label: "co.parlant.harness.app.work")
    private var busy = false

    private var harnessRoot: URL {
        guard let resources = Bundle.main.resourceURL else {
            fatalError("H.app bundle is missing Contents/Resources")
        }
        return resources.appendingPathComponent("harness", isDirectory: true)
    }

    private var hiPath: String {
        harnessRoot.appendingPathComponent("bin/hi").path
    }

    private var daemonLauncherPath: String {
        Bundle.main.bundleURL.appendingPathComponent("Contents/MacOS/hi-exec").path
    }

    private var hiImportPath: String {
        harnessRoot.appendingPathComponent("bin/hi-import").path
    }

    private var dataDir: URL {
        if let custom = ProcessInfo.processInfo.environment["H_DATA_DIR"], !custom.isEmpty {
            return URL(fileURLWithPath: (custom as NSString).expandingTildeInPath, isDirectory: true)
        }
        return FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/share/h", isDirectory: true)
    }

    private var webBaseURL: URL {
        let port = ProcessInfo.processInfo.environment["H_WEB_PORT"] ?? "4200"
        return URL(string: "http://127.0.0.1:\(port)")!
    }

    private var webLandingPath: String {
        "/workspaces"
    }

    private var webFallbackURL: URL {
        webBaseURL.appendingPathComponent("workspaces")
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        NSApp.setActivationPolicy(.accessory)
        buildStatusItem()
        startPolling()
        ensureDaemonAndOpenBrowser()
    }

    func applicationShouldHandleReopen(_ sender: NSApplication, hasVisibleWindows flag: Bool) -> Bool {
        ensureDaemonAndOpenBrowser()
        return true
    }

    func applicationWillTerminate(_ notification: Notification) {
        pollTimer?.invalidate()
        stopOwnedDaemonSynchronously()
    }

    private func buildStatusItem() {
        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.title = "H"
            button.font = NSFont.monospacedSystemFont(ofSize: 13, weight: .bold)
            button.toolTip = "H — Local Agent Harness"
        }

        let menu = NSMenu()
        statusHeaderItem = NSMenuItem(title: "Status: Starting…", action: nil, keyEquivalent: "")
        statusHeaderItem.isEnabled = false
        menu.addItem(statusHeaderItem)
        menu.addItem(.separator())

        openWebItem = NSMenuItem(title: "Open H Web UI", action: #selector(openWebUI), keyEquivalent: "o")
        openWebItem.target = self
        menu.addItem(openWebItem)

        copyTokenItem = NSMenuItem(title: "Copy Owner Sign-In Token", action: #selector(copyAuthToken), keyEquivalent: "c")
        copyTokenItem.target = self
        menu.addItem(copyTokenItem)

        menu.addItem(.separator())

        let installCliItem = NSMenuItem(
            title: "Install `hi` Command Line Tool…",
            action: #selector(installCommandLineTools),
            keyEquivalent: ""
        )
        installCliItem.target = self
        menu.addItem(installCliItem)

        let permissionsItem = NSMenuItem(
            title: "Permissions & Setup…",
            action: #selector(showPermissionGuide),
            keyEquivalent: ""
        )
        permissionsItem.target = self
        menu.addItem(permissionsItem)

        restartItem = NSMenuItem(
            title: "Drain & Restart Daemon",
            action: #selector(drainAndRestartDaemon),
            keyEquivalent: "r"
        )
        restartItem.target = self
        menu.addItem(restartItem)

        menu.addItem(.separator())

        quitItem = NSMenuItem(
            title: "Stop Daemon & Quit H",
            action: #selector(stopAndQuit),
            keyEquivalent: "q"
        )
        quitItem.target = self
        menu.addItem(quitItem)

        statusItem.menu = menu
    }

    private func startPolling() {
        pollTimer = Timer.scheduledTimer(withTimeInterval: 3.0, repeats: true) { [weak self] _ in
            self?.refreshStatus()
        }
        refreshStatus()
    }

    private func daemonEnvironment() -> [String: String] {
        var env = ProcessInfo.processInfo.environment
        let basePath = env["PATH"] ?? "/usr/local/bin:/opt/homebrew/bin:/usr/bin:/bin:/usr/sbin:/sbin"
        if !basePath.contains("/opt/homebrew/bin") {
            env["PATH"] = "/opt/homebrew/bin:/usr/local/bin:" + basePath
        }
        env["H_DATA_DIR"] = dataDir.path
        return env
    }

    private func readDaemonManifest() -> [String: Any]? {
        let manifestURL = dataDir.appendingPathComponent("daemon.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return json
    }

    private func readOwnerToken() -> String? {
        let tokenURL = dataDir.appendingPathComponent("auth.token")
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            return nil
        }
        return token
    }

    private func daemonHTTPBaseURL() -> URL? {
        guard let manifest = readDaemonManifest() else { return nil }
        if let raw = manifest["http_url"] as? String, let url = URL(string: raw) {
            return url
        }
        if let urls = manifest["http_urls"] as? [String],
           let raw = urls.first,
           let url = URL(string: raw) {
            return url
        }
        return nil
    }

    private func mintSignInLinkURL() -> URL {
        guard let token = readOwnerToken(),
              let apiBase = daemonHTTPBaseURL(),
              let endpoint = URL(string: "/api/v1/auth/sign-in-link", relativeTo: apiBase) else {
            return webFallbackURL
        }

        let deadline = Date().addingTimeInterval(5.0)
        var mintedCode: String?

        while mintedCode == nil && Date() < deadline {
            var request = URLRequest(url: endpoint)
            request.httpMethod = "POST"
            request.timeoutInterval = 2.0
            request.setValue("Bearer \(token)", forHTTPHeaderField: "Authorization")

            let semaphore = DispatchSemaphore(value: 0)
            var gotHTTPResponse = false

            let task = URLSession.shared.dataTask(with: request) { data, response, _ in
                defer { semaphore.signal() }
                guard let http = response as? HTTPURLResponse else { return }
                gotHTTPResponse = true
                guard http.statusCode == 200,
                      let data = data,
                      let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
                      let code = json["code"] as? String,
                      !code.isEmpty else {
                    return
                }
                mintedCode = code
            }
            task.resume()
            _ = semaphore.wait(timeout: .now() + 2.5)

            if mintedCode != nil || gotHTTPResponse {
                break
            }
            Thread.sleep(forTimeInterval: 0.15)
        }

        guard let code = mintedCode,
              var components = URLComponents(url: webBaseURL, resolvingAgainstBaseURL: false) else {
            return webFallbackURL
        }
        components.path = "/login/link"
        components.queryItems = [
            URLQueryItem(name: "code", value: code),
            URLQueryItem(name: "next", value: webLandingPath)
        ]
        return components.url ?? webFallbackURL
    }

    private func isDaemonRunning() -> Bool {
        guard let json = readDaemonManifest(),
              let pid = json["pid"] as? Int32,
              pid > 0 else {
            return false
        }
        return kill(pid, 0) == 0 || errno == EPERM
    }

    private func refreshStatus() {
        let running = isDaemonRunning()
        DispatchQueue.main.async {
            if self.busy {
                self.statusHeaderItem.title = "Status: Working…"
            } else if running {
                let ownerNote = self.ownedDaemon ? " (managed by H.app)" : " (external daemon)"
                self.statusHeaderItem.title = "Status: Running" + ownerNote
            } else {
                self.statusHeaderItem.title = "Status: Stopped"
            }
            self.quitItem.title = self.ownedDaemon ? "Stop Daemon & Quit H" : "Quit H"
            self.statusItem.button?.title = running ? "H" : "H·"
        }
    }

    private func ensureDataDir() throws {
        try FileManager.default.createDirectory(
            at: dataDir,
            withIntermediateDirectories: true,
            attributes: [.posixPermissions: 0o700]
        )
    }

    private func startDaemonIfNeeded() -> Bool {
        if isDaemonRunning() {
            return true
        }
        do {
            try ensureDataDir()
        } catch {
            presentAlert(title: "Could not prepare H data directory", message: error.localizedDescription)
            return false
        }

        let logURL = dataDir.appendingPathComponent("h-daemon.log")
        if !FileManager.default.fileExists(atPath: logURL.path) {
            FileManager.default.createFile(atPath: logURL.path, contents: nil, attributes: [.posixPermissions: 0o600])
        }

        let process = Process()
        process.executableURL = URL(fileURLWithPath: daemonLauncherPath)
        process.arguments = ["daemon", "--data-dir", dataDir.path]
        process.environment = daemonEnvironment()
        process.currentDirectoryURL = FileManager.default.homeDirectoryForCurrentUser

        if let logHandle = try? FileHandle(forWritingTo: logURL) {
            logHandle.seekToEndOfFile()
            process.standardOutput = logHandle
            process.standardError = logHandle
        }

        process.terminationHandler = { [weak self] _ in
            guard let self = self else { return }
            self.ownedDaemon = false
            self.daemonProcess = nil
            self.refreshStatus()
        }

        do {
            try process.run()
            daemonProcess = process
            ownedDaemon = true
        } catch {
            presentAlert(title: "Failed to start H daemon", message: error.localizedDescription)
            return false
        }

        let deadline = Date().addingTimeInterval(15.0)
        while Date() < deadline {
            if isDaemonRunning() {
                return true
            }
            if !process.isRunning {
                break
            }
            Thread.sleep(forTimeInterval: 0.1)
        }
        return isDaemonRunning()
    }

    private func ensureDaemonAndOpenBrowser() {
        workQueue.async {
            self.busy = true
            self.refreshStatus()
            let ready = self.startDaemonIfNeeded()
            let targetURL = ready ? self.mintSignInLinkURL() : self.webFallbackURL
            self.busy = false
            self.refreshStatus()
            DispatchQueue.main.async {
                if ready {
                    NSWorkspace.shared.open(targetURL)
                } else {
                    self.presentAlert(
                        title: "H daemon did not become ready",
                        message: "Inspect \(self.dataDir.appendingPathComponent("h-daemon.log").path) for details."
                    )
                }
            }
        }
    }

    @objc private func openWebUI() {
        ensureDaemonAndOpenBrowser()
    }

    @objc private func showPermissionGuide() {
        permissionWindow?.close()
        let window = NSWindow(
            contentRect: NSRect(x: 0, y: 0, width: 660, height: 650),
            styleMask: [.titled, .closable], backing: .buffered, defer: false
        )
        window.title = "H — Permissions & Setup"
        window.isReleasedWhenClosed = false
        let stack = NSStackView()
        stack.orientation = .vertical
        stack.alignment = .leading
        stack.spacing = 12
        stack.translatesAutoresizingMaskIntoConstraints = false
        window.contentView!.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.leadingAnchor.constraint(equalTo: window.contentView!.leadingAnchor, constant: 24),
            stack.trailingAnchor.constraint(equalTo: window.contentView!.trailingAnchor, constant: -24),
            stack.topAnchor.constraint(equalTo: window.contentView!.topAnchor, constant: 24)
        ])

        let external = isDaemonRunning() && !ownedDaemon
        let locationWarning = Bundle.main.bundleURL.path == "/Applications/H.app"
            ? "Keep H in /Applications and replace it there when upgrading."
            : "Move H.app to /Applications, then quit and reopen it. Running from Downloads, a disk image, or a versioned release can change its permission identity."
        let daemonNote = external
            ? "An external daemon is running. Permissions granted to H.app may not apply to it. In a terminal, run hi daemon check-service; if registered, run hi daemon uninstall-service, otherwise hi daemon stop. These commands drain active work. Then quit and reopen H. H will not take over the service automatically."
            : "H starts its bundled daemon through hi-exec. After changing permissions, use Drain & Restart Daemon from the H menu."
        let text = """
        1. Install at a stable location
        \(locationWarning)
        Native helper: \(daemonLauncherPath)

        2. Allow only the folder access you need
        Desktop, Documents, Downloads, and some external/network locations are protected by macOS. Open a folder intentionally and respond to its prompt. Review existing decisions in Files & Folders. Keeping projects in ~/Projects avoids many folder prompts.

        Full Disk Access is optional and broad: it can expose sensitive user data to H and its tools. Use it only if you intend that access. Add H.app, or the exact hi-exec/runtime executable named by macOS. Reveal hi-exec below; use Shift-Command-G in the settings file picker to enter a path.

        3. Check which daemon is running
        \(daemonNote)

        Accessibility and Screen Recording are separate permissions for future computer-control features. H does not currently request or use them. Do not enable them for ordinary coding or folder access.

        macOS chooses the responsible process and may still name erlexec or beam.smp. Signed releases with the same developer and identifiers are intended to preserve identity; ad-hoc builds and signing changes may require new approval. A stable path alone is not a guarantee. H cannot grant permissions or reliably infer all privacy decisions.
        """
        let scroll = NSScrollView()
        scroll.hasVerticalScroller = true
        scroll.borderType = .bezelBorder
        let body = NSTextView(frame: NSRect(x: 0, y: 0, width: 590, height: 490))
        body.isEditable = false
        body.isSelectable = true
        body.isRichText = false
        body.font = NSFont.systemFont(ofSize: 13)
        body.string = text
        body.isVerticallyResizable = true
        body.autoresizingMask = [.width]
        body.textContainer?.widthTracksTextView = true
        body.textContainer?.containerSize = NSSize(width: 590, height: CGFloat.greatestFiniteMagnitude)
        scroll.documentView = body
        stack.addArrangedSubview(scroll)
        scroll.widthAnchor.constraint(equalTo: stack.widthAnchor).isActive = true
        scroll.heightAnchor.constraint(equalToConstant: 490).isActive = true

        let settings = NSStackView()
        settings.spacing = 8
        for (title, pane) in [("Files & Folders", "Privacy_FilesAndFolders"),
                              ("Full Disk Access", "Privacy_AllFiles"),
                              ("Accessibility", "Privacy_Accessibility"),
                              ("Screen Recording", "Privacy_ScreenCapture")] {
            let button = NSButton(title: title, target: self, action: #selector(openPrivacySettings(_:)))
            button.identifier = NSUserInterfaceItemIdentifier(pane)
            settings.addArrangedSubview(button)
        }
        stack.addArrangedSubview(settings)
        let reveal = NSButton(title: "Reveal hi-exec in Finder", target: self, action: #selector(revealPermissionHelper))
        stack.addArrangedSubview(reveal)
        permissionWindow = window
        window.center()
        NSApp.activate(ignoringOtherApps: true)
        window.makeKeyAndOrderFront(nil)
    }

    @objc private func openPrivacySettings(_ sender: NSButton) {
        guard let pane = sender.identifier?.rawValue,
              let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)") else { return }
        if !NSWorkspace.shared.open(url) {
            presentAlert(title: "Open Privacy & Security", message: "Open System Settings → Privacy & Security manually. Settings links vary between macOS versions.")
        }
    }

    @objc private func revealPermissionHelper() {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: daemonLauncherPath)])
    }

    @objc private func copyAuthToken() {
        let tokenURL = dataDir.appendingPathComponent("auth.token")
        guard let token = try? String(contentsOf: tokenURL, encoding: .utf8)
            .trimmingCharacters(in: .whitespacesAndNewlines),
              !token.isEmpty else {
            presentAlert(
                title: "Sign-in token not found",
                message: "Start the H daemon first so \(tokenURL.path) is created."
            )
            return
        }
        let pb = NSPasteboard.general
        pb.clearContents()
        pb.setString(token, forType: .string)
    }

    private func normalizedPath(_ raw: String) -> String {
        let expanded = (raw as NSString).expandingTildeInPath
        let standardized = (expanded as NSString).standardizingPath
        return standardized == "/" ? "/" : standardized.trimmingCharacters(in: CharacterSet(charactersIn: "/")).isEmpty ? "/" : standardized
    }

    private func isWritableDirectory(_ path: String) -> Bool {
        var isDir: ObjCBool = false
        guard FileManager.default.fileExists(atPath: path, isDirectory: &isDir), isDir.boolValue else {
            return false
        }
        return access(path, W_OK | X_OK) == 0
    }

    private func isLocalBinUsable(_ localBin: String, home: String) -> Bool {
        if isWritableDirectory(localBin) { return true }
        if FileManager.default.fileExists(atPath: localBin) { return false }
        let localDir = (home as NSString).appendingPathComponent(".local")
        if isWritableDirectory(localDir) { return true }
        return !FileManager.default.fileExists(atPath: localDir) && isWritableDirectory(home)
    }

    private func isExcludedPathDir(_ raw: String, normalized: String, homeBin: String) -> Bool {
        if raw.isEmpty || !raw.hasPrefix("/") { return true }
        let blockedExact: Set<String> = ["/", "/bin", "/usr/bin", "/sbin", "/usr/sbin", homeBin]
        if blockedExact.contains(normalized) { return true }
        if normalized.hasPrefix("/System/") || normalized.hasPrefix("/Library/") || normalized.hasPrefix("/var/run/") {
            return true
        }
        if normalized.hasSuffix("/.cargo/bin") || normalized.hasSuffix("/node_modules/.bin") {
            return true
        }
        let components = (normalized as NSString).pathComponents
        if components.contains("Cellar") || components.contains("shims") { return true }
        if components.contains(where: { $0.hasPrefix("erts-") }) { return true }
        return false
    }

    private func selectBinDir() -> (url: URL, onPath: Bool) {
        let env = daemonEnvironment()
        let home = normalizedPath(FileManager.default.homeDirectoryForCurrentUser.path)
        let rawPath = env["PATH"] ?? ""
        let rawEntries = rawPath.split(separator: ":").map(String.init).filter { !$0.isEmpty }
        let normEntries = rawEntries.map { normalizedPath($0) }
        let pathSet = Set(normEntries)

        if let explicit = env["H_BIN_DIR"], !explicit.isEmpty {
            let norm = normalizedPath(explicit)
            return (URL(fileURLWithPath: norm, isDirectory: true), pathSet.contains(norm))
        }

        let preferred = ["/usr/local/bin", "/opt/local/bin", "/opt/homebrew/bin"]
        for pref in preferred {
            if pathSet.contains(pref) && isWritableDirectory(pref) {
                return (URL(fileURLWithPath: pref, isDirectory: true), true)
            }
        }

        let localBin = normalizedPath((home as NSString).appendingPathComponent(".local/bin"))
        if pathSet.contains(localBin) && isLocalBinUsable(localBin, home: home) {
            return (URL(fileURLWithPath: localBin, isDirectory: true), true)
        }

        let homeBin = normalizedPath((home as NSString).appendingPathComponent(".bin"))
        for (raw, norm) in zip(rawEntries, normEntries) {
            if !isExcludedPathDir(raw, normalized: norm, homeBin: homeBin) && isWritableDirectory(norm) {
                return (URL(fileURLWithPath: norm, isDirectory: true), true)
            }
        }

        if pathSet.contains(homeBin) && isWritableDirectory(homeBin) {
            return (URL(fileURLWithPath: homeBin, isDirectory: true), true)
        }

        for pref in preferred {
            if isWritableDirectory(pref) {
                return (URL(fileURLWithPath: pref, isDirectory: true), pathSet.contains(pref))
            }
        }

        if isWritableDirectory(localBin) {
            return (URL(fileURLWithPath: localBin, isDirectory: true), pathSet.contains(localBin))
        }

        return (URL(fileURLWithPath: homeBin, isDirectory: true), pathSet.contains(homeBin))
    }

    @objc private func installCommandLineTools() {
        let selection = selectBinDir()
        let binDir = selection.url
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for (name, target) in [("hi", hiPath), ("hi-import", hiImportPath)] {
                let linkURL = binDir.appendingPathComponent(name)
                if let attrs = try? FileManager.default.attributesOfItem(atPath: linkURL.path) {
                    let fileType = attrs[.type] as? FileAttributeType
                    if fileType != .typeSymbolicLink {
                        presentAlert(
                            title: "Refusing to overwrite existing file",
                            message: "\(linkURL.path) already exists and is not a symbolic link."
                        )
                        return
                    }
                    try FileManager.default.removeItem(at: linkURL)
                }
                try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
            }
            let pathHint = selection.onPath
                ? "Run `hi` in any terminal."
                : "Ensure \(binDir.path) is on your shell PATH, then run `hi` in any terminal."
            presentAlert(
                title: "Installed `hi` and `hi-import`",
                message: "Symlinks created in \(binDir.path).\n\n\(pathHint)"
            )
        } catch {
            presentAlert(title: "Failed to install CLI tools", message: error.localizedDescription)
        }
    }

    @discardableResult
    private func runHi(_ arguments: [String]) -> (Int32, String) {
        let proc = Process()
        proc.executableURL = URL(fileURLWithPath: hiPath)
        proc.arguments = arguments
        proc.environment = daemonEnvironment()
        let pipe = Pipe()
        proc.standardOutput = pipe
        proc.standardError = pipe
        do {
            try proc.run()
            proc.waitUntilExit()
            let output = String(data: pipe.fileHandleForReading.readDataToEndOfFile(), encoding: .utf8) ?? ""
            return (proc.terminationStatus, output.trimmingCharacters(in: .whitespacesAndNewlines))
        } catch {
            return (1, error.localizedDescription)
        }
    }

    @objc private func drainAndRestartDaemon() {
        workQueue.async {
            self.busy = true
            self.refreshStatus()
            let (status, output) = self.runHi(["daemon", "stop"])
            if status != 0 && self.isDaemonRunning() {
                self.busy = false
                self.refreshStatus()
                self.presentAlert(
                    title: "Could not drain H daemon",
                    message: output.isEmpty ? "The daemon refused to stop (active turns may still be running)." : output
                )
                return
            }
            self.ownedDaemon = false
            self.daemonProcess = nil
            let deadline = Date().addingTimeInterval(10.0)
            while self.isDaemonRunning() && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            _ = self.startDaemonIfNeeded()
            self.busy = false
            self.refreshStatus()
        }
    }

    private func stopOwnedDaemonSynchronously() {
        guard ownedDaemon else { return }
        _ = runHi(["daemon", "stop"])
        if let proc = daemonProcess, proc.isRunning {
            let deadline = Date().addingTimeInterval(5.0)
            while proc.isRunning && Date() < deadline {
                Thread.sleep(forTimeInterval: 0.1)
            }
            if proc.isRunning {
                proc.terminate()
            }
        }
        ownedDaemon = false
        daemonProcess = nil
    }

    @objc private func stopAndQuit() {
        workQueue.async {
            self.busy = true
            self.refreshStatus()
            self.stopOwnedDaemonSynchronously()
            DispatchQueue.main.async {
                NSApp.terminate(nil)
            }
        }
    }

    private func presentAlert(title: String, message: String) {
        DispatchQueue.main.async {
            NSApp.activate(ignoringOtherApps: true)
            let alert = NSAlert()
            alert.alertStyle = .informational
            alert.messageText = title
            alert.informativeText = message
            alert.addButton(withTitle: "OK")
            alert.runModal()
        }
    }
}

let app = NSApplication.shared
let delegate = HAppDelegate()
app.delegate = delegate
app.run()
