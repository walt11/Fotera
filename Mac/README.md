# Fotera for Mac

A native SwiftUI/AppKit macOS app, built alongside the existing iPhone app. This is an actively developed Mac version. It is not yet at full iPhone feature parity or ready for public distribution.

## Open and build

Open `Mac/FoteraMac.xcodeproj`, choose the **FoteraMac** scheme and **My Mac**, then Run. Requires macOS 14 or newer and an Xcode version that supports the installed SDK. The project was built with Xcode 27.2.

From the repository root:

```sh
xcodebuild -project Mac/FoteraMac.xcodeproj -scheme FoteraMac \
  -destination 'platform=macOS' -derivedDataPath /tmp/FoteraMac \
  -allowProvisioningUpdates build
open /tmp/FoteraMac/Build/Products/Debug/Fotera.app
```

For project changes, edit `Mac/project.yml` and run `xcodegen generate --spec Mac/project.yml`. The generated project is checked in so XcodeGen is not required to open it. ZIPFoundation resolves through Swift Package Manager.

The Mac app uses `net.jwalter.Fotera.Mac`. Its Keychain entries, preferences, transfer queue and sandbox container are separate from the iPhone app. The iPhone app's bundle identifier, signing identity and Keychain identifiers have not changed.

## First use

1. Sign in with your NAS address or QuickConnect ID, username, password and verification code if required. HTTPS is preferred; the shared address validator also supports local HTTP addresses. Certificate validation remains enabled.
2. Choose Personal or Shared Space in the sidebar. Double-click a photo to open it. Use Command-click for multiple selection and the arrow keys in the viewer to move between photos. Hold the mouse button on a Live Photo to play it.
3. Settings → Connection lets you configure LAN, remote HTTPS and QuickConnect routes. These use the shared NAS identity checks before switching.
4. Settings → Apple Photos optionally includes your local Mac library. Access is requested only when you enable it. Matched photos open locally; cloud-only photos download or stream when viewed. Matching uses the existing conservative display-matching rules; it is not a byte-for-byte backup verification.
5. Create albums from selected NAS photos. Right-click an album for renaming, deletion and sharing. Sharing supports public links and NAS accounts using existing tested client methods. Public link changes require explicit confirmation. Deleting an album does not delete its photos.
6. Right-click a person for naming, merging, cover selection and correcting face groups. Names are read back from the server before the save succeeds. Entered names are retained locally for recovery; they are never silently reapplied over changes made on the NAS.
7. The sidebar also includes Maps, Folders, Smart Albums, Shared with Me, Recently Deleted and Offline. Smart-album rules stay on this Mac. Right-click an album to save its originals offline.
8. Settings includes login-item and completion-notification controls. Closing the window leaves Fotera in the menu bar; Quit stops it.

## Imports and folder backup

Choose **Backups**, enter the destination path within the selected Photos space and choose whether to create year/month folders. **Choose Photos** stages selected files; **Back Up a Folder** grants access only to the selected folder and enables periodic scans. Choosing a watched folder records its destination, Photos space and year/month preference; choose the folder again to change those saved settings.

- Files remain on your Mac; the app never deletes local originals during backup.
- A persistent account-scoped queue keeps staged files until the NAS original has been downloaded and SHA-256 verified. “Verified” reflects the completed transfer, not a permanent guarantee against later NAS deletion.
- Existing destination files and same-size candidates from the loaded NAS catalog are compared by content, not filename alone. Same-name/different-content files receive a unique filename. Duplicate searches outside the destination depend on the loaded catalog.
- Preview JPEGs accompany uploads when the NAS supports the already-observed version 8 upload contract. This does not repair older uploads or add NAS support for every codec.
- Folder scans run every minute while Fotera is running and skip unchanged files after the initial scan. Very recently modified files are deferred. Temporary connection failures receive two bounded retries; network changes trigger route selection and retry eligible failed transfers. Other failures remain visible for manual retry.
- Imports and watching stop if Fotera quits or the Mac sleeps. Opening at login is optional. No sleep prevention is installed.
- Automatic Apple Photos backup is opt-in. Choose its destination, year/month folders, all versus new photos, videos and edited versions before enabling. Staging is bounded to 30 resources or approximately 2 GB per pass. Live Photo resources count as one photo, and progress includes originals not yet staged.
- Transfer history uses account-scoped SQLite storage and imports the earlier JSON queue. Completed history retains local/cloud matching evidence. Backup does not delete local originals.

