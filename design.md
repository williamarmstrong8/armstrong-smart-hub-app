# Armstrong Hub design system

The hub should feel like one native app: warm neutral surfaces, clear hierarchy, readable numbers, predictable navigation, and quick, restrained feedback. Keep the existing calm visual character; do not introduce a new theme for each feature.

## Source of truth

`Armstrong-Smart-Hub-App/Shared/DesignSystem.swift` owns shared colors, layout constants, motion, page styling, and toolbar hit areas.

- `HubDesign`: adaptive semantic colors.
- `HubLayout`: shared dimensions.
- `HubMotion`: interaction timing and Reduce Motion handling.
- `HubTabPage`: the standard scrolling overview for Home, Finance, and Calendar.
- `hubPageStyle()` / `hubListStyle()`: backgrounds, foregrounds, action tint, and list separators.
- `hubAnimation(value:)`: localized, Reduce Motion-aware feedback.
- `HubToolbarButtonStyle`: a minimum 44 × 44-point tappable label.

`BrickLook` and `Fit` remain compatibility names used throughout existing screens. Their neutral tokens now resolve to the shared palette. Do not add another independent surface palette to these namespaces. `BrickCard`, `BrickHero`, `BrickTopBar`, and `FitSection` are existing shared components despite their historical feature-specific names.

## Color and surfaces

Use semantic roles rather than selecting hex values in a screen:

- `page`: the warm off-white / near-black canvas.
- `surface`: quiet secondary surfaces, including the Fitness and Brick hero panels.
- `raised`: cards and transient messages.
- `track`: pills, progress tracks, and subtle control backgrounds.
- `ink`: primary text.
- `secondary`: supporting text, dates, and readable chart labels. Do not lower its opacity for normal text.
- `separator`: dividers and quiet outlines, not text.
- `action`: tappable text, links, and native control tint.
- `positive`, `warning`, `danger`: semantic state, accompanied by words or an icon.

Normal-size text using the six foreground tokens is tested at **4.5:1 or higher** against all four neutral surfaces in light and dark appearance. This check covers the shared token pairs, not every rendered blend or feature-specific chart color. Do not assume an opacity or gradient preserves contrast.

Feature colors remain meaningful: Google calendar colors, readiness/sleep/activity chart series, heart-rate zones, device power states, and media artwork. They are data, not competing app themes. Keep text readable on colored event cards and pair chart colors with labels.

Native forms, pickers, alerts, keyboards, and system toolbars keep native control geometry and behavior. Apply `hubListStyle()` to a new Form/List rather than painting individual controls. The cinematic media card is intentionally dark, with a **local** color-scheme environment; it must not force the entire app into dark mode. The iPad wall display and widgets retain their context-specific density and native platform presentation.

## Layout

Use these dimensions from `HubLayout`:

- Page gutter: **20 pt**.
- Space between independent sections: **24 pt**.
- Card padding: **20 pt**.
- Top inset below the safe area: **12 pt**.
- Bottom content inset: **32 pt**, in addition to system safe areas.
- Card corner radius: **24 pt**, continuous.
- Compact control/banner radius: **12 pt**.
- Minimum touch target: **44 × 44 pt**.

Use 4, 8, 12, and 16-point gaps within a component. Larger separation should indicate a new section, not compensate for a child’s undocumented padding. Capsules remain capsules; charts and media thumbnails may have smaller corners. The large bottom-rounded device heroes in Brick and Fitness are an intentional shared variant.

Home, Finance, and Calendar use `HubTabPage` with a stable top bar and lazily constructed sections. Fitness and Brick use the same tokens in a hero variant. Navigation destinations belong outside lazy containers. Keep hosted Screen Time reports mounted; rebuilding extension content as it scrolls into view is not an optimization.

A vertically scrolling page owns its horizontal width through `containerRelativeFrame(.horizontal)` and uses `.scrollBounceBehavior(.basedOnSize, axes: .vertical)`. Do not use negative padding to align headers, extend a background hundreds of points offscreen, or hide overflow bugs by clipping the entire page. Horizontal media shelves and workout carousels remain explicit horizontal scroll regions.

Keep native navigation and sheets. Forms remain forms; do not replace their accessibility, keyboard management, or selection behavior with bespoke controls.

## Typography and formatting

Use the system font and semantic text styles so text follows Dynamic Type:

- Page hero: light weight, scaled relative to large title; `BrickHero` uses a 44-point base.
- Device hero title: `.largeTitle.weight(.light)`.
- Section heading: `.title2.weight(.regular)`.
- Card title: `.headline`.
- Body/action text: `.body` or `.callout`.
- Supporting text: `.subheadline` or `.footnote`.
- Short metadata/caps: `.caption.weight(.medium)` with restrained tracking.

Use `monospacedDigit()` for changing amounts, durations, dates, and chart values. Use numeric transitions only for genuinely numeric values, not arbitrary page titles. Keep existing shared currency/date/unit formatters; do not replace locale-aware formats with string concatenation.

Allow important titles and descriptions to wrap. Hero pills switch from horizontal to vertical when they do not fit. Avoid shrinking long prose to half its intended size. Charts may keep fixed plot dimensions and specialized numerical sizes; their labels and surrounding explanation must remain legible.

## Interaction and accessibility

