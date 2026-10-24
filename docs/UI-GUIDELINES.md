# BusKit UI Guidelines

Conventions for SwiftUI views in `BusKit/Views/`. Follow Apple's macOS Human Interface Guidelines; this file records the project-specific choices. The canonical sheet reference is `BusKit/Views/CreateSubscriptionSheet.swift`.

## General principles

- Native macOS controls only (no Electron-style custom chrome). Prefer system styles, `Grid`, `Form`-like layouts, `NavigationSplitView`-style sidebar/detail.
- Support light and dark mode: use semantic colors (`.primary`, `.secondary`, `Color(nsColor:)`), never hard-coded hex values for text/background.
- Mark views `@available(macOS 15.0, *)` as existing views do.
- Every interactive control needs an accessibility label; section titles use `.accessibilityAddTraits(.isHeader)`.
- Icons: SF Symbols via `Image(systemName:)`. Warnings use `exclamationmark.triangle(.fill)`, info uses `info.circle`.

## Typography (as used in the codebase)

| Use | Font |
|-----|------|
| Sheet title | `.headline` |
| Sheet subtitle / breadcrumb, hints, errors under fields | `.caption`, `.secondary` |
| Form labels, body text in forms | `.system(size: 13)` |
| Form section headers | `.system(size: 12, weight: .semibold)`, `.secondary` |
| Inline messages | `.callout` |
| Small units / captions (e.g. duration unit) | `.system(size: 11)`, `.secondary` |

## Spacing

| Property | Value |
|----------|-------|
| Sheet horizontal padding | 20 pt |
| Sheet top / bottom padding (form area) | 14 pt / 20 pt |
| Header and footer vertical padding | 14 pt / 12 pt |
| Grid vertical / horizontal spacing | 6 pt / 8 pt |
| Padding around section dividers | 12 pt |

## Sheets and dialogs (center-equalized form)

Layout is a 2-column `Grid`: right-aligned labels (left column), left-aligned controls (right column).

Sheet shell, top to bottom:

1. **Header** – `.headline` title + `.caption` secondary subtitle (e.g. `Service Bus · <namespace>`).
2. `Divider()`
3. **`ScrollView`** containing `Grid(alignment: .topLeading, horizontalSpacing: 8, verticalSpacing: 6)`.
4. **Inline error banner** (only when an error exists): red warning icon, `.callout` red text, `Color.red.opacity(0.08)` background.
5. `Divider()`
6. **Footer** – optional `ProgressView().controlSize(.small)` + status text, `Spacer`, Cancel, primary action.

Rules:

- First cell of the first `GridRow` gets `.gridColumnAlignment(.trailing)`.
- Rows without a label start with an `emptyLabel` (`Color.clear.gridCellUnsizedAxes([.horizontal, .vertical])`).
- Sections: `formSectionDivider` then `formSectionHeader("Title")` (spans both columns via `.gridCellColumns(2)`).
- Never use `.leadingFirstTextBaseline` alignment on the grid.
- Fixed sheet width (e.g. 560 pt) with a `minHeight` suited to content.
- Required fields: red `*` after the label, red 1.5 pt rounded border plus a `.caption` red message on validation error.
- Checkboxes: `.toggleStyle(.checkbox)`. Numeric fields: right-aligned `TextField` + `Stepper` (`.labelsHidden()`), values clamped in `onChange`.
- Durations: Days / Hours / Minutes / Seconds spinners with centered `.system(size: 11)` captions; hide unused units.
- Help: `ⓘ` button (`info.circle`, `.imageScale(.small)`) opening a popover (`.system(size: 12)`, max width 280).

Buttons and keyboard:

- Cancel: `.keyboardShortcut(.escape, modifiers: [])`.
- Primary action: `.buttonStyle(.borderedProminent)` and `.keyboardShortcut(.return, modifiers: [])`; disabled while invalid or busy.
- Dirty forms: Cancel shows `confirmationDialog("Discard changes?")` with `Discard` (destructive) and `Keep Editing` (cancel). Implement `isDirty` as "any field differs from default".
- Disable Cancel while a request is running.

The `buskit-dialog-layout` skill contains copy-paste code for the helpers (grid helpers, duration picker, help popover, error banner, footer). Use it when creating or reworking a sheet.

## Feedback and status

- Long operations: inline `ProgressView` (`.controlSize(.small)`) plus a short status text ("Creating…").
- Transient confirmations and errors: toast (`ToastNotificationView`).
- Auditable operations: record in `ActivityLogStore` (shown in `ActivityLogPanel`).
- Connection / sidecar state: `StatusBarView` and `AppStatusModel`.
- Destructive actions (delete, purge, resubmit): confirm first; use `role: .destructive`.

## Keyboard

- `⌘F` – message search (`MessageSearchViews`).
- `Esc` / `Return` – cancel / primary action in sheets.
- Add menu commands and shortcuts for new global actions in `BusKitApp.swift` instead of ad-hoc key handlers.

## Checklist for a new or changed view

- [ ] Follows spacing and typography tables above
- [ ] Works in light and dark mode
- [ ] Accessibility labels on interactive controls
- [ ] Esc/Return behave as described for sheets
- [ ] Errors shown inline (sheets) or via toast (detail views), and logged when relevant
- [ ] Destructive actions confirmed
