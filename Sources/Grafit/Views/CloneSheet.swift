import SwiftUI

/// Clone a remote repository into a local folder and open it as a tab.
struct CloneSheet: View {
    let tabs: TabsModel

    @Environment(\.dismiss) private var dismiss
    @AppStorage("cloneFolder") private var cloneFolder = FileManager.default.homeDirectoryForCurrentUser
        .appendingPathComponent("repos").path

    @State private var remote = ""
    @State private var name = ""
    @State private var nameEdited = false
    @State private var cloning = false
    @State private var error: String?

    private var destination: URL { URL(fileURLWithPath: cloneFolder).appendingPathComponent(name) }
    private var destinationExists: Bool { !name.isEmpty && FileManager.default.fileExists(atPath: destination.path) }
    private var canClone: Bool {
        !remote.trimmingCharacters(in: .whitespaces).isEmpty && !name.isEmpty && !destinationExists && !cloning
    }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Clone repository").font(.title2.bold())
            Form {
                TextField("Repository URL", text: $remote, prompt: Text("git@github.com:org/repo.git or https://…"))
                    .onChange(of: remote) { _, value in
                        if !nameEdited { name = GitRepository.folderName(forRemote: value) }
                    }
                LabeledContent("Parent folder") {
                    HStack {
                        Text((cloneFolder as NSString).abbreviatingWithTildeInPath)
                            .lineLimit(1).truncationMode(.middle)
                        Spacer()
                        Button("Choose…") {
                            let panel = NSOpenPanel()
                            panel.canChooseDirectories = true
                            panel.canChooseFiles = false
                            panel.canCreateDirectories = true
                            if panel.runModal() == .OK, let url = panel.url { cloneFolder = url.path }
                        }
                    }
                }
                TextField("Folder name", text: Binding(get: { name }, set: { name = $0; nameEdited = true }))
            }
            Text(destinationExists ? "\(destination.path) already exists."
                 : name.isEmpty ? "Paste an SSH or HTTPS URL." : "Clones into \(destination.path)")
                .font(.caption)
                .foregroundStyle(destinationExists ? .red : .secondary)
            if let error {
                ScrollView {
                    Text(error).font(.caption).foregroundStyle(.red).textSelection(.enabled)
                        .frame(maxWidth: .infinity, alignment: .leading)
                }
                .frame(maxHeight: 80)
            }
            HStack {
                if cloning {
                    ProgressView().controlSize(.small)
                    Text("Cloning…").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Cancel") { dismiss() }.keyboardShortcut(.cancelAction)
                Button("Clone", action: clone)
                    .keyboardShortcut(.defaultAction)
                    .disabled(!canClone)
            }
        }
        .padding(20)
        .frame(width: 560)
        .onAppear {
            if let text = NSPasteboard.general.string(forType: .string)?.trimmingCharacters(in: .whitespacesAndNewlines),
               text.hasSuffix(".git") || text.hasPrefix("git@") || text.hasPrefix("https://") {
                remote = text
            }
        }
    }

    private func clone() {
        cloning = true
        error = nil
        let parent = URL(fileURLWithPath: cloneFolder)
        let url = remote.trimmingCharacters(in: .whitespacesAndNewlines)
        let folder = name
        Task {
            defer { cloning = false }
            do {
                try FileManager.default.createDirectory(at: parent, withIntermediateDirectories: true)
                let repoURL = try await GitRepository.clone(url, into: parent, name: folder)
                dismiss()
                await tabs.open(repoURL)
            } catch {
                self.error = error.localizedDescription
            }
        }
    }
}
