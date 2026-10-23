import SwiftUI

struct WelcomeView: View {
    let open: (URL) -> Void
    let clone: () -> Void
    let create: () -> Void
    let error: String?
    @State private var recent = RecentRepos.all

    var body: some View {
        HStack(spacing: 0) {
            VStack(alignment: .leading, spacing: 16) {
                Text("Grafit")
                    .font(.largeTitle.bold())
                Text("A Git client for macOS")
                    .foregroundStyle(.secondary)
                Button {
                    if let url = chooseRepositoryFolder() { open(url) }
                } label: {
                    Label("Open repository…", systemImage: "folder")
                }
                .controlSize(.large)
                Button(action: clone) {
                    Label("Clone repository…", systemImage: "arrow.down.doc")
                }
                .controlSize(.large)
                Button(action: create) {
                    Label("New repository…", systemImage: "plus.square.on.square")
                }
                .controlSize(.large)
                if let error {
                    Text(error)
                        .foregroundStyle(.red)
                        .font(.callout)
                }
                Spacer()
            }
            .padding(32)
            .frame(width: 300, alignment: .leading)

            Divider()

            VStack(alignment: .leading, spacing: 0) {
                Text("Recent repositories")
                    .font(.headline)
                    .padding(.horizontal, 20)
                    .padding(.vertical, 12)
                if recent.isEmpty {
                    Text("No recent repositories yet.")
                        .foregroundStyle(.secondary)
                        .padding(20)
                    Spacer()
                } else {
                    List(recent, id: \.self) { path in
                        Button {
                            open(URL(fileURLWithPath: path))
                        } label: {
                            VStack(alignment: .leading, spacing: 2) {
                                Text((path as NSString).lastPathComponent)
                                    .font(.body.weight(.medium))
                                Text((path as NSString).abbreviatingWithTildeInPath)
                                    .font(.caption)
                                    .foregroundStyle(.secondary)
                            }
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .contentShape(Rectangle())
                        }
                        .buttonStyle(.plain)
                        .padding(.vertical, 3)
                        .contextMenu {
                            Button("Remove from list") {
                                RecentRepos.remove(path)
                                recent = RecentRepos.all
                            }
                            Button("Show in Finder") {
                                NSWorkspace.shared.selectFile(nil, inFileViewerRootedAtPath: path)
                            }
                        }
                    }
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 700, minHeight: 420)
        .onAppear { recent = RecentRepos.all }
    }
}
