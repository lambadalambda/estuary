# Branch protection

Protect `main` and require the pull-request workflow's `check / check` status.
That single job runs locked Rust and Swift tests, a non-interactive Swift link,
strict Rust formatting and Clippy checks, and rejects stale or untracked UniFFI
bindings. Also require branches to be up to date before merging so the status
applies to the final merge base.
