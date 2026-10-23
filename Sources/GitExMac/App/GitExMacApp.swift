import AppKit
import SwiftUI

@main
struct GitExMacApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate

    var body: some Scene {
        Window("Git Extensions", id: "main") {
            MainWindowView(tabs: TabsModel.shared)
        }
        .defaultSize(width: 1400, height: 900)
        .commands {
            RepoCommands(tabs: TabsModel.shared)
        }

        Settings {
            SettingsView(tabs: TabsModel.shared)
        }
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    func applicationDidFinishLaunching(_ notification: Notification) {
        NSWindow.allowsAutomaticWindowTabbing = false
        NSApp.setActivationPolicy(.regular)
        NSApp.activate(ignoringOtherApps: true)
        Appearance.apply()
        scheduleDebugSnapshot()
    }

    /// GITEXMAC_SNAPSHOT=/path/prefix writes PNGs of all windows after a few seconds (for development).
    private func scheduleDebugSnapshot() {
        guard let prefix = ProcessInfo.processInfo.environment["GITEXMAC_SNAPSHOT"] else { return }
        DispatchQueue.main.asyncAfter(deadline: .now() + 4) {
            for (i, window) in NSApp.windows.enumerated() where window.isVisible {
                guard let view = window.contentView?.superview ?? window.contentView,
                      let rep = view.bitmapImageRepForCachingDisplay(in: view.bounds) else { continue }
                view.cacheDisplay(in: view.bounds, to: rep)
                try? rep.representation(using: .png, properties: [:])?
                    .write(to: URL(fileURLWithPath: "\(prefix)-\(i).png"))
            }
        }
    }

    func applicationShouldTerminateAfterLastWindowClosed(_ sender: NSApplication) -> Bool { true }

    /// Folders dropped on the Dock icon or opened with `open -a GitExMac <folder>` become tabs.
    func application(_ application: NSApplication, open urls: [URL]) {
        Task { @MainActor in
            for url in urls { await TabsModel.shared.open(url) }
        }
    }
}

/// App-wide appearance; dark unless the user switched it off in the View menu.
enum Appearance {
    static let key = "darkMode"

    static var isDark: Bool {
        UserDefaults.standard.object(forKey: key) as? Bool ?? true
    }

    @MainActor
    static func apply() {
        NSApp.appearance = NSAppearance(named: isDark ? .darkAqua : .aqua)
    }
}

/// Recently opened repositories, most recent first.
enum RecentRepos {
    private static let key = "recentRepositories"

    static var all: [String] {
        (UserDefaults.standard.stringArray(forKey: key) ?? []).filter {
            FileManager.default.fileExists(atPath: $0)
        }
    }

    static func add(_ path: String) {
        var list = all.filter { $0 != path }
        list.insert(path, at: 0)
        UserDefaults.standard.set(Array(list.prefix(20)), forKey: key)
    }

    static func remove(_ path: String) {
        UserDefaults.standard.set(all.filter { $0 != path }, forKey: key)
    }

    /// Path passed on the command line (`GitExMac.app/Contents/MacOS/GitExMac /path/to/repo`).
    static var launchArgument: String? {
        let args = CommandLine.arguments.dropFirst().filter { !$0.hasPrefix("-") }
        guard let first = args.first else { return nil }
        return URL(fileURLWithPath: first).standardizedFileURL.path
    }
}

@MainActor
func chooseRepositoryFolder() -> URL? {
    let panel = NSOpenPanel()
    panel.canChooseDirectories = true
    panel.canChooseFiles = false
    panel.allowsMultipleSelection = false
    panel.prompt = "Open"
    panel.message = "Choose a git repository"
    return panel.runModal() == .OK ? panel.url : nil
}

/// The single main window: repository tabs on top, the selected repository below.
struct MainWindowView: View {
    @Bindable var tabs: TabsModel

