# Local chatmail relay test infrastructure (podman)

## Summary
Local relay (official chatmail image, underscore-domain self-signed mode) so dev and
automated tests stop touching nine.testrun.org; opt-in network tests.

## Outcome
Done 2026-07-16. dev/chatmail/run.sh; instant-account + encrypted round-trip tests green.
Findings: filtermail rejects unencrypted first contact; first-scan race (see DEVLOG).
