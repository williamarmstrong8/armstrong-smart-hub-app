# Brick Minimal Launcher

Adds a Brick subpage and a large Home Screen widget in the existing WorkoutWidgets extension. No new target, entitlement, dependency or blocking behavior. Start at Brick → Minimal Launcher.

## Implementation

- Up to six named entries; add, edit, remove, move up/down, dark/light background and larger text.
- Empty by default. No apps are selected for the user.
- Preview buttons test the actual destination. Shortcut mode requires the user to create an Open App shortcut themselves. No installed-app enumeration or automatic shortcut creation is claimed.
- Entries and appearance are JSON in the existing app-group defaults. Changes request a widget timeline reload; iOS controls when it refreshes.
- Widget links route through `armstronghub://launch?id=UUID`. The app resolves IDs against saved entries rather than trusting a destination in an incoming URL. Removed IDs send the user to configuration with an error. File/javascript/data/self-recursive app links are rejected.
- Empty widget and background taps open `armstronghub://brick/launcher`.
- Existing Brick and Screen Time rules are untouched. iOS may still show a transition through Hub/Shortcuts and apply widget glass/tint. Wallpaper, widget placement, icon removal and Dock changes are manual.

## Validation status

Developed in Linux without Xcode, Apple SDKs, Swift compiler or an iPhone simulator. No native build or UI test has run. The illustration, if supplied, is a labeled layout study, not a native screenshot and not proof of runtime layout. Native rendering and app-opening behavior remain unverified.

## Xcode / real-iPhone checklist before merge

1. Build the app and WorkoutWidgets scheme from this branch. Existing project deployment target is iOS 27.0; not changed here. Check signing and the already-configured app group on both targets.
2. Open Brick → Minimal Launcher. Check empty state, back navigation and setup text. Add the Messages quick link, then test it from the preview. The Maps shortcut preset requires creating an Open Maps shortcut first.
3. In Shortcuts make `Open Camera` with Open App → Camera. Add a Shortcut entry with that exact name. Test a name with spaces, `&`, a non-ASCII letter and an apostrophe. Confirm one launch per tap. A missing named shortcut may show its own error inside Shortcuts, since opening Shortcuts can itself succeed.
4. Add six entries; verify Add app hides. Edit, reorder and delete; relaunch Hub and confirm persistence. Try invalid/empty links. Verify cancel makes no changes.
5. Add Armstrong Hub's large Minimal Launcher widget to Home Screen. Confirm entries/order/style match settings after WidgetKit refresh. Test every label, background configure tap, empty widget tap and a stale removed entry.
6. Test widget tap with Hub cold, backgrounded and foregrounded. Hub's existing sign-in gate must be satisfied. If signed out, sign in and tap the widget again.
7. Activate an existing Brick mode that blocks a launcher destination; confirm the launcher cannot bypass the shield. No new blocking authorization should appear.
8. Check light/dark system appearance, tinted/clear widget modes, large accessibility text, VoiceOver, long labels, smallest supported iPhone and the largest six-entry layout. Confirm all rows are readable and have usable tap areas.

## Sources used for launch behavior

- https://support.apple.com/guide/shortcuts/run-a-shortcut-from-a-url-apd624386f42/ios
- https://developer.apple.com/documentation/widgetkit/linking-to-specific-app-scenes-from-your-widget-or-live-activity.md
- https://developer.apple.com/library/archive/featuredarticles/iPhoneURLScheme_Reference/SMSLinks/SMSLinks.html

## Checks run during implementation

- `git diff --check`: passed.
- Tree-sitter Swift grammar parsed all six changed/new Swift files with no error or missing nodes. This is a syntax-only check, not Swift type checking, an Apple SDK build or an execution test.
- Inspected a labeled layout illustration for text fit and separation of page/widget. Actual native pixels remain unverified.
