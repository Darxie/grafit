import SwiftUI

/// Settings window (⌘,). Identity and git options are stored in git config,
/// app-only options in UserDefaults.
struct SettingsView: View {
    var tabs: TabsModel

    var body: some View {
        TabView {
            IdentitySettings(repoModel: tabs.selected)
                .frame(height: 560)
                .tabItem { Label("Identity", systemImage: "person.crop.circle") }
            GeneralSettings()
                .frame(height: 470)
                .tabItem { Label("General", systemImage: "gearshape") }
        }
        .frame(width: 560)
        .padding(20)
    }
}

private struct IdentityFields: Hashable {
    var name = ""
    var email = ""
}

struct IdentitySettings: View {
    let repoModel: RepoModel?

    @State private var global = IdentityFields()
    @State private var savedGlobal = IdentityFields()
    @State private var local = IdentityFields()
    @State private var savedLocal = IdentityFields()
    @State private var message: String?

    private var globalRepo: GitRepository { GitRepository(url: FileManager.default.homeDirectoryForCurrentUser) }

    var body: some View {
        Form {
            Section {
                TextField("Name", text: $global.name, prompt: Text("Your Name"))
                TextField("Email", text: $global.email, prompt: Text("you@example.com"))
                HStack {
                    Spacer()
                    Button("Save Global") { save(.global) }
                        .disabled(global == savedGlobal)
                }
            } header: {
                Text("Global (all repositories)")
            } footer: {
                Text("Stored in ~/.gitconfig (user.name / user.email).")
                    .font(.caption).foregroundStyle(.secondary)
            }

            Section {
                if let repoModel {
                    TextField("Name", text: $local.name, prompt: Text(savedGlobal.name.isEmpty ? "inherits global" : savedGlobal.name))
                    TextField("Email", text: $local.email, prompt: Text(savedGlobal.email.isEmpty ? "inherits global" : savedGlobal.email))
                    HStack {
                        Text("Leave empty to use the global identity.")
                            .font(.caption).foregroundStyle(.secondary)
                        Spacer()
                        Button("Save for \(repoModel.name)") { save(.local) }
                            .disabled(local == savedLocal)
                    }
                } else {
                    Text("Open a repository to set an identity just for it.")
                        .foregroundStyle(.secondary)
                }
            } header: {
                Text(repoModel.map { "This repository: \($0.name)" } ?? "This repository")
            }

            if let message {
                Text(message).font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task(id: repoModel?.id) { await load() }
    }

    private func load() async {
        savedGlobal = IdentityFields(name: await globalRepo.config("user.name", scope: .global) ?? "",
                                     email: await globalRepo.config("user.email", scope: .global) ?? "")
        global = savedGlobal
        if let repo = repoModel?.repo {
            savedLocal = IdentityFields(name: await repo.config("user.name", scope: .local) ?? "",
                                        email: await repo.config("user.email", scope: .local) ?? "")
        } else {
            savedLocal = IdentityFields()
        }
        local = savedLocal
    }

    private func save(_ scope: ConfigScope) {
        let fields = scope == .global ? global : local
        let repo = scope == .global ? globalRepo : repoModel?.repo
        guard let repo else { return }
        Task {
            do {
                try await repo.setConfig("user.name", fields.name, scope: scope)
                try await repo.setConfig("user.email", fields.email, scope: scope)
                message = "Saved."
            } catch {
                message = error.localizedDescription
            }
            await load()
        }
    }
}

struct GeneralSettings: View {
    @AppStorage("commitLimit") private var commitLimit = 5000
    @AppStorage(Appearance.key) private var darkMode = true
    @AppStorage("cloneFolder") private var cloneFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("repos").path

    @State private var mergeTool = ""
    @State private var pullRebase = false
    @State private var fetchPrune = false
    @State private var loaded = false

    private var globalRepo: GitRepository { GitRepository(url: FileManager.default.homeDirectoryForCurrentUser) }

    static let mergeTools: [(id: String, label: String)] = [
        ("", "Not set"),
        ("opendiff", "FileMerge (Xcode)"),
        ("vscode", "Visual Studio Code"),
        ("smerge", "Sublime Merge"),
        ("bc", "Beyond Compare"),
        ("kdiff3", "KDiff3"),
        ("meld", "Meld"),
        ("p4merge", "P4Merge"),
        ("vimdiff", "vimdiff"),
    ]

    var body: some View {
        Form {
            Section("App") {
                Toggle("Dark mode", isOn: $darkMode)
                    .onChange(of: darkMode) { _, _ in Appearance.apply() }
                Picker("Commits to load", selection: $commitLimit) {
                    ForEach([1000, 2000, 5000, 10000, 20000, 50000], id: \.self) { Text("\($0)").tag($0) }
                }
                LabeledContent("Clone into") {
                    HStack {
                        Text((cloneFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { cloneFolder = url.path }
                        }
                    }
                }
            }
            Section {
                Picker("Merge tool", selection: $mergeTool) {
                    let known = Self.mergeTools.contains { $0.id == mergeTool }
                    ForEach(Self.mergeTools + (known ? [] : [(mergeTool, mergeTool)]), id: \.id) {
                        Text($0.label).tag($0.id)
                    }
                }
                .onChange(of: mergeTool) { _, value in
                    guard loaded else { return }
                    Task {
                        try? await globalRepo.setConfig("merge.tool", value, scope: .global)
                        try? await globalRepo.setConfig("mergetool.keepBackup", value.isEmpty ? "" : "false", scope: .global)
                    }
                }
                Toggle("Pull with rebase by default", isOn: $pullRebase)
                    .onChange(of: pullRebase) { _, value in
                        guard loaded else { return }
                        Task { try? await globalRepo.setConfig("pull.rebase", value ? "true" : "", scope: .global) }
                    }
                Toggle("Prune deleted remote branches on fetch", isOn: $fetchPrune)
                    .onChange(of: fetchPrune) { _, value in
                        guard loaded else { return }
                        Task { try? await globalRepo.setConfig("fetch.prune", value ? "true" : "", scope: .global) }
                    }
            } header: {
                Text("Git (global)")
            } footer: {
                Text("The merge tool opens from the conflict resolver (git mergetool).")
                    .font(.caption).foregroundStyle(.secondary)
            }
        }
        .formStyle(.grouped)
        .task {
            mergeTool = await globalRepo.config("merge.tool", scope: .global) ?? ""
            pullRebase = await globalRepo.config("pull.rebase", scope: .global) == "true"
            fetchPrune = await globalRepo.config("fetch.prune", scope: .global) == "true"
            loaded = true
        }
    }
}
