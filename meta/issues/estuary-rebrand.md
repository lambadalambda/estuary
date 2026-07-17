# Estuary rebrand — first slice (name + palette)

## Summary

The app is now called **Estuary** ("where conversations converge" — a delta
and an estuary are both river mouths, nodding to Delta Chat compatibility).
User approved a brand sheet (2026-07-17): logo, palette, Sora type. This
issue covers the first slice: user-facing name and color palette. The app
icon lands via [App bundle polish](app-bundle-polish.md) once the asset
exists.

## Palette (from the brand sheet)

| Name          | Hex       | Role                                        |
| ------------- | --------- | ------------------------------------------- |
| Deep Teal     | `#0F3D3E` | primary accent (light mode), outgoing bubbles |
| Sea Glass     | `#7FBDB4` | accent in dark mode (deep teal vanishes there) |
| Midnight Blue | `#0D1B2A` | reserved (dark surfaces, later)             |
| Slate         | `#4B5B66` | reserved (secondary text, later)            |
| Warm Ivory    | `#F6F4EF` | reserved (light surfaces, later)            |
| Coral         | `#FF6F61` | attention: unread badges                    |

## Requirements

- `EstuaryTheme` as the single source of palette + app name constants.
- Rename all user-facing "Delta Native"/"DeltaApp" strings to "Estuary":
  onboarding title, Info.plist CFBundleName/CFBundleDisplayName, bundle
  output `Estuary.app`.
- Replace scattered `Color.accentColor` uses with theme accent (adaptive:
  deep teal in light, sea glass in dark); coral for unread badges (muted
  stays gray).
- Do NOT change: bundle identifier (would reset TCC camera + notification
  grants), data dir `DeltaChatNative` (would orphan existing accounts),
  internal target/module names (pure churn).

## Acceptance Criteria

- Swift tests cover theme constants (valid hex, distinct roles); suite green.
- `make app && make run-app` produces `Estuary.app` titled "Estuary" with
  teal accent and coral unread badges; existing account still loads.

## Notes

- Mockup features NOT in scope: calls/video buttons (no core support),
  presence ("last seen"), list filter tabs, accent-color picker (could be a
  later issue).
- Sora font: branding-only if ever bundled (OFL); chat text stays system.

## Slice 2 (2026-07-17): calm ivory surfaces

User verdict on slice 1: keep teal/coral, and "make it look calmer overall"
with the warm ivory background. Scope:

- Chat conversation surface: warm ivory in light mode, midnight blue in dark.
- Incoming bubbles: flat white cards (mockup look) instead of gray system
  material; dark mode uses the website's card navy. Must contrast with the
  surface in both modes (theme-tested).
- No new loud elements; everything else stays native.

## Slice 3 (2026-07-17): quote contrast fix + tiling chat background

- BUG (user-found): quote blocks inside OUTGOING (deep teal) bubbles render
  dark text on dark background — unreadable in light mode.
- Tiling chat background from user-provided pattern (CC0 sunset photo also
  provided for the mock showcase): light = pattern on warm ivory; dark =
  inverted/tinted onto midnight. Pre-generated tiles, bundled as resources.
