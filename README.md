# Fotera

A native SwiftUI iOS client for the Synology Photos library on the DS224+ at `https://pics.jwalter.net`. This is a feature-rich trial build, not a claim of complete Synology Photos parity or proven backup reliability under every failure condition.

## Open and run

1. Open `/Users/walt/Documents/IOS Apps/Fotera/Fotera.xcodeproj` in Xcode.
2. Select the **Fotera** scheme. The installed app is named **Fotera**.
3. Let Xcode resolve the pinned ZIPFoundation 0.9.20 package.
4. Select an iOS simulator or the paired iPhone and run. The minimum deployment target is iOS 17.
5. Both app and widget targets use automatic signing with the existing development team. The device identifiers remain `net.jwalter.PhotoHarbor` and `net.jwalter.PhotoHarbor.Memories`; the simulator uses `com.example.PhotoHarbor` and its `.Memories` extension.
6. App Groups must be enabled for both device targets with `group.net.jwalter.Fotera`. If provisioning fails, sign into Xcode Settings → Apple Accounts and select the development team on both targets. Do not change the app bundle identifier to resolve a signing error: that changes its Keychain identity.

The project folder is the source/build working directory. The old `outputs/PhotoHarbor` path is a compatibility symlink. The chat's saved directory has not been changed through an app tool.

## Using Fotera

- **Sign in** with a direct HTTPS DSM address, a local HTTP address (for example `http://192.168.68.66:10004`), or a QuickConnect ID (for example `jwaltnas`). HTTP is limited to private/local addresses and is unencrypted. QuickConnect resolves and verifies the NAS identity over HTTPS before sending login details; it does not bypass certificate validation. If DSM asks for a verification code, a code field appears. "Stay signed in" stores the password in the Keychain so expired sessions renew automatically. Backup needs this to keep running.
- **Photos**: full timeline with On This Day memories. Pinch to change grid density, drag the right edge to scrub by month, and long-press to select. Selected items can be shared, favorited, added to an album, saved to Photos or deleted. The filter menu switches between Personal and Shared Space and between day and month grouping. The cloud icon opens Backup.
- **Viewer**: swipe between items and swipe down to close. A high-quality preview appears instantly. The original downloads when you zoom, share or save, or always if you turn that on in Settings. Videos stream from the NAS. Live Photos play from the header button. Info shows EXIF, location map and people.
- **Search**: filename, tag, place and thing search, plus People, Places, Things and a photo map. **Search saved library** works from the on-device index: search filenames, months or dates (`YYYY-MM-DD`) and filter by year, photos, videos, Live Photos or RAW. Only downloaded previews are available offline.
- **Library**: Favorites, Videos, Folders, Upload, and albums (create, add, remove, rename, delete, share link).
- **People**: open Search → People, choose a person, then use the **…** menu → **Name person** or **Edit name**. Names are saved to Synology Photos and read back before Fotera reports success.
- **Widget**: rotates through today's memories hourly, or shows a pinned photo ("Show in widget" in the viewer).

Deleting requires the Synology Photos recycle bin to be enabled. Library → Recently Deleted browses accessible DSM recycle folders and offers restoration without overwriting existing files. If the NAS has no accessible recycle folder, Fotera explains that it cannot list deleted items.

## New collections and settings

- **Smart albums** save rules on this device for media, date, filename, person and tag filters; these are not Synology conditional albums.
- **Offline albums** download selected originals and Live Photo packages. Open an album to start or resume its download; removing the download does not delete NAS photos.
- **People management** offers visibility, cover selection, merge and face separation. Review selected faces carefully before confirming a change.
- **Photo Info → Edit** edits descriptions and tags, with server readback before reporting success.
- **Shared with me** lists incoming shared albums and opens their Synology shared viewer.
- **Connections** configures a preferred private LAN address and QuickConnect fallback. Each route must identify the same NAS before Fotera uses it. The original address remains the account/backup identity.
- **Widgets** include album, person and backup status. Choose album/person content in its detail screen; iOS controls widget refresh timing.

