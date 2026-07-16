# Local chatmail relay (podman)

A local chatmail server so development and automated tests don't create throwaway
accounts on `nine.testrun.org`, and so multi-account message-flow tests can run
against real IMAP/SMTP.

## How it works

- **Image:** official `ghcr.io/chatmail/docker:main` (github.com/chatmail/docker,
  experimental but CI-built) — a Debian systemd container running the full relay
  stack via `cmdeploy run --ssh-host @local`.
- **The `_`-domain trick (officially supported):** deploying with
  `MAIL_DOMAIN=_cm.example` makes the server use self-signed certs and skip DNS
  checks, and deltachat-core skips TLS certificate verification for hostnames
  starting with `_` (core `src/net/tls.rs`: "used for servers with self-signed
  certificates, e.g. for local testing"). This covers IMAP, SMTP **and** the
  DCACCOUNT HTTPS POST — core otherwise only trusts compiled-in webpki roots, so
  no CA-store fiddling can help.
- **Account creation:** `DCACCOUNT:_cm.example` (bare domain) makes core invent
  random credentials locally — no HTTP involved — and chatmail creates the
  mailbox on first login. `DCACCOUNT:https://_cm.example/new` exercises the full
  POST flow too.

## Usage

```sh
podman machine start          # macOS; once
echo '127.0.0.1 _cm.example' | sudo tee -a /etc/hosts   # once
./dev/chatmail/run.sh up      # start relay (first pull is large)
DCNATIVE_INSTANCE=DCACCOUNT:_cm.example make run        # app against local relay
DCVM_TEST_RELAY=DCACCOUNT:_cm.example cargo test -- --ignored  # opt-in network tests
```

## Caveats (as of 2026-07)

- The image is amd64; on Apple Silicon the podman machine runs it via Rosetta.
  Untested upstream on arm64/podman (upstream CI uses Docker inside Incus/LXC,
  see github.com/chatmail/cmlxc). **Status here: unverified** — the podman VM
  could not boot inside the restricted agent session (Virtualization.framework
  denied); run from a normal terminal.
- May need higher inotify limits inside the podman VM:
  `podman machine ssh "sudo sysctl fs.inotify.max_user_instances=65536 fs.inotify.max_user_watches=65536"`.
- Second-device (backup transfer) tests do NOT need this server at all — they
  run offline over loopback iroh (see `dcvm/tests/vm.rs`).
- Fallback if the image misbehaves: any fake domain + explicit
  `EnteredLoginParam` with `AcceptInvalidCertificates` (what chatmail's own CI
  does for self-signed relays), or upstream's `cmlxc` rig on a Linux box.
