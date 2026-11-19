import SwiftUI

struct MacFaceCorrection:View {
    @EnvironmentObject var model:MacModel
    @Environment(\.dismiss) private var dismiss
    let person:RemoteGroup
    @State private var faces:[PersonFace] = []
    @State private var selected = Set<Int>()
    @State private var confirming = false
    @State private var busy = false
    @State private var failure:String?
    var body:some View {
        VStack {
            HStack {Text("Correct face grouping").font(.title2.bold()); Spacer(); Button("Done") {dismiss()}}.padding()
            Text("Select faces that are not this person.").foregroundStyle(.secondary)
            ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:90))]) {ForEach(faces) {face in
                MacCover(source:face.thumbnailSource).aspectRatio(1,contentMode:.fit).clipShape(RoundedRectangle(cornerRadius:8))
                    .overlay {RoundedRectangle(cornerRadius:8).strokeBorder(selected.contains(face.id) ? Color.accentColor : .clear,lineWidth:3)}
                    .onTapGesture {if selected.contains(face.id) {selected.remove(face.id)} else {selected.insert(face.id)}}
            }}.padding()}
            if let failure {Text(failure).foregroundStyle(.red).padding()}
            Button("Separate Selected Faces…") {confirming = true}.disabled(selected.isEmpty || busy).padding()
        }.frame(width:620,height:540).task {await load()}.overlay {if busy {ProgressView()}}
        .alert("Separate these faces?",isPresented:$confirming) {Button("Cancel",role:.cancel){}; Button("Separate") {Task {guard let client = model.client else {return}; busy = true; defer {busy = false}; do {try await client.separateFaces(person:person.id,faces:Array(selected),shared:model.shared); selected = []; await load(); await model.loadSection()} catch {failure = error.localizedDescription}}}} message:{Text("The selected faces leave this person’s group. Photos are not deleted.")}
    }
    private func load() async {guard let client = model.client else {return}; busy = true; defer {busy = false}; do {faces = try await client.personFaces(person:person.id,shared:model.shared)} catch {failure = error.localizedDescription}}
}
struct MacHiddenPeople:View {
    @EnvironmentObject var model:MacModel
    @Environment(\.dismiss) private var dismiss
    @State private var people:[RemoteGroup] = []
    @State private var failure:String?
    var body:some View {
        VStack {
            HStack {Text("Hidden People").font(.title2.bold()); Spacer(); Button("Done") {dismiss()}}.padding()
            List(people) {person in HStack {Text(person.name.isEmpty ? "Unnamed" : person.name); Spacer(); Button("Unhide") {Task {guard let client = model.client else {return}; do {try await client.showPerson(id:person.id,shared:model.shared,visible:true); await load(); await model.loadSection()} catch {failure = error.localizedDescription}}}}}
            if let failure {Text(failure).foregroundStyle(.red).padding()}
        }.frame(width:460,height:450).task {await load()}
    }
    private func load() async {guard let client = model.client else {return}; do {let all = try await client.allPeople(shared:model.shared,includeHidden:true), visible = Set(try await client.allPeople(shared:model.shared).map(\.id)); people = all.filter{!visible.contains($0.id)}} catch {failure = error.localizedDescription}}
}
struct MacPersonCover:View {
    @EnvironmentObject var model:MacModel
    @Environment(\.dismiss) private var dismiss
    let person:RemoteGroup
    @State private var photos:[RemotePhoto] = []
    @State private var failure:String?
    var body:some View {
        VStack {
            HStack {Text("Choose Person Cover").font(.title2.bold()); Spacer(); Button("Cancel") {dismiss()}}.padding()
            ScrollView {LazyVGrid(columns:[GridItem(.adaptive(minimum:130))]) {ForEach(photos) {photo in MacThumbnail(photo:photo).aspectRatio(1,contentMode:.fit).onTapGesture {Task {guard let client = model.client else {return}; do {try await client.personCover(person:person.id,photo:photo.id,shared:model.shared); await model.loadSection(); dismiss()} catch {failure = error.localizedDescription}}}}}.padding()}
            if let failure {Text(failure).foregroundStyle(.red).padding()}
        }.frame(width:650,height:550).task {guard let client = model.client else {return}; do {var offset = 0; while true {let page = try await client.items(.person(person.id),shared:model.shared,offset:offset); try Task.checkCancellation(); photos += page; offset += page.count; if page.count < DSMClient.pageSize {break}}} catch {if !isCancelledRequest(error) {failure = error.localizedDescription}}}
    }
}
