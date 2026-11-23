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
        harnessRoot.appendingPathComponent("bin/h-daemon").path
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

    private var webInboxURL: URL {
        let port = ProcessInfo.processInfo.environment["H_WEB_PORT"] ?? "4200"
        return URL(string: "http://127.0.0.1:\(port)/inbox")!
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

    private func isDaemonRunning() -> Bool {
        let manifestURL = dataDir.appendingPathComponent("daemon.json")
        guard let data = try? Data(contentsOf: manifestURL),
              let json = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
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
        process.arguments = ["--data-dir", dataDir.path]
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
            self.busy = false
            self.refreshStatus()
            DispatchQueue.main.async {
                if ready {
                    NSWorkspace.shared.open(self.webInboxURL)
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

    @objc private func installCommandLineTools() {
        let binDir = FileManager.default.homeDirectoryForCurrentUser
            .appendingPathComponent(".local/bin", isDirectory: true)
        do {
            try FileManager.default.createDirectory(at: binDir, withIntermediateDirectories: true)
            for (name, target) in [("hi", hiPath), ("hi-import", hiImportPath)] {
                let linkURL = binDir.appendingPathComponent(name)
                if FileManager.default.fileExists(atPath: linkURL.path)
                    || (try? FileManager.default.attributesOfItem(atPath: linkURL.path)) != nil {
                    try FileManager.default.removeItem(at: linkURL)
                }
                try FileManager.default.createSymbolicLink(atPath: linkURL.path, withDestinationPath: target)
            }
            presentAlert(
                title: "Installed `hi` and `hi-import`",
                message: "Symlinks created in \(binDir.path).\n\nEnsure \(binDir.path) is on your shell PATH, then run `hi` in any terminal."
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