- Use a real `Button`, `Link`, or `NavigationLink` for actions. A text/image `onTapGesture` is not an accessible substitute.
- Give icon-only controls an explicit accessibility label. Put the touch area **inside the button label**, not just in an outer layout frame.
- Keep destructive operations explicit and confirmed; do not obscure them behind motion.
- Disable underlying interaction and accessibility focus while a custom modal is open. Provide a close button and accessibility escape action.
- Preserve native scroll indicators where they help discover additional content.
- Do not use color alone for loading, failure, completion, or active state.
- Use `MessageView` for empty/error pages, `ErrorBanner` when stale content is still useful, and `Toast` for transient feedback.

The media modal has scrollable details and a separate artwork drag region. Scrolling its contents must not accidentally dismiss it or send a title to the TV. Buttons remain the primary, discoverable actions; gestures are supplementary.

## Motion and responsiveness

Motion communicates a change; it should never delay access to content.

- `HubMotion.quick`: **160 ms**, ease-out.
- `HubMotion.standard`: **240 ms**, ease-in-out.
- `hubAnimation(value:)` disables interpolation when Reduce Motion is enabled.
- Animate the smallest changed element: a ring, a progress bar, a button, or the toast overlay.
- Do not attach an implicit animation to the root, tab view, whole scroll stack, or a polling result collection. It can animate unrelated layout and scroll geometry in the same transaction.
- Network refreshes should replace data without springing the entire page. Retain stable model identities and avoid `.id(UUID())` for routine refreshes.
- Presentation identities are appropriate for separate modal lifetimes and are used to reject stale callbacks, not to force page redraws.
- Keep the actual search control mounted while hiding it; a hard-coded placeholder height changes the scroll geometry at larger text sizes.
- Use an inexpensive dim scrim instead of continuously blurring the live tab hierarchy. Avoid giant shadowed backgrounds in scrolling content.
- Media opening never waits for a detail API response. It performs only a short, cancellable poster warm-up, then shows cached details or loading placeholders.
- Decode poster thumbnails off the main actor and bound their resolution. TMDB detail artwork uses `w780`, not unbounded original-size images.
- Disk cache restoration, encoding, and writes run on a serial actor. Versioned snapshots prevent late writes/requests from overwriting newer data or resurrecting invalidated entries.
- Search, opening, and detail fetches must check cancellation and request/presentation identity before updating UI.
- Await pull-to-refresh work instead of launching detached lifetime work and ending the system refresh indicator early.

The optional media send/landing flight is a bounded, one-shot exception to standard timing. It is skipped with Reduce Motion. Playback success is shown only after the server accepts the request. Do not add repeating decoration to scrolling pages.

## Changes in this consolidation

- Shared neutral palette, higher-contrast secondary text, layout/motion tokens, and page/toolbar components.
- Aligned main tab spacing; removed negative header padding and oversized shadowed hero extensions.
- Unified shared cards, detail-page surfaces/action tint, account/login styling, and toast treatment.
- Removed root, shelf, finance, calendar, and other broad layout animations; localized workout rest-panel feedback.
- Replaced media backdrop blur, bounded artwork decoding, isolated modal interaction, and separated drag from content scrolling.
- Guarded media/search asynchronous lifetimes and moved media-cache file work off the main actor.
- Added accessible event links, habit-day buttons, Brick/watch actions, and shared toolbar hit areas.

This is a shared-system consolidation, not a claim that every legacy component has been redesigned. Existing specialized charts, voice scenes, native forms, and extension UI retain domain-specific behavior. New work should follow the rules above; legacy components should migrate when touched.

## Verification

From the repository root:

```sh
python3 scripts/check-design-system.py
./scripts/check-media-cache.sh
git diff --check
```

The Python checks validate token contrast in both appearances, shared overview adoption, and source-level guards against known presentation/scroll hazards. The Swift harness extracts the production media cache/load code, compiles it with the actual media models and test doubles for API/view dependencies, and exercises nine persistence/cancellation/ordering regressions. It uses an isolated temporary cache. It requires Swift 6.2+ and Python 3, but not an iOS SDK.

Swift syntax parsing is useful without Xcode but **does not type-check SwiftUI, validate layout, or establish frame-rate improvements**. Full build, VoiceOver, screenshots, and on-device profiling are still required; full Xcode was unavailable in the implementation environment.

### Device acceptance checklist

1. Build the app in full Xcode and navigate every main tab and its detail pages in light and dark mode. Include empty, loading, stale-data/error, and populated states.
2. Test a small iPhone, a large iPhone, landscape, and the iPad wall display. Repeat at the largest accessibility text sizes. Check wrapped heroes, pills, buttons, labels, and keyboard dismissal.
3. Fling Home, Finance, Calendar, Fitness, and Brick while polling/data updates arrive. Verify no sideways drag, header jump, card reflow animation, or recreated Screen Time report.
4. Open/close/search media repeatedly on a slow connection; change queries rapidly, switch tabs during opening, dismiss during a refresh, and immediately open another title. Old results must never appear in the new presentation.
5. Open media with long titles and short window heights. Confirm all actions scroll into reach, the close button stays reachable, and scrolling does not trigger the artwork gesture.
6. Test request, request cancellation, failed playback, successful playback, and offscreen shelf landing. Failed playback must not celebrate success; an offscreen shelf must not receive a flying card.
7. Enable Reduce Motion and VoiceOver. Confirm focus stays inside the media modal, escape closes it, underlying tabs are unavailable, and decorative flights/glow are skipped.
8. Use Instruments Animation Hitches / Time Profiler on a physical device. Record scroll and open/close traces before and after on the same device/data. Investigate long main-thread frames and image/cache work rather than claiming performance from source changes alone.
