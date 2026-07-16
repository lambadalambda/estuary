# Webxdc support

## Summary

Webxdc mini-apps are sandboxed HTML/JS bundles; a fully native client cannot run them
without a web engine. Decide and implement: embed a webview (WKWebView) solely for
webxdc content, or drop the feature.

## Requirements

- Render webxdc messages as launchable cards (icon, name).
- If accepted: isolated WKWebView window per app with the webxdc JS API bridged
  (sendUpdate/setUpdateListener) to dcvm; no network access from the webview.

## Acceptance Criteria

- A received .xdc app opens and can exchange updates, or an explicit product decision
  documents dropping webxdc.

## Notes

- Same question later applies to HTML e-mail display (isolated webview pane).
- This was consciously deferred at architecture time; the viewmodel boundary is unaffected.
