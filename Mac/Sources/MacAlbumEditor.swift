import SwiftUI
import AppKit

struct MacNewAlbumEditor: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    @FocusState private var nameFocused:Bool
    let items:[RemotePhoto]
    @State private var name = ""
    @State private var busy = false
    @State private var failure:String?
    @State private var createdID:Int?
    private var cleanName:String {name.trimmingCharacters(in:.whitespacesAndNewlines)}
    private var eligible:[RemotePhoto] {items.filter{!$0.isLocalOnly && $0.passphrase == nil}}
    var body:some View {
        VStack(alignment:.leading,spacing:18) {
            Text("New Album").font(.title2.bold())
            TextField("Album name",text:$name).textFieldStyle(.roundedBorder).focused($nameFocused)
                .accessibilityIdentifier("album.name").disabled(busy || createdID != nil)
                .onSubmit {if !cleanName.isEmpty && !busy {Task {await save()}}}
            Text(eligible.isEmpty ? "Create an empty album." : "Add \(eligible.count) selected photos.").foregroundStyle(.secondary)
            if eligible.count != items.count {Text("Only photos in your NAS library can be added.").font(.caption).foregroundStyle(.secondary)}
            if let failure {Text(failure).foregroundStyle(.red).textSelection(.enabled).accessibilityIdentifier("album.error")}
            HStack {
                if busy {ProgressView().controlSize(.small); Text("Saving…").foregroundStyle(.secondary)}
                Spacer()
                Button("Cancel") {dismiss()}.keyboardShortcut(.cancelAction).disabled(busy)
                Button(createdID == nil ? "Create" : "Check Album") {Task {await save()}}
                    .keyboardShortcut(.defaultAction).disabled(cleanName.isEmpty || busy)
                    .accessibilityIdentifier("album.create")
            }
        }.padding(24).frame(width:420).interactiveDismissDisabled(busy)
            .onAppear {nameFocused = true}
    }
    private func save() async {
        guard !busy, !cleanName.isEmpty else {return}
        guard !model.activeSpace else {failure = "Create albums in Personal Space."; return}
        busy = true; failure = nil; defer {busy = false}
        let account = model.account
        do {
            let result:[RemoteAlbum]
            if ProcessInfo.processInfo.arguments.contains("--demo") {
                let album = RemoteAlbum(id:(model.albums.map(\.id).max() ?? 0) + 1,name:cleanName,item_count:eligible.count,additional:nil)
                createdID = album.id; result = model.albums + [album]
            } else {
                guard let client = model.client else {throw FeatureError.message("Connect to your NAS before creating an album.")}
                if createdID == nil {createdID = try await client.createAlbum(name:cleanName,items:eligible.map(\.id))}
                guard let id = createdID else {throw FeatureError.message("The NAS did not confirm album creation.")}
                result = try await client.allAlbums()
                guard result.contains(where:{$0.id == id}) else {throw FeatureError.message("The album was created, but has not appeared in the NAS list yet. Check again.")}
            }
            guard model.account == account else {throw FeatureError.message("The connected account changed. Check the album in the original account.")}
            model.navigate(.albums); model.albums = result; model.toast("Album created"); dismiss()
        } catch {failure = createdID == nil ? error.localizedDescription : "Album created; couldn’t refresh the list. " + error.localizedDescription}
    }
}

