# Widget — Xcode setup

The Swift files, the widget Info.plist, and a placeholder
`QuicPeekWidget.entitlements` are already on disk. The remaining steps must
happen in Xcode's UI because they touch signing, the embed-extension build
phase, and capabilities — hand-editing `.pbxproj` for those silently breaks
provisioning.

> **Heads up — paid Apple Developer membership required:** App Groups
> capability needs a paid Developer Program team. A free personal team can
> sign each target individually but cannot enable App Groups, so the widget
> will load and show "Open QuicPeek to fetch" forever because
> `UserDefaults(suiteName:)` returns `nil` in both targets.
>
> The main app's `.entitlements` does **not** yet declare the App Group —
> we left it out so the project keeps building on a free account. Add the
> capability via the Xcode UI in step 4 below; Xcode will rewrite the
> entitlements files for both targets atomically and reconcile provisioning.

## 1. Add the Widget Extension target

1. **File → New → Target…**
2. macOS → **Widget Extension** → Next.
3. Product Name: `QuicPeekWidget`.
4. Bundle Identifier: `com.bharath.QuicPeek.Widget`.
5. **Uncheck** "Include Live Activity" and "Include Configuration Intent" — we
   ship our own `SelectProjectIntent`.
6. Embed in Application: `QuicPeek`.
7. Finish. Activate the new scheme if prompted.

Xcode will create a `QuicPeekWidget` group with a few placeholder files
(`QuicPeekWidget.swift`, `QuicPeekWidgetBundle.swift`, an `Assets.xcassets`,
maybe `QuicPeekWidget.intentdefinition`).

**Delete every file Xcode generated inside `QuicPeekWidget/` *except*
`Assets.xcassets`** — we already have hand-written replacements on disk.

## 2. Wire the prepared files into the new target

The seven files we've staged on disk:

```
QuicPeekWidget/
  QuicPeekWidgetBundle.swift     ← @main WidgetBundle
  BrandRingsWidget.swift         ← Widget + timeline provider + entry view
  SelectProjectIntent.swift      ← AppIntent + ProjectAppEntity
  WidgetRingView.swift           ← Standalone ring renderer
  Info.plist                     ← NSExtension config
  QuicPeekWidget.entitlements    ← App Group + sandbox
  SETUP.md                       ← this file
```

For each `.swift` file: right-click the QuicPeekWidget group in Xcode → **Add
Files to "QuicPeek"…** → select the file → in the dialog, set **Targets** to
`QuicPeekWidget` only (NOT the main app). Repeat.

The widget target also needs `SharedStore.swift` from the main app — add it as
a member of *both* targets:

1. Select `QuicPeek/SharedStore.swift` in the navigator.
2. In the File Inspector (right pane), under **Target Membership**, check
   both `QuicPeek` and `QuicPeekWidget`.

## 3. Point the widget target at our Info.plist and entitlements

Select the `QuicPeekWidget` target → **Build Settings**:

- **Info.plist File**: `QuicPeekWidget/Info.plist`
- **Code Signing Entitlements**: `QuicPeekWidget/QuicPeekWidget.entitlements`

(Xcode-generated values can be replaced inline by typing.)

## 4. Enable App Groups on both targets

Select the `QuicPeek` target → **Signing & Capabilities** → **+ Capability** →
**App Groups** → click the `+` and add `group.com.bharath.QuicPeek` (or check
it if it already exists in the team).

Repeat for the `QuicPeekWidget` target. Both targets must have the **same**
group ID checked. Xcode will rewrite both `.entitlements` files and request a
fresh provisioning profile that includes the App Group.

If Xcode reports that the device isn't registered or the team can't enable
App Groups, you're on a free Apple ID — see the heads-up at the top of this
doc.

## 5. Build & run

- Build the main app once (so it can fetch projects + brand reports and write
  to the shared store).
- Open Notification Center / desktop, add the **QuicPeek → Brand Rings**
  widget, edit it to pick a project, and the rings should populate.
- The widget refreshes automatically every time the main app fetches data
  (`PeecMCP` calls `WidgetCenter.reloadAllTimelines()` via `SharedStore`).

## Troubleshooting

- **Widget shows "Open QuicPeek to fetch":** the shared container has no data
  yet. Open the main app and let it fetch a brand report at least once.
- **Widget shows placeholder Acme data forever:** App Groups aren't enabled on
  one of the targets, so `UserDefaults(suiteName:)` returns `nil` in the
  widget. Re-check capabilities on both targets.
- **Project picker is empty in widget configuration:** the main app hasn't
  fetched projects since the App Group was set up. Quit and relaunch
  QuicPeek; it will repopulate `SharedStore.writeProjects` on `refreshProjects`.
