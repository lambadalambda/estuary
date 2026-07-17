# Whole-app bug audit

## Summary

Systematic review of dcvm + the macOS app for bugs missed during feature work:
concurrency, FFI semantics, state-machine holes, UX logic.

## Requirements

- Parallel focused reviews (Rust/FFI, Swift concurrency/bridge, app state/UX logic).
- Findings verified against the actual code and core v2.53 sources before fixing.
- Confirmed bugs fixed with tests where practical; all suites green after.

## Acceptance Criteria

- Review findings triaged (fixed / rejected with reason) and documented in DEVLOG.
