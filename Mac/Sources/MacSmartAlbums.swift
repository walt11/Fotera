import SwiftUI

struct MacSmartRule:Codable,Identifiable {
    var id = UUID()
    var title = ""
    var query = ""
    var media = "All"
    var year = 0
    var personID:Int?
    var tag = ""
    var shared = false
    func matches(_ photos:[RemotePhoto],remoteIDs:Set<Int>?) -> [RemotePhoto] {
        LocalLibrarySearch.results(photos,query:query,media:LibraryMediaFilter(rawValue:media) ?? .all,year:year == 0 ? nil : year)
            .filter {(personID == nil && tag.isEmpty) || remoteIDs?.contains($0.id) == true}
    }
}
struct MacSmartAlbums:View {
    @EnvironmentObject var model:MacModel
    @State private var rules:[MacSmartRule] = []
    @State private var editing:MacSmartRule?
    @State private var busy = false
    @State private var failure:String?
    private var key:String {"mac.smartAlbums." + LibraryCache.hash(model.account)}
    var body:some View {
        VStack(alignment:.leading) {
            HStack {Text("Smart Albums").font(.title2.bold()); Spacer(); Button("New Smart Album…") {editing = MacSmartRule(shared:model.shared)}}.padding()
            Text("Rules stay on this Mac. Open an album to apply its rules to the current library.").foregroundStyle(.secondary).padding(.horizontal)
            List(rules.filter{$0.shared == model.shared}) {rule in
                Button {Task {await open(rule)}} label:{Label(rule.title,systemImage:"sparkles.rectangle.stack")}.buttonStyle(.plain)
                    .contextMenu {Button("Edit…") {editing = rule}; Button("Delete Rule",role:.destructive) {rules.removeAll{$0.id == rule.id}; save()}}
            }.disabled(busy)
            if let failure {Text(failure).foregroundStyle(.red).padding()}
        }.overlay {if busy {ProgressView()}}
        .task(id:key) {rules = UserDefaults.standard.data(forKey:key).flatMap{try? JSONDecoder().decode([MacSmartRule].self,from:$0)} ?? []}
        .sheet(item:$editing) {rule in MacSmartEditor(rule:rule) {value in rules.removeAll{$0.id == value.id}; rules.append(value); save()}.environmentObject(model)}
    }
    private func save() {do {UserDefaults.standard.set(try JSONEncoder().encode(rules),forKey:key)} catch {failure = error.localizedDescription}}
    private func open(_ rule:MacSmartRule) async {
        guard let client = model.client else {return}
        let account = model.account; busy = true; failure = nil; defer {busy = false}
        do {
            var ids:Set<Int>?
            if let person = rule.personID {
                var offset = 0; var found = Set<Int>()
                while true {let page = try await client.items(.person(person),shared:rule.shared,offset:offset); try Task.checkCancellation(); found.formUnion(page.map(\.id)); offset += page.count; if page.count < DSMClient.pageSize {break}}
                ids = found
            }
            if !rule.tag.isEmpty {
                var offset = 0; var tagged = Set<Int>()
                while true {
                    let page = try await client.search(keyword:rule.tag,shared:rule.shared,offset:offset)
                    for photo in page where ids == nil || ids!.contains(photo.id) {
                        try Task.checkCancellation()
                        if try await client.photoTags(id:photo.id,shared:rule.shared).contains(where:{$0.name.localizedCaseInsensitiveCompare(rule.tag) == .orderedSame}) {tagged.insert(photo.id)}
                    }
                    offset += page.count; if page.count < 100 {break}
                }; ids = tagged
            }
            guard model.account == account, model.shared == rule.shared else {return}
            model.query = ""; model.media = .all; model.locationFilter = .all; model.selection = []
            model.collection = rule.matches(model.photos,remoteIDs:ids); model.collectionTitle = rule.title; model.collectionSpace = rule.shared
        } catch {if !isCancelledRequest(error) {failure = error.localizedDescription}}
    }
}
struct MacSmartEditor:View {
    @EnvironmentObject var model:MacModel
    @Environment(\.dismiss) private var dismiss
    @State var rule:MacSmartRule
    var saved:(MacSmartRule)->Void
    @State private var people:[RemoteGroup] = []
    @State private var failure:String?
    var body:some View {
        VStack {
            Form {
                TextField("Album name",text:$rule.title)
                TextField("Filename or date contains",text:$rule.query)
                Picker("Media",selection:$rule.media) {ForEach(LibraryMediaFilter.allCases) {Text($0.rawValue).tag($0.rawValue)}}
                Picker("Year",selection:$rule.year) {Text("All years").tag(0); ForEach((1900...Calendar.current.component(.year,from:Date())).reversed(),id:\.self) {Text(String($0)).tag($0)}}
                Picker("Person",selection:$rule.personID) {Text("Anyone").tag(Int?.none); ForEach(people) {Text($0.name.isEmpty ? "Unnamed person \($0.id)" : $0.name).tag(Optional($0.id))}}
                TextField("Tag",text:$rule.tag)
                if let failure {Text(failure).foregroundStyle(.red)}
            }.formStyle(.grouped)
            HStack {Button("Cancel") {dismiss()}; Spacer(); Button("Save") {rule.title = rule.title.trimmingCharacters(in:.whitespacesAndNewlines); rule.tag = rule.tag.trimmingCharacters(in:.whitespacesAndNewlines); saved(rule); dismiss()}.disabled(rule.title.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)}.padding()
        }.frame(width:460,height:420).task {guard let client = model.client else {return}; do {people = try await client.allPeople(shared:rule.shared)} catch {failure = error.localizedDescription}}
    }
}