struct MacAlbumEditor: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let album: RemoteAlbum
    @State private var name = ""
    @State private var state: AlbumSharingState?
    @State private var members: [AlbumShareMember] = []
    @State private var memberID = -1
    @State private var role: AlbumShareRole = .view
    @State private var password = ""
    @State private var allowDownloads = false
    @State private var expires = false
    @State private var expiration = Date().addingTimeInterval(604800)
    @State private var busy = false
    @State private var error: String?
    @State private var deleting = false
    @State private var publishing = false
    private var publicEnabled: Bool { state?.shared == true && state?.additional?.sharing_info?.privacy_type?.hasPrefix("public-") == true }
    var body: some View {
        VStack {
            HStack { Text("Album settings").font(.title2.bold()); Spacer(); Button("Done") { dismiss() } }.padding()
            Form {
                Section("Album") {
                    TextField("Name",text:$name)
                    Button("Save name") { perform { client in try await client.renameAlbum(id:album.id,name:name); model.albums = try await client.allAlbums() } }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
                    Button("Delete Album…",role:.destructive) { deleting = true }
                }
                Section("People with access") {
                    if state?.shared == true, let permissions = state?.additional?.sharing_info?.permission {
                        ForEach(permissions.filter{$0.member.type == "user" && $0.role != "owner"},id:\.member.id) { entry in
                            HStack {
                                Text(members.first{$0.id == entry.member.id}?.name ?? "User \(entry.member.id ?? 0)")
                                Spacer(); Text(entry.role).foregroundStyle(.secondary)
                                Button("Remove") { if let member = members.first(where:{$0.id == entry.member.id}) { perform { client in state = try await client.updateAlbumMember(id:album.id,member:member,role:nil) } } }
                            }
                        }
                    }
                    Picker("Account",selection:$memberID) { Text("Choose an account").tag(-1); ForEach(members) { Text($0.name).tag($0.id) } }
                    Picker("Permission",selection:$role) { ForEach(AlbumShareRole.allCases) { Text($0.title).tag($0) } }
                    Button("Invite") { if let member = members.first(where:{$0.id == memberID}) { perform { client in state = try await client.updateAlbumMember(id:album.id,member:member,role:role) } } }.disabled(memberID == -1 || state == nil)
                }
                Section("Share a link") {
                    if publicEnabled, let string = state?.additional?.sharing_info?.sharing_link, let url = URL(string:string), ["https","http"].contains(url.scheme ?? "") {
                        HStack { ShareLink(item:url); Button("Copy Link") { NSPasteboard.general.clearContents(); NSPasteboard.general.setString(url.absoluteString,forType:.string) } }
                    }
                    Toggle("Allow downloads",isOn:$allowDownloads)
                    SecureField("Password (optional)",text:$password)
                    Toggle("Expiration date",isOn:$expires)
                    if expires { DatePicker("Expires",selection:$expiration,in:Date()...,displayedComponents:.date) }
                    Text("Anyone with the link can access this album. Leaving the password blank removes existing password protection.").font(.caption).foregroundStyle(.secondary)
                    Button(publicEnabled ? "Update Link…" : "Create Link…") { publishing = true }.disabled(state == nil)
                    if publicEnabled { Button("Turn Off Link") { perform { client in state = try await client.updateAlbumSharing(id:album.id,enabled:false,role:"view",password:"",expiration:nil) } } }
                }
                if let error { Text(error).foregroundStyle(.red).textSelection(.enabled) }
            }.formStyle(.grouped).disabled(busy)
        }.frame(width:570,height:720).overlay { if busy { ProgressView().padding().background(.regularMaterial,in:RoundedRectangle(cornerRadius:12)) } }
        .task { name = album.name; perform { client in state = try await client.albumSharing(id:album.id); members = try await client.albumSharingMembers(); allowDownloads = state?.additional?.sharing_info?.privacy_type == "public-download"; if let date = state?.additional?.sharing_info?.expiration, date > 0 { expiration = Date(timeIntervalSince1970:date); expires = true } } }
        .alert("Delete this album?",isPresented:$deleting) { Button("Cancel",role:.cancel){}; Button("Delete",role:.destructive) { perform { client in try await client.deleteAlbum(id:album.id); model.albums = try await client.allAlbums(); dismiss() } } } message:{Text("The photos remain in your library.")}
        .alert("Enable access by link?",isPresented:$publishing) { Button("Cancel",role:.cancel){}; Button("Save Link") { perform { client in state = try await client.updateAlbumSharing(id:album.id,enabled:true,role:allowDownloads ? "download" : "view",password:password,expiration:expires ? expiration : nil); password = "" } } } message:{Text("Anyone with the link and its password, if set, can access this album.")}
    }
    private func perform(_ action: @escaping (DSMClient) async throws -> Void) {
        guard let client = model.client, !busy else { return }; busy = true; error = nil
        Task { defer { busy = false }; do { try await action(client); let fresh = try await client.allAlbums(); if model.client === client {model.albums = fresh} } catch { self.error = error.localizedDescription } }
    }
}
struct MacPersonEditor: View {
    @EnvironmentObject var model: MacModel
    @Environment(\.dismiss) private var dismiss
    let person: RemoteGroup
    @State private var name = ""
    @State private var targetID = -1
    @State private var correctingFaces = false
    @State private var choosingCover = false
    @State private var merging = false
    @State private var busy = false
    @State private var failure: String?
    var body: some View {
        VStack(alignment:.leading,spacing:18) {
            Text("People").font(.title2.bold())
            TextField("Name",text:$name).textFieldStyle(.roundedBorder)
            Button("Save Name") { run { client in _ = try await client.renamePerson(id:person.id,name:name,shared:model.shared) } }.disabled(name.trimmingCharacters(in:.whitespacesAndNewlines).isEmpty)
            HStack {Button("Choose Cover…") {choosingCover = true}; Button("Correct Faces…") {correctingFaces = true}; Button("Hide Person") {run {client in try await client.showPerson(id:person.id,shared:model.shared,visible:false)}}}
            Divider()
            Picker("Merge with",selection:$targetID) { Text("Choose a person").tag(-1); ForEach(model.groups.filter{$0.id != person.id}) { Text($0.name.isEmpty ? "Unnamed person \($0.id)" : $0.name).tag($0.id) } }
            Button("Merge…") { merging = true }.disabled(targetID == -1)
            if let failure { Text(failure).foregroundStyle(.red) }
            HStack { if busy { ProgressView().controlSize(.small) }; Spacer(); Button("Done") { dismiss() } }
        }.padding(24).frame(width:450).disabled(busy).onAppear { name = person.name }
        .task { if let client = model.client, let prior = await client.savedPersonName(id:person.id,shared:model.shared), !prior.name.isEmpty, (!prior.confirmed || person.name.isEmpty), prior.name != person.name { name = prior.name; failure = "Previous entry recovered. Save Name to confirm it on the NAS." } }
        .sheet(isPresented:$correctingFaces) {MacFaceCorrection(person:person).environmentObject(model)}
        .sheet(isPresented:$choosingCover) {MacPersonCover(person:person).environmentObject(model)}
        .alert("Merge these people?",isPresented:$merging) { Button("Cancel",role:.cancel){}; Button("Merge") { if let target = model.groups.first(where:{$0.id == targetID}) { run { client in try await client.mergePeople(target:target,sources:[person.id],shared:model.shared) } } } } message:{Text("Their photos will be grouped under the selected person’s name.")}
    }
    private func run(_ action: @escaping (DSMClient) async throws -> Void) {
        guard let client = model.client else { return }; busy = true
        Task { defer {busy = false}; do { try await action(client); await model.loadSection(); dismiss() } catch { failure = error.localizedDescription } }
    }
}

