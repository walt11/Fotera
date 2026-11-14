import ActivityKit
import Foundation

/// Only aggregate progress leaves the app: no photos, filenames, account names, or NAS addresses.
struct BackupActivityAttributes: ActivityAttributes {
    struct ContentState: Codable, Hashable {
        enum Phase: String, Codable { case preparing, uploading, verifying, waiting, paused, attention, complete }
        let completed: Int
        let total: Int
        let awaitingVerification: Int
        let phase: Phase
        var fraction: Double { total > 0 ? min(1, max(0, Double(completed) / Double(total))) : 0 }
        var percent: Int { Int(fraction * 100) }
        var title: String {
            switch phase {
            case .preparing: return "Preparing backup"
            case .uploading: return "Backing up photos"
            case .verifying: return "Verifying uploads"
            case .waiting: return "Backup waiting"
            case .paused: return "Backup paused"
            case .attention: return "Backup needs attention"
            case .complete: return "Backup complete"
            }
        }
        var symbol: String {
            switch phase {
            case .complete: return "checkmark.icloud"
            case .attention: return "exclamationmark.icloud"
            case .waiting, .paused: return "pause.circle"
            case .verifying: return "checkmark.shield"
            default: return "icloud.and.arrow.up"
            }
        }
    }
}
