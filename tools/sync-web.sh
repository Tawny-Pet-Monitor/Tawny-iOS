#!/usr/bin/env bash
# Vendor the shared web app (Tawny Android's public/) into Tawny/Web, and write
# config.json the way the Android build does (webConfigJson() in
# android/app/build.gradle.kts), so both apps meet on the same rendezvous and
# Nostr relays. Run it after the web app changes, then commit Tawny/Web.
#
#   tools/sync-web.sh                    # from ../Tawny Android
#   TAWNY_ANDROID=/path tools/sync-web.sh
set -euo pipefail

here=$(cd "$(dirname "$0")/.." && pwd)
android="${TAWNY_ANDROID:-$here/../Tawny Android}"
src="$android/public"
dst="$here/Tawny/Web"

[ -f "$src/index.html" ] || { echo "no web app at $src" >&2; exit 1; }

# Same defaults as the Android release build. Override per sync if needed.
rendezvous="${TAWNY_RENDEZVOUS:-wss://tawny-rendezvous.tawny1.workers.dev}"
stun="${TAWNY_STUN:-stun:stun.cloudflare.com:3478,stun:stun.l.google.com:19302}"
nostr="${TAWNY_NOSTR:-wss://relay.primal.net,wss://relay.nostr.net,wss://relay.snort.social}"
nostr_mode="${TAWNY_NOSTR_MODE:-prefer}"

mkdir -p "$dst"
rsync -a --delete \
  --exclude '.DS_Store' --exclude 'README.md' --exclude 'sounds/_src/' \
  "$src/" "$dst/"

python3 - "$dst/config.json" "$rendezvous" "$stun" "$nostr" "$nostr_mode" <<'EOF'
import json, sys
out, rendezvous, stun, nostr, mode = sys.argv[1:]
cfg = {
    "stun": [s.strip() for s in stun.split(",") if s.strip()],
    "rendezvous": rendezvous,
    "turnMode": "auto",
    "authRequired": False,
}
relays = [r.strip() for r in nostr.split(",") if r.strip()]
if relays and mode != "off":
    cfg["nostr"] = {"relays": relays, "mode": mode}
with open(out, "w") as f:
    json.dump(cfg, f, separators=(",", ":"))
EOF

rev=$(git -C "$android" rev-parse --short HEAD 2>/dev/null || echo unknown)
dirty=$(git -C "$android" status --porcelain -- public 2>/dev/null | head -1)
printf 'Tawny/Web synced from Tawny Android %s%s on %s\n' \
  "$rev" "${dirty:+ (with uncommitted changes in public/)}" "$(date -u +%Y-%m-%dT%H:%MZ)" \
  > "$here/tools/web-source.txt"
cat "$here/tools/web-source.txt"
du -sh "$dst"
