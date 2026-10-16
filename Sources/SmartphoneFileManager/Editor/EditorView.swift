import SFMCore
import SwiftUI

struct EditorView: View {
    @Bindable var model: EditorModel
    @Environment(\.dismiss) private var dismiss
    @State private var confirmClose = false
    @State private var pendingEncoding: TextEncoding?

    var body: some View {
        VStack(spacing: 0) {
            header
            Divider()
            content
            Divider()
            statusBar
        }
        .frame(minWidth: 760, idealWidth: 960, minHeight: 520, idealHeight: 720)
        .confirmationDialog("Discard unsaved changes?", isPresented: $confirmClose) {
            Button("Discard", role: .destructive) { dismiss() }
        }
        .confirmationDialog("Reload with another encoding?", isPresented: Binding(
            get: { pendingEncoding != nil }, set: { if !$0 { pendingEncoding = nil } })
        ) {
            Button("Reload", role: .destructive) {
                if let encoding = pendingEncoding { model.reinterpret(as: encoding) }
            }
        } message: {
            Text("Unsaved changes will be lost.")
        }
    }

    private var header: some View {
        HStack {
            Image(systemName: model.item.kind.symbolName)
            VStack(alignment: .leading) {
                Text(model.item.name).font(.headline)
                Text(model.item.path).font(.caption).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
            }
            Spacer()
            Picker("Encoding", selection: Binding(
                get: { model.encoding },
                set: { encoding in
                    if model.isDirty { pendingEncoding = encoding } else { model.reinterpret(as: encoding) }
                })
            ) {
                ForEach(TextEncoding.all) { Text($0.name).tag($0) }
                if !TextEncoding.all.contains(model.encoding) { Text(model.encoding.name).tag(model.encoding) }
            }
            .frame(width: 200)
            .disabled(model.phase != .ready)
            Button("Close") {
                if model.isDirty { confirmClose = true } else { dismiss() }
            }
            .keyboardShortcut(.cancelAction)
            Button("Save") { model.save() }
                .keyboardShortcut("s", modifiers: .command)
                .buttonStyle(.borderedProminent)
                .disabled(model.phase != .ready || !model.isDirty || model.isSaving)
        }
        .padding(10)
    }

    @ViewBuilder
    private var content: some View {
        switch model.phase {
        case .loading:
            ProgressView("Loading…").frame(maxWidth: .infinity, maxHeight: .infinity)
        case let .failed(message):
            ContentUnavailableView("Cannot open file", systemImage: "exclamationmark.triangle", description: Text(message))
        case .ready:
            CodeTextView(text: $model.text, fileName: model.item.name) { line, column in
                model.cursor = (line, column)
            }
        }
    }

    private var statusBar: some View {
        HStack(spacing: 16) {
            Text(SyntaxHighlighter.language(for: model.item.name))
            Text("Ln \(model.cursor.line), Col \(model.cursor.column)")
            Text("\(model.text.count) characters")
            Spacer()
            if model.isSaving { ProgressView().controlSize(.small) }
            if model.isDirty { Text("Modified").foregroundStyle(.orange) }
            Text("⌘F Find  ⌥⌘F Replace").foregroundStyle(.tertiary)
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .padding(.horizontal, 10)
        .padding(.vertical, 5)
    }
}

struct ImagePreviewView: View {
    let model: ImagePreviewModel
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            HStack {
                Text(model.item.name).font(.headline)
                Text(model.item.sizeText).foregroundStyle(.secondary)
                if let image = model.image {
                    Text("\(Int(image.size.width)) × \(Int(image.size.height))").foregroundStyle(.secondary)
                }
                Spacer()
                Button("Close") { dismiss() }.keyboardShortcut(.cancelAction)
            }
            .padding(10)
            Divider()
            Group {
                if let image = model.image {
                    Image(nsImage: image).resizable().scaledToFit().padding()
                } else if let error = model.error {
                    ContentUnavailableView("Cannot preview image", systemImage: "photo", description: Text(error))
                } else {
                    ProgressView()
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .frame(minWidth: 520, idealWidth: 800, minHeight: 420, idealHeight: 640)
    }
}
