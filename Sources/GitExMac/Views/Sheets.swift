import SwiftUI

struct InputRequest {
    let title: String
    let prompt: String
    var placeholder = ""
    var toggleLabel: String?
    var toggleDefault = false
    var messageLabel: String?
    let onSubmit: (_ name: String, _ toggle: Bool, _ message: String?) -> Void
}

struct ConfirmRequest {
    let title: String
    let message: String
    let confirmLabel: String
    var destructive = false
    var toggleLabel: String?
    let onConfirm: (_ toggle: Bool) -> Void
}

struct InputSheet: View {
    let request: InputRequest
    let dismiss: () -> Void

    @State private var name = ""
    @State private var toggle = false
    @State private var message = ""

    private var trimmed: String { name.trimmingCharacters(in: .whitespaces) }

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title2.bold())
            Text(request.prompt).foregroundStyle(.secondary).lineLimit(2)
            TextField(request.placeholder, text: $name)
                .textFieldStyle(.roundedBorder)
                .onSubmit(submit)
            if let label = request.messageLabel {
                Text(label).font(.caption).foregroundStyle(.secondary)
                TextField("", text: $message, axis: .vertical)
                    .lineLimit(3...6)
                    .textFieldStyle(.roundedBorder)
            }
            if let label = request.toggleLabel {
                Toggle(label, isOn: $toggle)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Create", action: submit)
                    .keyboardShortcut(.defaultAction)
                    .disabled(trimmed.isEmpty || trimmed.contains(" "))
            }
        }
        .padding(20)
        .frame(width: 460)
        .onAppear { toggle = request.toggleDefault }
    }

    private func submit() {
        guard !trimmed.isEmpty, !trimmed.contains(" ") else { return }
        dismiss()
        request.onSubmit(trimmed, toggle, request.messageLabel == nil ? nil : message)
    }
}

struct ConfirmSheet: View {
    let request: ConfirmRequest
    let dismiss: () -> Void
    @State private var toggle = false

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text(request.title).font(.title3.bold())
            Text(request.message)
                .foregroundStyle(.secondary)
                .textSelection(.enabled)
                .fixedSize(horizontal: false, vertical: true)
            if let label = request.toggleLabel {
                Toggle(label, isOn: $toggle)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button(request.confirmLabel, role: request.destructive ? .destructive : nil) {
                    dismiss()
                    request.onConfirm(toggle)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}

struct ResetSheet: View {
    let commit: Commit
    let branch: String?
    let onReset: (ResetMode) -> Void
    let dismiss: () -> Void

    @State private var mode: ResetMode = .mixed

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Reset \(branch ?? "HEAD") to \(commit.shortSha)").font(.title3.bold())
            Text(commit.subject).foregroundStyle(.secondary)
            Picker("", selection: $mode) {
                Text("Soft: keep working tree and index").tag(ResetMode.soft)
                Text("Mixed: keep working tree, reset index").tag(ResetMode.mixed)
                Text("Hard: discard all changes").tag(ResetMode.hard)
            }
            .pickerStyle(.radioGroup)
            .labelsHidden()
            if mode == .hard {
                Label("All uncommitted changes will be lost.", systemImage: "exclamationmark.triangle.fill")
                    .foregroundStyle(.red)
            }
            HStack {
                Spacer()
                Button("Cancel", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Reset", role: mode == .hard ? .destructive : nil) {
                    dismiss()
                    onReset(mode)
                }
                .keyboardShortcut(.defaultAction)
            }
        }
        .padding(20)
        .frame(width: 460)
    }
}
