# Fotera implementation and verification status

Updated November 13, 2026.

## Architecture

- `FoteraApp.swift`: app entry, `AppModel` (session, space, sign-in/out, foreground/background hooks), sign-in screen, Photos tab.
- `DSMClient.swift`: DSM API client. Renews expired sessions automatically when "Stay signed in" is on (password and DSM device token in the Keychain, after-first-unlock, this device only). Batch favorite/delete/album operations with read-back.
- `LibraryStore.swift`: full on-device metadata index (500 items per request), day/month sections, On This Day memories, widget memories.
- `Thumbnails.swift`: image pipeline with memory + disk cache, request de-duplication, cancellation and a LIFO limit of 6 concurrent requests. Decoding is downsampled off the main thread.
- `PhotoGrid.swift`: shared grid (pinch for 2–7 columns, long-press multi-select, per-section select, timeline scrubber) and the selection action bar.
- `Viewer.swift`: UIPageViewController viewer, swipe down to dismiss, xl preview first and original on zoom, streamed video, Live Photo playback, details panel (EXIF, map, people).
- `Actions.swift`: share, save to Photos (Live Photos stay paired), favorite, add to album, delete.
- `Collections.swift`: Library tab, albums, sharing links, folders, Search/Explore (People, Places, Things, Map).
- `Transfers.swift` / `BackgroundTransfers.swift`: durable upload ledger on a background URLSession.
- `Backup.swift` / `BackupScheduler.swift`: PhotoKit backup, BGAppRefresh + BGProcessing scheduling.

## Bugs fixed from the previous build

- Capture times were shown and grouped in the device time zone. Synology stores wall-clock time encoded as UTC, so times were 5–6 hours off and evening photos landed on the wrong day.
- Writing a partial snapshot deleted every cached preview not in the first page.
- Preview cache trimming enumerated the whole cache on every thumbnail write.
- The timeline recomputed every section for every item on each render (quadratic). Thumbnails were fetched one at a time before a page appeared and decoded on the main thread in `body`.
- Opening Uploads created a second queue for the same ledger, which marked active uploads "Needs review".
- Backup stalled permanently once any item needed review or stayed unverified, and never restarted after the network returned.
- Two different photos with the same filename (for example IMG_0001.HEIC from different years) failed verification forever because the NAS keeps the existing file. They are now re-uploaded under a unique name.
- Re-uploading on every asset modification (favoriting changes `modificationDate`). Originals are now keyed by identity; edited renderings by edit date.
- Linear duplicate checks across the whole ledger, the full ledger rewritten on every state change, and a baseline of every asset ID stored in UserDefaults.
- Receipts and orphaned multipart bodies were never deleted.
- An expired session signed the user out, including during background backup.

## Background backup design

1. Assets are scanned newest first; assets already handled are skipped without loading resources.
2. Resources are exported in bounded batches (24 files / 600 MB in the foreground, 40 / 1.5 GB before suspension), with a free-space check.
3. Uploads are submitted concurrently to the background session, so iOS keeps uploading while Fotera is suspended or terminated.
4. When iOS relaunches Fotera for finished uploads, and on app-refresh tasks, Fotera reconciles receipts and submits the next batch within about 20 seconds.
5. Verification (download and SHA-256 compare) runs in the foreground and in BGProcessing tasks. Turning off "Verify every upload" falls back to a file-size check.
6. If an upload's outcome is unknown, the destination folder is checked on the NAS before uploading again. Because uploads use duplicate-ignore, a resubmission doesn't create duplicates.
7. Failures back off exponentially. Only unsupported types, missing folders or repeated failures need attention. They can be retried or dismissed from Backup.

## Verified against the NAS (simulator, `--fotera-verify`)

Cache isolation, wall-clock time formatting, ledger dedup and restore, interrupted-upload reconciliation through to byte verification, favorites, album membership, sharing read, search, item details, People/Places/Things, person thumbnails, person filtering, count, full index with GPS (128 of 179), favorites list, streaming (HTTP 206 video/mp4), recycle-bin check. UI screens were checked in the simulator by screenshot.

## Still requires real-device trials

- Multi-day backup of a large library: suspension, termination, iCloud-only assets, low storage, network changes, Low Power Mode. iOS decides when background tasks run.
- Sign-in with OTP and the device token, and automatic session renewal after DSM expiry. These weren't exercised because they need your password.
- Interaction gestures (paging, swipe to dismiss, pinch columns, scrubber), which were checked in code but not driven by touch.
- Widget rotation on the Home Screen. Creating and updating public sharing links, and deletion, weren't exercised against your library.

