import SwiftUI

struct MacOfflineEntry: Codable, Identifiable {
    var id: String { "\(shared)|\(photo.id)" }
    let photo: RemotePhoto
    let shared: Bool
    let bytes: Int64
}
extension OfflineVault {
    private func manifest(_ account:String) -> URL {MacFiles.support.appendingPathComponent("Originals/index-" + LibraryCache.hash(account) + ".json")}
    func entries(account:String) -> [MacOfflineEntry] {guard let data = try? Data(contentsOf:manifest(account)) else {return []}; return (try? JSONDecoder().decode([MacOfflineEntry].self,from:data)) ?? []}
    func remember(_ photo:RemotePhoto,account:String,shared:Bool,source:URL) throws {
        try save(source,account:account,shared:shared,id:photo.id)
        let entry = MacOfflineEntry(photo:photo,shared:shared,bytes:Int64((try source.resourceValues(forKeys:[.fileSizeKey])).fileSize ?? 0))
        var list = entries(account:account); list.removeAll{$0.id == entry.id}; list.append(entry)
        try JSONEncoder().encode(list).write(to:manifest(account),options:.atomic)
    }
    func remove(_ entry:MacOfflineEntry,account:String) throws {
        if let file = originalURL(account:account,shared:entry.shared,id:entry.photo.id) {try FileManager.default.removeItem(at:file)}
        try JSONEncoder().encode(entries(account:account).filter{$0.id != entry.id}).write(to:manifest(account),options:.atomic)
    }
}
extension MacModel {
    func keepAlbumOffline(_ album:RemoteAlbum) {
        guard let client else {return}; let key = account
        Task {
            do {
                var offset = 0, completed = 0
                while true {
                    let page = try await client.items(.album(album.id),shared:false,offset:offset)
                    for photo in page {
                        try Task.checkCancellation(); guard account == key else {return}
                        let file = photo.isLive ? try await client.livePackage(photo,shared:false) : try await client.original(photo,shared:false)
                        defer {try? FileManager.default.removeItem(at:file)}
                        try await OfflineVault.shared.remember(photo,account:key,shared:false,source:file); completed += 1
                        toast("Saved \(completed) photos offline")
                    }
                    offset += page.count; if page.count < DSMClient.pageSize {break}
                }
                if account == key {toast("Album available offline")}
            } catch {if account == key, !isCancelledRequest(error) {self.error = error.localizedDescription}}
        }
    }
    func keepOffline(_ photo:RemotePhoto) {
        guard let client, !photo.isLocalOnly, photo.passphrase == nil else {return}; let key = account, space = activeSpace
        Task {
            do {
                let file = photo.isLive ? try await client.livePackage(photo,shared:space) : try await client.original(photo,shared:space)
                defer {try? FileManager.default.removeItem(at:file)}
                try await OfflineVault.shared.remember(photo,account:key,shared:space,source:file)
                toast("Available offline")
            } catch {self.error = error.localizedDescription}
        }
    }
}
struct MacOfflineView: View {
    @EnvironmentObject var model:MacModel
    @State private var entries:[MacOfflineEntry] = []
    var body:some View {
        List(entries) {entry in
            HStack {
                Image(systemName:entry.photo.isVideo ? "video" : "photo")
                VStack(alignment:.leading) {Text(entry.photo.filename); Text(entry.shared ? "Shared Space" : "Personal Space").font(.caption).foregroundStyle(.secondary)}
                Spacer(); Text(ByteCountFormatter.string(fromByteCount:entry.bytes,countStyle:.file)).foregroundStyle(.secondary)
                Button("Open") {model.shared = entry.shared; model.viewer = entry.photo}
                Button("Remove Download") {Task {do {try await OfflineVault.shared.remove(entry,account:model.account); entries = await OfflineVault.shared.entries(account:model.account)} catch {model.error = error.localizedDescription}}}
            }.padding(.vertical,5)
        }.task(id:model.account) {entries = await OfflineVault.shared.entries(account:model.account)}
        .overlay {if entries.isEmpty {ContentUnavailableView("No offline photos",systemImage:"arrow.down.circle",description:Text("Right-click a NAS photo and choose Keep Offline."))}}
    }
}
