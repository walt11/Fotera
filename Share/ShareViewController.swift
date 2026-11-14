import UIKit
import SwiftUI
import UniformTypeIdentifiers

/// "Upload to Fotera" in the share sheet. Shared photos and videos are saved to the App Group inbox
/// and uploaded to the Upload to NAS folder the next time Fotera opens. The extension never touches
/// the NAS or your sign-in.
final class ShareViewController: UIViewController {
    override func viewDidLoad() {
        super.viewDidLoad()
        let model = ShareModel(context: extensionContext)
        let host = UIHostingController(rootView: ShareView(model: model))
        addChild(host)
        host.view.frame = view.bounds
        host.view.autoresizingMask = [.flexibleWidth, .flexibleHeight]
        view.addSubview(host.view)
        host.didMove(toParent: self)
        Task { await model.collect() }
    }
}

@MainActor final class ShareModel: ObservableObject {
    @Published var saved = 0
    @Published var failed = 0
    @Published var done = false
    let context: NSExtensionContext?
    init(context: NSExtensionContext?) { self.context = context }
    func collect() async {
        let providers = (context?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        for provider in providers {
            guard let type = [UTType.movie, .image, .data].first(where: { provider.hasItemConformingToTypeIdentifier($0.identifier) }) else { failed += 1; continue }
            if await Self.save(provider, type: type) { saved += 1 } else { failed += 1 }
        }
        done = true
    }
    /// The provided file is only valid inside the callback, so it's copied there.
    private static func save(_ provider: NSItemProvider, type: UTType) async -> Bool {
        await withCheckedContinuation { continuation in
            _ = provider.loadFileRepresentation(forTypeIdentifier: type.identifier) { url, _ in
                guard let url else { continuation.resume(returning: false); return }
                continuation.resume(returning: (try? ShareInbox.add(url)) != nil)
            }
        }
    }
    func finish() { context?.completeRequest(returningItems: nil) }
}

struct ShareView: View {
    @ObservedObject var model: ShareModel
    var body: some View {
        NavigationStack {
            VStack(spacing: 16) {
                if !model.done {
                    ProgressView("Adding to Fotera…")
                } else {
                    Image(systemName: model.saved > 0 ? "checkmark.circle.fill" : "exclamationmark.triangle.fill")
                        .font(.system(size: 48)).foregroundStyle(model.saved > 0 ? .green : .orange)
                    Text(model.saved > 0 ? "\(model.saved) \(model.saved == 1 ? "item" : "items") added" : "Nothing could be added")
                        .font(.title3.bold())
                    Text(detail).multilineTextAlignment(.center).foregroundStyle(.secondary)
                }
            }
            .padding(24)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .navigationTitle("Upload to Fotera").navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { model.finish() }.disabled(!model.done) } }
        }
    }
    private var detail: String {
        let folder = ShareInbox.uploadFolder
        var text = folder.isEmpty
            ? "Open Fotera and choose a folder in Upload to NAS. Your items will upload after that."
            : "They’ll upload to \(folder) the next time you open Fotera."
        if model.failed > 0 { text += " \(model.failed) couldn’t be read." }
        return text
    }
}