## More features

- **Accounts**: Settings → Accounts lists every signed-in NAS account. Switch with a tap or add another; backup runs for the account in use.
- **Sign in again**: if a session expires without a saved password, a sheet asks for it over the current screen instead of returning to the login page.
- **Lock with Face ID** (Settings → Viewing) covers the app, including open sheets, whenever it leaves the foreground.
- **Duplicates** (Library → ⋯): exact copies and burst shots from the index, plus look-alikes from Synology Photos' Similar photos feature when it is on. Copies and bursts pre-select all but one photo; similar photos start unselected.
- **Recently added** (Library → ⋯) lists the newest uploads regardless of capture date.
- **Shared with me** opens shared albums inside Fotera (with a link to Synology's web viewer if the NAS doesn't allow it).
- **Video quality** (Settings → Viewing): fast start (the NAS's smaller version), original on Wi‑Fi, or always original.
- **Share sheet**: choose **Upload to Fotera** in Photos, Files or any app. Items upload to the Upload to NAS folder the next time Fotera opens.
- **Shortcuts / Siri**: Back Up Now, Upload Latest Photo and Show Memories.
- **iPad**: sidebar navigation and wider grids.

## Backup

Settings → Backup (or the cloud icon). Choose a space and folder, then turn backup on. Originals, both Live Photo resources and RAW+JPEG pairs are uploaded. Edited versions are optional. Uploads run on a background URLSession and continue while Fotera is suspended. iOS wakes Fotera to queue more when uploads finish and through scheduled background tasks. With "Verify every upload" on, each file is downloaded back and compared byte for byte before it counts as backed up.

Before uploading, Fotera checks all indexed photos in the selected Personal or Shared Space, across folders. Only items with the same file size, or Live Photos with the same base name, are considered, so existing libraries aren't downloaded wholesale; an exact SHA-256 match of the downloaded original (including individual Live Photo components) is required to skip the upload. Names alone never establish a match. Existing matches are recorded as verified backups without moving or copying the NAS file. If discovery or comparison fails, the resource stays queued for retry. Checks cannot see files outside Synology Photos, items not yet indexed, or another space. Comparing originals can require substantial downloads; candidate digests persist between launches to accelerate comparisons. A cached matching digest is rechecked against a fresh NAS download before an upload is skipped.

Backup → **Backup history** records every foreground and background run (exportable as CSV). **Free up space** removes iPhone copies of items whose NAS copy was byte-verified (and whose edits were backed up), after the iOS confirmation; they stay in Recently Deleted for 30 days. **Notifications** report finished background backups, items needing attention, and backups that haven't completed for 3 days.

iOS controls background execution, so open Fotera occasionally to keep backup current. Don't delete photos from the iPhone based on backup status until real-device trials (see IMPLEMENTATION.md) are complete.

## Development

Unit tests: `xcodebuild -project Fotera.xcodeproj -scheme Fotera -destination 'platform=iOS Simulator,name=iPhone 17 Pro' test`.

Launch arguments (Debug only): `--fotera-verify` runs NAS checks and writes `Documents/verification.txt`. `--fotera-screen viewer|info|search|library|backup|settings|select` opens a screen for screenshots.

See `IMPLEMENTATION.md` for architecture, fixed bugs and remaining work.

### HEIC previews

Fotera creates local previews when NAS thumbnails are missing. For imported HEIC photos that still show placeholders, open **Settings → Storage → Generate HEIC previews**, then tap **Generate previews**. Keep that screen open; Stop or leaving the screen cancels further work while preserving completed previews. This can download many originals, so use Wi-Fi for a large library. HEIC files over 50 MB are skipped. Generated previews appear only in Fotera and are subject to its 300 MB preview-cache limit; this does not generate Synology Photos server previews or alter the originals.
