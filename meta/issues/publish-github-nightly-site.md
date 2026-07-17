# Publish: README, license, GitHub repo, nightly DMG, Pages site

## Summary

Take Estuary public: polish the README (with the logo), add the most
permissive license, create `github.com/lambadalambda/estuary` (public),
build a nightly DMG on every push to main via GitHub Actions, and host a
landing page on GitHub Pages describing the app and offering the download.

## Requirements

- README: logo, what/why, feature list, build instructions, license note.
- License: maximally permissive for OUR code (Unlicense — public-domain
  dedication). Note clearly: deltachat-core dependency stays MPL-2.0; the
  binary/DMG is therefore governed by core's license too.
- Public repo under `lambadalambda` (gh CLI is authed as that account).
- Workflow `nightly.yml`: on push to main + manual dispatch → rust tests,
  swift tests, `make app`, wrap in drag-to-Applications DMG, recreate the
  `nightly` prerelease with the DMG at a stable URL.
- `docs/` static site (Estuary palette, logo, Sora), served by GitHub Pages
  from main:/docs; download button → stable nightly asset URL; honest
  Gatekeeper note (ad-hoc signed, right-click → Open).

## Acceptance Criteria

- Repo public with all history pushed; Pages serves the site; the nightly
  workflow completes green and the DMG downloads from the stable URL.

## Notes

- CI uses the same dev-profile Rust + debug Swift as `make app` (honest
  nightly of the dev loop; release-profile packaging stays with
  app-bundle-polish).
- CI YAML/HTML/README are not unit-testable — verification is the live
  workflow run and the served page.