## Remaining parity gaps

The new feature implementations below still need real-device trials. Smart album rules are local to Fotera, and incoming shared albums open Synology’s shared viewer rather than a native Fotera viewer.

## November 13 review and implementation

The folder has no Git history, so changes cannot be attributed reliably to an individual author. Reviewed the current session, library synchronization, caching, backup and collection/search code.

- Fixed Forget saved password retaining credentials inside the active DSM client. The client now clears secure storage and its in-memory credentials, cancels renewal, and restricts session access to unlocked-device use. Storage failures are shown to the user.
- Fixed stale library tasks clearing a newer task's loading state or applying a cached snapshot after switching away and back. Refreshes and attachments now have distinct generation identifiers.
- Offline direct-address restores preserve the remember-password state, and requests retry API discovery after the connection returns.
- QuickConnect sessions persist their successfully verified HTTPS endpoint in the Keychain. If discovery is unavailable on a subsequent launch, that endpoint allows the existing cached-library flow to proceed. Legacy session records remain readable; they acquire the endpoint on the next successful restore. No HTTP downgrade or certificate bypass was added.
- Added Search → Search saved library: local filename, capture date, and month search, plus year and All/Photos/Videos/Live Photos/RAW filters. It uses only downloaded metadata in the selected space. Uncached media and server edits still require connectivity.

Verification: simulator build passed; `--fotera-verify --review-tests` passed filename/date filtering, year/media filters, unknown dates, capture-day boundary, legacy session decoding, endpoint persistence, and matching an actual NAS item's metadata. The simulator UI showed 899 indexed items and filtered to 29 videos. Password forgetting was reviewed in code, not exercised against the user's saved credentials. A real QuickConnect outage and multi-day backup remain device trials.

## People naming and timeline scrubbing

- Added a person name editor from Search's People carousel and full People list. The name is written with `Browse.Person.set` v1 and a JSON-encoded name string, then confirmed by a paginated people-list readback. The prior `set_name` method was incorrect for people. Readback failures retain the user's entry and show an error; saves refresh People lists. The same space-specific API wrapper is used for Personal and Shared Space, subject to NAS permissions.
- Live Personal Space validation re-saved the existing empty name successfully and confirmed unchanged person ID and photo membership (`--people-tests`). No invented identity was assigned. The editor and cancel flow were checked in the simulator. Shared Space naming has not been separately exercised.
- Timeline month/year scrub label now has an intrinsic single-line width and appears 54 points left of the right-edge handle, outside the touch target. Its vertical position stays inside the timeline. Simulator drag navigation was checked; the brief transient label's placement was reviewed in code.


## Fotera project rename and expanded collections

The Xcode project, main target and scheme are now Fotera, as explicitly authorized. Existing bundle identifiers, Keychain identity and App Group remain unchanged. `PhotoHarbor.xcodeproj` is a compatibility symlink; open `Fotera.xcodeproj` for normal work.

Implemented offline original albums, local smart rules, descriptions/tags, face previews and correction controls, people merge/visibility/covers, incoming shared albums, constrained recycle restoration, identity-checked connection selection, persisted duplicate candidate digests, transfer speed, and album/person/backup widgets.

Validation distinguishes tested contracts from unexercised operations: synthetic-photo metadata and offline round-trips use a dedicated Fotera Validation folder; visible-person and cover checks preserve their existing values. Merging or separating real people, restoration from an actual recycle folder, populated incoming shares, phone network transitions and long-running backup remain trial items. The NAS currently returns no accessible Photos recycle folder, so end-to-end restoration has not been claimed. No NAS recycle settings were changed.

## November 13 review of the expanded build

Fixed:

- Duplicate detection treated every Live Photo on the NAS as a candidate for every file, so the first backup downloaded every Live Photo package before uploading anything. Candidates are now limited to the same file size or a Live Photo with the same base name. The digest index is written in batches off the main thread instead of after every download.
- Backup progress ran a full PhotoKit fetch, re-read the baseline file and rebuilt the staged-asset set on every ledger change (several times a second during backup). Counts are now coalesced to once per second, the library count is cached for a minute, and staged asset IDs are maintained incrementally.
- Connection route probes blocked the next API request every 30 seconds (2+ second stalls away from home). Route checks now run in the background after the first request, every 2 minutes or on network changes.
- Switching routes cancelled in-flight uploads. Uploads are now cancelled only when Fotera leaves a LAN route.
- Automatic re-login sent the password over the HTTP LAN route. It now uses the HTTPS endpoint the account was opened with. An explicitly entered HTTP address still uses HTTP.
- Background wakes for QuickConnect accounts re-resolved QuickConnect (several network round trips) before doing any work. They now use the saved verified endpoint.
- Thumbnails cleared whenever the app went inactive, so the app-switcher snapshot showed blank tiles.
- The missing-preview fallback could download originals up to 40 MB while scrolling. It is now limited to 15 MB and skips RAW files.
- UI: Library shows one tile grid (Favorites, Videos, Shared with me, Smart albums, Offline, Folders, Recently deleted, Upload) above Albums. Search drops the stacked extra links: "On this iPhone" sits with Map, and Hidden people is in the People list toolbar.

Verified in the simulator against the NAS: the base, duplicate, review and connection suites pass, including QuickConnect resolution. The local-HTTP-stub step now skips when no stub is running.

Open: the LAN HTTP auto-route still sends the session ID unencrypted. The NAS identity check (`ezid`) is public, so a device on an untrusted network that answers at the configured LAN IP could capture the session.

## Immich/Ente-style layout pass (November 13)

- **Photos**: no title. A floating "Photos ▾" menu switches space, grouping and selection. The grid runs edge to edge under a transparent bar. Day mode shows sticky month headers with small day labels. The right-edge scrubber shows a thumb while scrolling (iOS 18+) and year markers while dragging. Tiles show video duration, a Live Photo mark and a favorite heart. Favorites come from the favorites list during each sync, because the item list doesn't report them. Memories are larger cards that open a full-screen auto-advancing story (tap the sides to step, hold to pause).
- **Viewer**: swipe up for details and down to close. A thumbnail filmstrip sits above the controls. The controls are Share, Favorite, Delete and "…" (Details, album, save, slideshow, widget) on a plain dark overlay. Live Photos get a LIVE pill.
- **Library**: a horizontal row of round icon chips. Albums are the main content, as two-column cards with the title over the photo.
- **Search**: two rows of people, chevron section headers, place cards with a pin and country, suggestions while typing (people, places, things) and recent searches.
- **Global**: shared `Theme` radius and spacing. Settings → Appearance defaults to Dark. Grids, albums and Search load with skeleton placeholders. A slim progress line under the Photos bar shows a running backup and opens it on tap.
- Fixed: placeholder tiles shared IDs with albums in one lazy grid, so album cards kept rendering as blank placeholders.
- Fixed: the `--connection-tests` harness overwrote the saved session with its QuickConnect test account. It now restores the original. A DEBUG `--repair-session <address> <user>` rebinds the simulator's current session.

Swipe gestures, the memory story, the backup progress line and search suggestions were reviewed in code. They weren't driven by touch in the simulator, because simulator control wasn't granted and no memories fall on today's date.

## Efficiency pass (November 13)

- **Library sync**: an automatic refresh first compares the item count and the newest 100 items with the saved index, and skips the full download when they match. Pull-to-refresh and a 6-hour interval still do a full sync. The index is only re-saved when it changed. (A binary plist format was measured and rejected: larger and slower than JSON for this data.)
- **Timeline**: sections, memories, videos, located photos, years and an ID lookup are built off the main thread, in one pass per change. Day labels rebuild only after midnight. Grids without month groups skip the grouping step, and the Favorites tile uses the ID lookup instead of scanning the library.
- **Backup**: the duplicate check reuses the timeline index (refreshed at most every 10 minutes) instead of re-listing the NAS for each batch. Exports are fingerprinted while they stream from PhotoKit, removing a full re-read of every file. New "Verify videos by downloading" option: when off, videos are checked by size and photos are still fully verified. Ledger writes are batched to at most one per 0.5 s, except writes that must survive a crash (enqueue, submit); pending writes flush when the app goes to the background.
- **Viewer** uses the synced favorites list instead of asking the NAS on every swipe. **Search** caches people, places and things for 5 minutes per space (pull to refresh forces a reload). **Grid** prefetches the next two rows of thumbnails through a separate low-priority limiter.

Verification: simulator and device builds pass; the streamed fingerprint matches a whole-file SHA-256; the cached timeline renders with off-main builds. The simulator's NAS session expired during this pass (DSM 119, no saved password), so the quick sync check, catalog reuse and streamed export weren't exercised against the NAS.
