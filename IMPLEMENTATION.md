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

## Feature batch (November 13, evening)

Added: Git history, an XCTest target (15 tests) with a shared scheme, re-sign-in sheet, backup notifications, backup history log, Free up space, duplicate finder (local exact/burst groups plus the NAS's `Browse.SimilarItem` list grouped by capture time), Recently added (`Browse.RecentlyAdded`), in-app shared-album browsing via share token, video quality setting, share extension (`FoteraShare`) with an App Group inbox, Face ID lock in a top-level window, iPad sidebar and wider grids, App Intents (Back Up Now, Upload Latest Photo, Show Memories), multiple accounts (Keychain slots per account), zoom transition from grid to viewer (iOS 18+), haptics, and an accessibility pass.

Also fixed: the project's Debug configuration lacked Xcode's standard settings (`ONLY_ACTIVE_ARCH`, `ENABLE_TESTABILITY`, `-Onone`), so Debug builds were optimized and couldn't be unit-tested.

Review fixes before commit: Free up space now requires edited renderings to be verified for edited photos; offline renewal failures no longer prompt for a password; the Face ID lock covers open sheets; shared-file import can't run twice concurrently.

Verified: unit tests pass on the simulator; NAS probes on the iPhone confirmed `SimilarItem.list` and `SimilarTimeline.get`. Not verified against the NAS: shared-album token browsing (no albums are shared with this account), `Similar.get` grouping, multiple accounts, the share extension on a device (needs an App ID with App Groups; see below), and the new flows by touch.

Device signing: the share extension needs App ID `net.jwalter.PhotoHarbor.Share` with the `group.net.jwalter.Fotera` App Group. Xcode registers it automatically once an Apple account is added in Xcode → Settings → Accounts and the project is built for a device once.

## Backup stall repair (November 13, evening)

The phone's saved queue contained 245 verified resources, 40 queued resources (28 repeatedly reporting ZIPFoundation missingEndOfCentralDirectoryRecord), and one unsupported AVIF requiring attention. Read-only NAS probes reproduced the failure: some items marked `live` return a single HEIC or video instead of an archive.

- Duplicate checking now validates the downloaded payload as an image, video, or ZIP and hashes its actual contents. Only an exact SHA-256 match skips an upload; invalid packages remain errors, not assumed matches.
- Pending retry/backoff keeps the owning backup task alive, preserving an existing iOS continued-processing grant instead of ending it and relying on a foreground-only timer.
- Returning to the foreground cancels and awaits the suspension worker before resuming backup. Starts are reserved before task scheduling to prevent competing starts losing the cancellation handle.
- Cancellation during submission/verification no longer increases failure attempts or verification backoff.

Regression coverage includes raw-image responses labeled live, real archives containing still and motion resources, and rejection of corrupt payloads. Long-duration locked-device progress still requires a phone trial; iOS remains responsible for scheduling background execution. The new FoteraShare extension needs an App Groups provisioning profile before this source can be installed as a complete device build.

Repair validation: 17 simulator unit tests passed. Read-only checks against all 29 NAS candidates implicated by the phone queue passed the new fingerprint decoder, including standalone HEIC, standalone QuickTime, and genuine two-resource archives. The standalone QuickTime response's SHA-256 also exactly matched a queued phone original. No backup records were marked complete manually and no NAS files were deleted or moved. Full phone installation remains blocked by the FoteraShare signing profile; the unsigned device build also passed, which verifies device compilation but does not permit installation.

Device follow-up: after Apple account sign-in, the command-line builder still reported no account. Building the same Fotera project directly in Xcode successfully provisioned FoteraShare. The signed app passed codesign verification, was installed on the phone, and launched normally. All 29 download probes passed on the physical phone. Twenty of the 28 previously ZIP-blocked records became verified; eight retained prior retry delays at the last snapshot. New backup work was also progressing. Long-duration locked-phone behavior is still a trial item, not a completed endurance test.

## Local HEIC preview generation

Fotera's fallback now resolves missing size metadata and supports HEIC/HEIF/HIF originals up to 50 MB. Settings → Storage → Generate HEIC previews scans the selected Photos space and generates previews sequentially, with progress and cancellation. Leaving the screen or backgrounding cancels the pass; completed previews remain cached. Manual generation bypasses NAS placeholder previews and updates the timeline's small/medium caches plus its high-quality preview. No preview is uploaded to Synology and originals remain unchanged.

A real NAS HEIC exposed UIImage JPEG encoding returning nil for the decoded high-bit-depth image. Rendering into standard-range RGB before JPEG encoding fixed persistent caching. NAS validation passed missing-size metadata handling, both grid cache sizes, and account-scoped disk caching. The simulator regression suite and signed device build passed; Settings navigation was checked in the simulator.


### Two-factor login continuation investigation

Reproduced authentication error 402 with a second account in the simulator. Changing the session name to SynologyPhotos did not resolve it; that experiment was reverted. The NAS's own public login bundle handles error 403 by retaining `error.errors.token` and submitting it in `passwd` with the OTP. Fotera previously discarded this response detail and recreated its client for the OTP step. It now preserves that continuation only in memory, scoped to the same client, username and original password, with a five-minute limit. Persisted credentials always retain the original password, never the temporary token. Error payload decoding remains compatible with non-authentication APIs whose `errors` field is an array.

All 20 simulator unit tests passed, including challenge scope/expiry and error decoding. Live second-account verification remains pending; this is not yet a confirmed fix for that account's 402. DEBUG builds write only authentication result codes and challenge-present/used booleans to `Documents/login-verification.txt`, never credentials, tokens or raw responses.

Phone follow-up: the server returned 403 with a challenge, and Fotera used it on the OTP request, but that request still returned 402. Opening the NAS Photos page then revealed its actual login redirect includes `app_name=SYNO.Foto.AppInstance` (alongside launchApp and photos_action). The NAS public login helper merges these URL parameters into its authentication request. Fotera now includes this Photos application identifier; a session name alone was not equivalent. This request change is based on observed vendor behavior; successful affected-account authentication still requires live confirmation.

Fresh web sign-in succeeded for the affected account, while phone diagnostics confirmed 403/challenge followed by 402 even with app_name. The next build aligns the native request with the observed Photos web flow: negotiated Auth v7 (v6 only when v7 is unavailable), webui session, Photos launchApp/app_name/photos_action, local login type, and private ephemeral cookies retained across steps. Device registration parameters remain consistent from the password step, and both v6 did and v7 device_id response fields are accepted. The app still requests SID format and uses explicit SIDs for Photos API calls. Live affected-account success is not yet verified.

### Memory previews and cached-library refresh

Memory covers and story slides now pass their RemotePhoto into ThumbnailView's bounded original-preview fallback, matching timeline behavior for missing NAS/HEIC previews. Widget memory generation uses the same fallback. This does not manufacture previews for unsupported video/RAW originals or bypass download size limits.

Pull-to-refresh no longer forces a full metadata scan. Within the existing six-hour reconciliation interval, it checks total count and the newest 100 items, merging only if those account for the entire count increase and overlap the cached prefix in order. A second count check rejects a changing snapshot. Unchanged libraries avoid rebuilding their derived timeline; imports outside the newest page, deletions, replacements and ambiguous ordering fall back to full reconciliation. Older same-count edits remain discoverable by the periodic full scan. No undocumented Diff endpoint is assumed. Unit tests cover unchanged/new/updated items and fallback conditions.

### Large-library map responsiveness

Photo map clustering now runs in a detached, cancellable task with periodic cancellation checks. Only photos inside the viewport are grouped into an 8x8 grid, capping SwiftUI/MapKit rendering at 64 annotations. Longitude wrapping handles the date line, invalid coordinates are ignored, and stale camera results cannot replace newer work. A fixed initial world map rectangle avoids camera-fitting feedback from changing annotations. Synthetic 100,000-photo tests retained all valid items at world extent; all 27 tests passed. Simulator UI checks verified opening, panning and navigating back with that synthetic library. Actual NAS thumbnails and physical-device performance still depend on the user's library/network.

### Manual memories and timeline navigation

Memory stories no longer have a timer, automatic advancement, pause gesture, or fade between items. Their progress segments indicate the selected item instead of elapsed time. A Show in timeline button returns the current photo ID to PhotosTab; after the memory dismisses, PhotoGrid reveals the containing section, centers the photo and outlines it. Jump requests have unique IDs so repeated navigation to the same photo works. Original-preview loading remains enabled with loading fades disabled for memory slides.

Verified in the simulator using an isolated 100-photo timeline: the memory remained on item 1 after seven seconds, manual Next selected item 2, and Show in timeline centered/highlighted photo 91 (the current memory item) far down the timeline. Synthetic previews intentionally have no images or NAS access.

Timeline jump follow-up: the one-photo-per-section UI test missed nested lazy month grids. Navigation now uses the target row’s proportional section anchor to materialize its tile; the tile task then centers the exact photo and only then marks the request handled. Verified in the simulator with three 1,000-photo sections, targeting photo 1790 deep in the second section. The highlighted tile appeared at viewport center.

### Separate LAN and remote HTTPS routes

Connections settings now persist a full remote HTTPS origin alongside LAN and optional QuickConnect. Legacy profiles decode without losing their settings. Selection prefers verified LAN, then the configured remote HTTPS origin, then remaining current/canonical routes and QuickConnect. Candidates are deduplicated and still require the saved NAS identity before switching. Existing network-change monitoring selects routes even when backup is disabled. Controlled tests cover LAN preference, LAN failure to remote, and rejecting a different NAS. The remote pics.jwalter.net identity probe passed from this Mac; the previous LAN address 192.168.68.66:10004 returned No route to host, so physical LAN/cellular transition remains unverified.

### Live route display and switching

AppModel publishes the active route separately from the saved account address. Settings shows LAN/Remote plus the active URL beneath the username; Connections uses that same live state. DSMClient publishes route changes, filtered to the current client to prevent account cross-talk. A foreground-only 15-second monitor and immediate foreground/network checks refresh route selection without relaunching; it stops on background, sign-out and account changes. Explicit checks arriving during a probe queue a follow-up instead of being lost. Connection failures trigger route reevaluation; only get/list/count/query requests retry once after the origin changes, never writes or login requests. Cancellation and certificate failures do not trigger this retry. All 31 tests passed before the final save-connections follow-up adjustment; signed build validates the final source. Physical LAN/cellular switching remains dependent on reachable configured endpoints and was not exercised from this Mac.

### Faster network handoff

Route checks are shared and awaited before pull-to-refresh starts. Cellular paths exclude LAN candidates; identity probes have a three-second total timeout. Route changes cancel outstanding read requests and retry them once on the verified new origin, while writes are not replayed. Background upload migration no longer delays route selection. Simulator tests cover cellular candidate filtering, origin comparison, and existing route identity protection. Physical Wi-Fi/cellular handoff still requires device validation.

## Review of the route, preview and login changes (November 14)

Fixed after review:
- Route checks stalled browsing. A 15-second foreground monitor forced full route checks, and every request waited for any check in progress (up to ~3 s per check when an unreachable LAN address timed out). Now only the first request waits; later checks run alongside requests, reads in flight to the old origin are still cancelled and retried on a switch, and the monitor checks on foreground return and then at most once a minute. Pull-to-refresh no longer waits for a route check.
- Generating HEIC previews reloaded every thumbnail for each generated photo (a global revision counter observed by every tile). Regeneration now posts the photo's ID and only that photo's tiles reload.

Login investigation:
- Synology's DSM Login Web API Guide documents Auth versions 3–7 (6 recommended), `session` as an optional "login session name for DSM Applications", 402 as "Denied permission", device tokens (`enable_device_token`/`device_name`/`device_id`), and logout with no extra parameters. It does not document returning a 403 token in `passwd`, nor `app_name`/`launchApp`/`photos_action`/`logintype`/`client`.
- The NAS's own web login (`synocredential.js`) uses Auth v6 with `session=webui`, moving to v7 only together with an encrypted Noise handshake, and maps 402 to "no privilege". The NAS has Synology's Secure SignIn service installed, which adds approve-on-phone and passwordless sign-in; the 403 continuation token is consistent with that.
- A probe with a nonexistent account reached the password check (error 400) on both v6 and v7 with Fotera's parameters, so the request shape is accepted.
- The phone's DEBUG login log (result codes only) shows the final code working: a 403 with challenge followed by a successful sign-in that used it, and six further successful sign-ins.
- Open: whether `session=webui` ties the app's session to DSM's web-UI logout timer is untested; it would show up as more frequent renewals.

## NAS thumbnail uploads (November 15)

New upload bodies include `thumb_sm`, `thumb_m`, and `thumb_xl` JPEG parts alongside the unchanged original using `SYNO.Foto[Team].Upload.Item.upload_to_folder` v8. The field names, aspect-fit sizes (240/320/1280), quality 0.9, and version were observed in this NAS's `/webman/3rdparty/SynologyPhotos/react_bundle.js`. API discovery must advertise v8; older servers retain the original upload path.

Generation runs off the main thread from the staged file with ImageIO orientation handling and bounded sRGB output. Supported videos use an oriented AVFoundation frame; Live Photo motion resources do not replace the still's preview. Unsupported media still backs up as an original. The JPEGs travel in the existing durable background multipart body, so they need no separate upload task, completion count, or retry ledger. This does not transcode videos, repair previously uploaded files, or install a NAS background service.

Validation: 66 simulator tests passed. A synthetic HEIC was uploaded through the real queue from the iPhone to personal space in `/Fotera Validation`, its original was downloaded and byte-verified, and all three thumbnail sizes returned by the NAS matched the generated JPEGs byte-for-byte. The check bypassed Fotera's image caches. Shared-space upload uses the same observed client contract, but was not separately exercised. DEBUG launch: `--fotera-verify --upload-preview-tests` (retains the synthetic fixture for inspection).

## Repairing historical backup identities (November 15)

Confirmed on the phone: IMG_0117.jpg had a completed backup link to retired NAS item 25161. Its exact original is currently NAS item 50138, named IMG_0117+1.jpg, with a different timestamp. Name/date matching correctly declined to guess, but the historical link was never reconciled.

After backup catches up, completed phone assets that remain unmatched are now checked against the current NAS catalog using the existing original-resource SHA-256 verification. Exact matches save a new durable upload link and refresh the timeline; this does not enqueue originals or restore deliberately deleted NAS files. Successful checks are memoized for the current catalog and local revision, respect cancellation/deadlines, and scope identities by account and space. Multiple proven NAS copies no longer produce an extra device-only row; one deterministic NAS row gets the local viewer, while all NAS copies remain visible. Unresolved historical backups are reported in backup status instead of an unqualified “Up to date.”

Validation: 68 tests passed, including renamed/date-changed identity recovery, deleted originals remaining device-only, conflicting identities, and multiple proven NAS copies. A live repair saved 23 links and reduced device-only timeline entries from 32 to 12; IMG_0117.jpg now matches item 50138. Twelve entries remain unresolved (8 without a retained upload link, 1 pointing to an absent NAS ID, 3 with linked but incompatible media identities); these were not guessed or re-uploaded. DEBUG diagnostics are opt-in and operate without uploading or deleting originals.

## Remaining device-only matches (November 15)

A fresh NAS/PhotoKit audit identified six PNG assets with edited JPEG renditions already on the NAS and three standalone MOV/MP4 originals incorrectly labeled `type=live` by Synology. Reconciliation now checks the exact bytes of original, edited, and alternate still resources (or original/edited video). Finding an edited rendition saves display identity only: it never marks an unverified original as verified or makes that original eligible for removal. Imported motion files with a video extension are classified as videos even if their NAS type is live; their original download uses item_id, preserving the request previously used for these files by livePackage. Real HEIC/JPEG Live Photos retain paired-photo behavior.

The user explicitly chose matching fixes only, not restoration of missing originals. Live validation saved six edited-resource links, corrected all three video matches, and reduced device-only entries from twelve to three with the NAS item count unchanged at 3150. The three remaining files have no verified NAS equivalent: IMG_0040.AVIF, IMG_20260809_201018.jpg, and the JPG beginning 11357f2a1a4358ed. No original was uploaded, deleted, or restored by the repair. Seventy regression tests passed.

## Memory widget day rollover (November 16)

The old widget repeatedly generated hourly entries from the last app-written `memories-widget.json` array. Its timeline could refresh independently, but the selection itself never changed days until the app rebuilt it.

The app now prepares seven dated daily selections and a small evergreen fallback in the App Group's atomic `memories-schedule.json`. The extension chooses by its local Gregorian date and supplies 48 future hourly boundaries, including midnight, rather than repeating today's array across tomorrow. Calendar hour intervals handle daylight-saving changes. Beyond the prepared week, it rotates fallback photos with absolute capture-date titles, never stale relative anniversary labels. Pinned photos remain pinned. Disabling memories and signing out clear the new schedule; cache stamps include account, timezone, date, and library count. The extension still receives no NAS credentials and makes no network requests.

Validation: 73 tests passed, including decoding a saved schedule and selecting tomorrow without any app refresh, expired-cache fallback, and both DST transitions. Release app and widget extension build successfully. WidgetKit ultimately controls presentation timing; this schedules future entries rather than promising an exact-time background launch.