#if DEBUG
struct MacAlbumContractProbe:Decodable {
    let id:Int?
    let problem:String?
    init(from decoder:Decoder) throws {
        let values = try decoder.container(keyedBy:Keys.self)
        id = try? values.decode(Int.self,forKey:.id)
        do {_ = try RemoteAlbum(from:decoder); problem = nil}
        catch DecodingError.typeMismatch(let type,let context) {problem = "Type mismatch: \(context.codingPath.map(\.stringValue).joined(separator:".")) expected \(type)"}
        catch DecodingError.keyNotFound(let key,let context) {problem = "Missing field: \(context.codingPath.map(\.stringValue).joined(separator:".")) \(key.stringValue)"}
        catch {problem = "Album decoding failed"}
    }
    enum Keys:String,CodingKey {case id}
}
extension MacModel {
    func auditAlbumContract() async {
        guard let client else {albumAudit = "AUDIT: no signed-in Mac session"; return}
        struct Page:Decodable {let list:[MacAlbumContractProbe]}
        do {
            let page = try await client.call("SYNO.Foto.Browse.Album",1,"list",["offset":"0","limit":"100","additional":"[\"thumbnail\"]"],as:Page.self)
            let issues = Set(page.list.compactMap(\.problem)).sorted()
            albumAudit = "AUDIT: \(page.list.count) albums; " + (issues.isEmpty ? "album decoding passed" : issues.joined(separator:"; "))
            if issues.isEmpty, ProcessInfo.processInfo.arguments.contains("--album-create-audit") {
                albumAudit = nil
                let name = "Fotera Album Verification " + UUID().uuidString
                guard let id = try await client.createAlbum(name:name,items:[]) else {throw ConnectionError.invalidResponse}
                do {
                    let albums = try await client.allAlbums()
                    guard albums.contains(where:{$0.id == id && $0.name == name}) else {throw ConnectionError.invalidResponse}
                    if ProcessInfo.processInfo.arguments.contains("--album-sharing-audit") {
                        _ = try await client.updateAlbumSharing(id:id,enabled:true,role:"view",password:UUID().uuidString,expiration:nil)
                        guard try await client.allAlbums().first(where:{$0.id == id})?.shared == true else {throw FeatureError.message("Shared badge missing while link is enabled")}
                        _ = try await client.updateAlbumSharing(id:id,enabled:false,role:"view",password:"",expiration:nil)
                        guard try await client.allAlbums().first(where:{$0.id == id})?.shared == false else {throw FeatureError.message("Shared badge remained after link removal")}
                    }
                    try await client.deleteAlbum(id:id)
                    albumAudit = "AUDIT: PASS — empty album sharing enabled and disabled, badge read back, test album removed"
                } catch {
                    try? await client.deleteAlbum(id:id)
                    throw error
                }
            }
        } catch {albumAudit = "AUDIT: " + error.localizedDescription}
    }
}
#endif
