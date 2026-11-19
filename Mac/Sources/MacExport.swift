import AppKit
import Photos

@MainActor enum MacExport {
    static func original(_ photo:RemotePhoto,client:DSMClient?,shared:Bool) async throws -> URL {
        if ProcessInfo.processInfo.arguments.contains("--demo"), let root = Bundle.main.url(forResource:"DemoAssets",withExtension:nil) {
            let target = FileManager.default.temporaryDirectory.appendingPathComponent(UUID().uuidString + ".png")
            try FileManager.default.copyItem(at:root.appendingPathComponent("\(abs(photo.id)).png"),to:target)
            return target
        }
        if let asset = MacLocalPhotos.asset(photo) {
            let resources = PHAssetResource.assetResources(for:asset)
            let type:PHAssetResourceType = asset.mediaType == .video ? .video : .photo
            guard let resource = resources.first(where:{$0.type == type}) else {throw FeatureError.message("This original is unavailable in Apple Photos.")}
            let directory = FileManager.default.temporaryDirectory.appendingPathComponent("Fotera-export-" + UUID().uuidString)
            try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
            let target = directory.appendingPathComponent((resource.originalFilename as NSString).lastPathComponent)
            let options = PHAssetResourceRequestOptions(); options.isNetworkAccessAllowed = true
            do {
                try await withCheckedThrowingContinuation {(continuation:CheckedContinuation<Void,Error>) in
                    PHAssetResourceManager.default().writeData(for:resource,toFile:target,options:options) {error in if let error {continuation.resume(throwing:error)} else {continuation.resume()}}
                }
                return target
            } catch {try? FileManager.default.removeItem(at:directory); throw error}
        }
        guard let client else {throw ConnectionError.signedOut}
        return try await client.original(photo,shared:shared)
    }
}

import SwiftUI

@MainActor final class MacSharing:NSObject,NSSharingServicePickerDelegate,NSSharingServiceDelegate {
    private var preparing = false
    private var picker:NSSharingServicePicker?
    private var directory:URL?
    private var task:Task<Void,Never>?
    private weak var model:MacModel?
    func present(_ items:[RemotePhoto],model:MacModel,anchor:NSView) {
        guard !items.isEmpty, !preparing, picker == nil else {return}
        self.model = model
        let client = model.client
        guard client != nil || ProcessInfo.processInfo.arguments.contains("--demo") || items.allSatisfy({$0.localAssetID != nil}) else {model.error = "Connect to your NAS to share originals."; return}
        let account = model.account, space = model.activeSpace
        preparing = true
        task = Task {
            defer {preparing = false; task = nil}
            do {
                let root = FileManager.default.temporaryDirectory.appendingPathComponent("Fotera-Share-" + UUID().uuidString)
                try FileManager.default.createDirectory(at:root,withIntermediateDirectories:true); directory = root
                var files:[URL] = []
                for (index,photo) in items.enumerated() {
                    try Task.checkCancellation()
                    guard model.account == account else {throw CancellationError()}
                    model.toast("Preparing photo \(index + 1) of \(items.count)")
                    let source = try await MacExport.original(photo,client:client,shared:space)
                    defer {try? FileManager.default.removeItem(at:source)}
                    let destination = root.appendingPathComponent("\(index)",isDirectory:true)
                    try FileManager.default.createDirectory(at:destination,withIntermediateDirectories:true)
                    let target = destination.appendingPathComponent((photo.filename as NSString).lastPathComponent)
                    try FileManager.default.copyItem(at:source,to:target); files.append(target)
                }
                guard model.account == account, anchor.window != nil else {throw CancellationError()}
                let picker = NSSharingServicePicker(items:files); picker.delegate = self; self.picker = picker
                picker.show(relativeTo:anchor.bounds,of:anchor,preferredEdge:.minY)
            } catch {cleanup(); if !isCancelledRequest(error) {model.error = error.localizedDescription}}
        }
    }
    func cancelPreparation() {task?.cancel()}
    nonisolated func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,didChoose service:NSSharingService?) {
        if service == nil {Task {@MainActor in self.cleanup()}}
    }
    nonisolated func sharingServicePicker(_ sharingServicePicker:NSSharingServicePicker,delegateFor sharingService:NSSharingService) -> NSSharingServiceDelegate? {self}
    nonisolated func sharingService(_ sharingService:NSSharingService,didShareItems items:[Any]) {Task {@MainActor in self.cleanup()}}
    nonisolated func sharingService(_ sharingService:NSSharingService,didFailToShareItems items:[Any],error:Error) {
        let message = isCancelledRequest(error) ? nil : error.localizedDescription
        Task {@MainActor in self.cleanup(); if let message {self.model?.error = message}}
    }
    private func cleanup() {picker = nil; if let directory {try? FileManager.default.removeItem(at:directory)}; directory = nil}
}
struct MacShareButton:NSViewRepresentable {
    @EnvironmentObject var model:MacModel
    let items:[RemotePhoto]
    func makeCoordinator() -> Coordinator {Coordinator()}
    func makeNSView(context:Context) -> NSButton {
        let button = NSButton(title:"Share…",target:context.coordinator,action:#selector(Coordinator.share(_:)))
        button.bezelStyle = .rounded; return button
    }
    func updateNSView(_ button:NSButton,context:Context) {
        context.coordinator.model = model; context.coordinator.items = items
        button.isEnabled = !items.isEmpty
    }
    @MainActor final class Coordinator:NSObject {
        weak var model:MacModel?
        var items:[RemotePhoto] = []
        @objc func share(_ sender:NSButton) {guard let model else {return}; model.sharing.present(items,model:model,anchor:sender)}
    }
}
