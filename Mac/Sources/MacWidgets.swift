import SwiftUI
import WidgetKit

struct MacWidgetChoice:Codable,Equatable {
    let id:Int
    let title:String
    let kind:String
    let shared:Bool
    var filter:ItemFilter {kind == "person" ? .person(id) : .album(id)}
    static func key(account:String,kind:String) -> String {"mac.widget.source." + LibraryCache.hash(account) + "." + kind}
    static func read(account:String,kind:String,defaults:UserDefaults = .standard) -> Self? {
        defaults.data(forKey:key(account:account,kind:kind)).flatMap{try? JSONDecoder().decode(Self.self,from:$0)}
    }
    func save(account:String,defaults:UserDefaults = .standard) throws {defaults.set(try JSONEncoder().encode(self),forKey:Self.key(account:account,kind:kind))}
    static func remove(account:String,kind:String,defaults:UserDefaults = .standard) {defaults.removeObject(forKey:key(account:account,kind:kind))}
}
@MainActor enum MacWidgetWriter {
    static var photosEnabled:Bool {UserDefaults.standard.object(forKey:"mac.widget.photosEnabled") as? Bool ?? true}
    static func refresh(model:MacModel) async {
        guard WidgetSnapshotStore.isAvailable, photosEnabled else {return}
        let account = model.account, space = model.shared
        let prior = UserDefaults.standard.string(forKey:"mac.widget.account")
        if prior != account {try? WidgetSnapshotStore.clear(); UserDefaults.standard.set(account,forKey:"mac.widget.account")}
        let calendar = WidgetMemorySchedule.calendar(), now = Date()
        var days:[String:[WidgetSnapshot]] = [:]
        for offset in 0..<7 {
            guard let date = calendar.date(byAdding:.day,value:offset,to:now) else {continue}
            var snapshots:[WidgetSnapshot] = []
            for photo in MacModel.memories(model.photos,now:date).filter({!$0.isVideo}).prefix(6) {
                guard model.account == account, !Task.isCancelled else {return}
                if let image = await MacImages.shared.image(photo,model:model,space:space) {
                    let years = calendar.component(.year,from:date) - PhotoTime.calendar.component(.year,from:photo.date ?? date)
                    snapshots.append(.init(title:years == 1 ? "1 year ago" : "\(years) years ago",image:WidgetSnapshot.previewData(image),date:date))
                }
            }
            days[WidgetMemorySchedule.dayKey(date)] = snapshots
        }
        var fallback:[WidgetSnapshot] = []
        for photo in model.photos.filter({!$0.isVideo}).prefix(6) {
            if let image = await MacImages.shared.image(photo,model:model,space:space) {fallback.append(.init(title:photo.date.map{PhotoTime.format($0,.dateTime.month().day().year())} ?? "From your library",image:WidgetSnapshot.previewData(image),date:now))}
        }
        guard model.account == account, model.shared == space, photosEnabled, !Task.isCancelled else {return}
        try? WidgetSnapshotStore.saveMemorySchedule(.init(days:days,fallback:fallback))
        WidgetCenter.shared.reloadTimelines(ofKind:"FoteraPhoto")
        guard let client = model.client else {return}
        for kind in ["album","person"] {
            guard photosEnabled, model.account == account, !Task.isCancelled else {return}
            guard let choice = MacWidgetChoice.read(account:account,kind:kind) else {continue}
            do {
                let items = try await client.items(choice.filter,shared:choice.shared,offset:0,limit:6)
                guard model.account == account, !Task.isCancelled else {return}
                try await collection(items,title:choice.title,kind:kind,model:model,space:choice.shared,expected:choice)
            } catch {
                if let failure = error as? ConnectionError, case .server = failure, model.account == account {
                    try? WidgetSnapshotStore.saveFeed([],kind:kind)
                    WidgetCenter.shared.reloadTimelines(ofKind:"FoteraCollection-" + kind)
                }
            }
        }
    }
    static func collection(_ photos:[RemotePhoto],title:String,kind:String,model:MacModel,space:Bool,expected:MacWidgetChoice? = nil) async throws {
        let account = model.account
        var snapshots:[WidgetSnapshot] = []
        for photo in photos.filter({!$0.isVideo}).prefix(6) {if let image = await MacImages.shared.image(photo,model:model,space:space) {snapshots.append(.init(title:title,image:WidgetSnapshot.previewData(image),date:Date()))}}
        guard photosEnabled, account == model.account, !Task.isCancelled else {throw CancellationError()}
        if let expected, MacWidgetChoice.read(account:account,kind:kind) != expected {throw CancellationError()}
        try WidgetSnapshotStore.saveFeed(snapshots,kind:kind); WidgetCenter.shared.reloadTimelines(ofKind:"FoteraCollection-" + kind)
    }
    static func backup(_ queue:MacBackupQueue) {
        guard WidgetSnapshotStore.isAvailable else {return}
        let status = queue.paused ? "Paused" : queue.running ? "Backing up" : queue.records.contains(where:{$0.state == .failed}) ? "Needs attention" : queue.completedPhotos == queue.totalPhotos ? "Up to date" : "Waiting"
        WidgetSnapshotStore.saveBackup(.init(status:status,completed:queue.completedPhotos,total:queue.totalPhotos,updated:Date()))
        WidgetCenter.shared.reloadTimelines(ofKind:"FoteraBackup")
    }
}


struct MacWidgetSettings:View {
    @EnvironmentObject var model:MacModel
    @AppStorage("mac.widget.photosEnabled") private var enabled = true
    @State private var choices:[MacWidgetChoice] = []
    var body:some View {
        Toggle("Show photos in widgets",isOn:$enabled).onChange(of:enabled) {_,value in
            if value {Task {await MacWidgetWriter.refresh(model:model)}}
            else {do {try WidgetSnapshotStore.clear(); WidgetCenter.shared.reloadAllTimelines()} catch {model.error = error.localizedDescription}}
        }
        Text("Widgets store small previews on this Mac. Turn this off to remove them.").font(.caption).foregroundStyle(.secondary)
        ForEach(choices,id:\.kind) {choice in
            HStack {
                LabeledContent(choice.kind == "album" ? "Album" : "Person",value:choice.title)
                Button("Clear") {
                    MacWidgetChoice.remove(account:model.account,kind:choice.kind)
                    do {try WidgetSnapshotStore.saveFeed([],kind:choice.kind); WidgetCenter.shared.reloadTimelines(ofKind:"FoteraCollection-" + choice.kind); reload()} catch {model.error = error.localizedDescription}
                }
            }
        }
        if choices.isEmpty {Text("Choose an album or person from its right-click menu.").font(.caption).foregroundStyle(.secondary)}
        Color.clear.frame(height:0).task(id:model.account) {reload()}
    }
    private func reload() {choices = ["album","person"].compactMap{MacWidgetChoice.read(account:model.account,kind:$0)}}
}