## Verification

Fifteen Mac logic tests passed on Apple Silicon: content hashing, SQLite persistence, preview generation, NAS date grouping, Memories dates, conservative local/cloud matching, incremental indexing, large-library map clustering, name recovery, Live Photo progress across spaces, network retry classification and smart-album filtering. The 76 iOS tests passed, including a hosted scrolling-layout check showing that selecting/canceling selection does not change the timeline viewport, scroll offset or bottom inset.

To run logic tests without launching the app container:

```sh
xcodebuild -project Mac/FoteraMac.xcodeproj -scheme FoteraMacLogic \
  -destination 'platform=macOS' -derivedDataPath /tmp/FoteraMacLogic \
  CODE_SIGN_IDENTITY=- build-for-testing
xcrun xctest /tmp/FoteraMacLogic/Build/Products/Debug/FoteraMacLogicTests.xctest
```

A separate `FoteraMacUITests` target launches only the synthetic demo library and checks timeline, viewer and backup navigation. After macOS data-access approval, the synthetic Library → viewer → Backups UI test passed. A sidebar publishing-during-render warning found in the first run was corrected; the repeat passed without that warning. To repeat:

```sh
xcodebuild -project Mac/FoteraMac.xcodeproj -scheme FoteraMac \
  -destination 'platform=macOS' CODE_SIGN_IDENTITY=- \
  -only-testing:FoteraMacUITests test
```

Run the synthetic library without accessing your NAS or Photos library:

```sh
open /tmp/FoteraMac/Build/Products/Debug/Fotera.app --args --demo
```

The demo photos are generated fixtures, not the user's library. The Mac app launched successfully and loaded these fixtures. Its own view capture is useful for structural checks, but macOS window capture was unavailable, so a pixel-accurate visual review is still pending.

## Verification limits and remaining parity

The current development-signed app and widget compile successfully. macOS data-access approval resolved the app launch block. The signed app passed the synthetic Library, photo viewer and Backups navigation test; exported test screenshots were inspected. Empty-album creation, listing and deletion also passed against the NAS. Other authenticated workflows still need end-to-end checks; synthetic UI and logic tests do not establish those results.

A read/write/restore audit using the iPhone found 168 Personal Space people and zero saved names. A temporary name persisted across separate server reads and was restored without changing membership. The reported later disappearance was not reproduced. The verified-save and recovery changes are installed on the iPhone.

Implemented additions include incremental refresh (with periodic full reconciliation), bounded map clustering, received albums, folder browsing, recycle restore, offline originals/albums, metadata and tags, smart albums, automatic Apple Photos backup, menu-bar operation, login-item settings and Mac widgets. Widgets use a separate Mac App Group and precompute daily Memories; real widget display and rollover still require runtime verification.

Outstanding work:

- Authenticated Mac validation against the DS224+: session restoration, route switching, originals/video/Live Photos, backup, sharing and People changes.
- NAS-only versus NAS-and-Apple-Photos deletion, with strict original verification before local deletion; cleanup/duplicate review.
- Incoming share extension, account switching, Dock icon choices and remaining bulk operations. Outgoing native sharing is now available in the viewer and multi-selection bar; its picker was verified with synthetic images.
- Live desktop-widget rendering and daily rollover verification. Saved album/person sources now refresh with the library, stay scoped to their account and Photos space, and can be cleared. Settings can disable photo widgets and remove previews.
- Large-library performance profiling, accessibility/keyboard audit, UI automation and Intel runtime testing.
- Distribution signing, notarization and Mac App Store preparation.

Development signing is for testing; this is not a notarized distribution package. The current Release configuration compiled for both arm64 and x86_64; Intel runtime verification remains outstanding.

© 2026 John Walter. All rights reserved. Fotera is independent and is not affiliated with, endorsed by, or sponsored by Synology Inc. Support: Fotera@jwalter.net.
