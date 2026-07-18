#!/bin/sh
# Local chatmail relay for development and automated testing.
#
# Uses the official (experimental) chatmail container image with an
# underscore-prefixed domain: for such domains the server generates
# self-signed certs and skips DNS checks, and deltachat-core v2.49 skips TLS
# certificate verification for `_`-hosts by design (src/net/tls.rs) — the
# officially anticipated local-testing combination.
#
# One-time host setup (needs sudo, hence not automated here):
#   echo '127.0.0.1 _cm.example' | sudo tee -a /etc/hosts
# Podman machine must be running (macOS): podman machine start
set -eu

NAME=chatmail-dev
DOMAIN="${CHATMAIL_DOMAIN:-_cm.example}"
IMAGE="${CHATMAIL_IMAGE:-ghcr.io/chatmail/docker:main}"

case "${1:-up}" in
  up)
    # systemd container: podman supports these natively (--systemd=always).
    # Standard ports must stay standard: core's autoconfig and the
    # DCACCOUNT flow assume 443/465/587/993.
    # Upstream image is amd64-only; force the platform (Rosetta on Apple
    # Silicon podman machines executes it fine).
    podman run -d --name "$NAME" --replace \
      --platform "${CHATMAIL_PLATFORM:-linux/amd64}" \
      --systemd=always \
      --tmpfs /run --tmpfs /tmp \
      -e MAIL_DOMAIN="$DOMAIN" \
      -p 443:443 -p 465:465 -p 587:587 -p 993:993 \
      "$IMAGE"
    echo "chatmail relay starting as $DOMAIN (image: $IMAGE)"
    echo "check:  curl -kis --resolve $DOMAIN:443:127.0.0.1 https://$DOMAIN/new -X POST"
    echo "client: DCNATIVE_INSTANCE=DCACCOUNT:$DOMAIN"
    echo "tests:  DCVM_TEST_RELAY=DCACCOUNT:$DOMAIN cargo test --locked -- --ignored"
    ;;
  down)
    podman rm -f "$NAME"
    ;;
  logs)
    podman logs -f "$NAME"
    ;;
  *)
    echo "usage: $0 [up|down|logs]" >&2
    exit 2
    ;;
esac
