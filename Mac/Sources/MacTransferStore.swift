import Foundation
import SQLite3

/// One durable row per transfer avoids rewriting an entire large-library history on every upload.
final class MacTransferStore {
    private var database:OpaquePointer?
    init(directory:URL) throws {
        try FileManager.default.createDirectory(at:directory,withIntermediateDirectories:true)
        let result = sqlite3_open_v2(directory.appendingPathComponent("transfers.sqlite").path,&database,SQLITE_OPEN_READWRITE | SQLITE_OPEN_CREATE | SQLITE_OPEN_FULLMUTEX,nil)
        do {
            guard result == SQLITE_OK else {throw FeatureError.message("Couldn’t open the backup history.")}
            try execute("PRAGMA journal_mode=WAL")
            try execute("PRAGMA synchronous=FULL")
            try execute("CREATE TABLE IF NOT EXISTS transfers (id TEXT PRIMARY KEY NOT NULL, payload BLOB NOT NULL)")
        } catch {sqlite3_close(database); database = nil; throw error}
    }
    deinit {sqlite3_close(database)}
    private func execute(_ sql:String) throws {guard sqlite3_exec(database,sql,nil,nil,nil) == SQLITE_OK else {throw FeatureError.message("Couldn’t save the backup history. Check available disk space.")}}
    func load() throws -> [MacTransfer] {
        var statement:OpaquePointer?; guard sqlite3_prepare_v2(database,"SELECT payload FROM transfers ORDER BY rowid",-1,&statement,nil) == SQLITE_OK else {throw ConnectionError.invalidResponse}
        defer {sqlite3_finalize(statement)}; var result:[MacTransfer] = []
        while true {
            let status = sqlite3_step(statement)
            if status == SQLITE_DONE {return result}
            guard status == SQLITE_ROW, let bytes = sqlite3_column_blob(statement,0) else {throw ConnectionError.invalidResponse}
            result.append(try JSONDecoder().decode(MacTransfer.self,from:Data(bytes:bytes,count:Int(sqlite3_column_bytes(statement,0)))))
        }
    }
    func save(_ record:MacTransfer) throws {
        let data = try JSONEncoder().encode(record)
        var statement:OpaquePointer?; guard sqlite3_prepare_v2(database,"INSERT INTO transfers(id,payload) VALUES(?,?) ON CONFLICT(id) DO UPDATE SET payload=excluded.payload",-1,&statement,nil) == SQLITE_OK else {throw ConnectionError.invalidResponse}
        defer {sqlite3_finalize(statement)}
        let transient = unsafeBitCast(-1,to:sqlite3_destructor_type.self)
        guard sqlite3_bind_text(statement,1,record.id.uuidString,-1,transient) == SQLITE_OK else {throw ConnectionError.invalidResponse}
        try data.withUnsafeBytes {bytes in
            guard sqlite3_bind_blob(statement,2,bytes.baseAddress,Int32(bytes.count),transient) == SQLITE_OK, sqlite3_step(statement) == SQLITE_DONE else {throw FeatureError.message("Couldn’t save backup progress. Check available disk space.")}
        }
    }
    func importLegacy(_ records:[MacTransfer]) throws {
        try execute("BEGIN IMMEDIATE")
        do {for record in records {try save(record)}; try execute("COMMIT")} catch {try? execute("ROLLBACK"); throw error}
    }
}
enum MacBackupProgress {
    static func key(asset:String,shared:Bool) -> String { (shared ? "shared|" : "personal|") + asset }
    static func counts(records:[MacTransfer],expected:[String:Set<String>]) -> (complete:Int,total:Int) {
        let groups = Dictionary(grouping:records,by:{key(asset:$0.localAssetID ?? $0.id.uuidString,shared:$0.shared)})
        let complete = groups.filter {key,values in values.allSatisfy{$0.state == .complete} && (expected[key]?.isSubset(of:Set(values.compactMap(\.resourceKey))) ?? true)}.count
        return (complete,Set(groups.keys).union(expected.keys).count)
    }
}