    var body: some View {
        VStack(spacing: 0) {
            if !tabs.tabs.isEmpty {
                TabBarView(tabs: tabs)
            }
            if let model = tabs.selected {
                RepoView(model: model, onClose: { tabs.close(model.id) })
                    .id(model.id)
                    .navigationTitle(model.name)
                    .navigationSubtitle(model.repo.url.path)
            } else {
                WelcomeView(open: { url in Task { await tabs.open(url) } },
                            clone: { tabs.showClone = true },
                            create: { tabs.initWithPanel() },
                            error: tabs.openError)
                    .navigationTitle("Git Extensions")
            }
        }
        .frame(minWidth: 900, minHeight: 550)
        .sheet(isPresented: $tabs.showClone) {
            CloneSheet(tabs: tabs)
        }
        .task {
            // Keep branch / change counts of all tabs fresh while the app is running.
            while !Task.isCancelled {
                try? await Task.sleep(for: .seconds(15))
                if NSApp.isActive { await tabs.refreshSummaries() }
            }
        }
        .onReceive(NotificationCenter.default.publisher(for: NSApplication.didBecomeActiveNotification)) { _ in
            Task { await tabs.refreshSummaries() }
        }
    }
}

// MARK: - Menu commands

struct FocusedRepoKey: FocusedValueKey {
    typealias Value = RepoActions
}

extension FocusedValues {
    var repoActions: RepoActions? {
        get { self[FocusedRepoKey.self] }
        set { self[FocusedRepoKey.self] = newValue }
    }
}

/// Actions the focused repository window exposes to the menu bar.
struct RepoActions {
    let refresh: () -> Void
    let commit: () -> Void
    let fetch: () -> Void
    let pull: () -> Void
    let push: () -> Void
    let close: () -> Void
}

struct RepoCommands: Commands {
    let tabs: TabsModel
    @FocusedValue(\.repoActions) private var actions
    @AppStorage(Appearance.key) private var darkMode = true

    var body: some Commands {
        CommandGroup(after: .toolbar) {
            Toggle("Dark Mode", isOn: $darkMode)
                .keyboardShortcut("d", modifiers: [.command, .shift])
                .onChange(of: darkMode) { _, _ in Appearance.apply() }
        }
        CommandGroup(replacing: .newItem) {
            Button("New Tab…") { tabs.openWithPanel() }
                .keyboardShortcut("t")
            Button("Open Repository…") { tabs.openWithPanel() }
                .keyboardShortcut("o")
            Button("Clone Repository…") { tabs.showClone = true }
                .keyboardShortcut("o", modifiers: [.command, .shift])
            Button("New Repository…") { tabs.initWithPanel() }
                .keyboardShortcut("n", modifiers: [.command, .shift])
        }
        CommandGroup(replacing: .saveItem) {
            Button("Close Tab") {
                if let id = tabs.selectedId {
                    tabs.close(id)
                } else {
                    NSApp.keyWindow?.performClose(nil)
                }
            }
            .keyboardShortcut("w")
        }
        CommandGroup(before: .windowList) {
            Button("Show Next Tab") { tabs.selectNext(1) }
                .keyboardShortcut(.tab, modifiers: .control)
            Button("Show Previous Tab") { tabs.selectNext(-1) }
                .keyboardShortcut(.tab, modifiers: [.control, .shift])
            ForEach(0..<9) { i in
                Button("Tab \(i + 1)") { tabs.select(index: i) }
                    .keyboardShortcut(KeyEquivalent(Character("\(i + 1)")), modifiers: .command)
                    .disabled(i >= tabs.tabs.count)
            }
            Divider()
        }
        CommandMenu("Repository") {
            Button("Refresh") { actions?.refresh() }
                .keyboardShortcut("r")
            Divider()
            Button("Commit…") { actions?.commit() }
                .keyboardShortcut("k")
            Divider()
            Button("Fetch") { actions?.fetch() }
                .keyboardShortcut("f", modifiers: [.command, .shift])
            Button("Pull") { actions?.pull() }
                .keyboardShortcut("l", modifiers: [.command, .shift])
            Button("Push") { actions?.push() }
                .keyboardShortcut("p", modifiers: [.command, .shift])
        }
    }
}
