# publish-ip: write this notebook's current IP address to
# ~/polybox/aktuell/current-ip.txt, so you can find it from home. The
# Nextcloud client syncs it to polybox. A timer runs it every 30 minutes
# (see home.nix); run `publish-ip` to write it right away.
#
# The Nextcloud client only runs while you're logged in. After a restart the
# file is written, but polybox gets it only once someone logs in.
set -euo pipefail

FILE="$HOME/polybox/aktuell/current-ip.txt"
# An address on the office network (ETH's DNS server), to ask the routing
# table which of our addresses faces it.
PROBE=129.132.98.12

die() {
  echo "publish-ip: $*" >&2
  exit 1
}

[ -d "$(dirname "$FILE")" ] || die "$(dirname "$FILE") doesn't exist."
ip="$(ip -4 route get "$PROBE" 2>/dev/null | sed -n 's/.* src \([0-9.]*\).*/\1/p')"
[ -n "$ip" ] || die "no network connection (no route to $PROBE)."

# Write a temporary file and rename it, so the sync never sees half a file.
cat >"$FILE.tmp" <<EOF
$(cat /proc/sys/kernel/hostname): $ip
as of $(date '+%Y-%m-%d %H:%M') (updated every 30 minutes)

ssh -L 5901:localhost:5901 $USER@$ip
EOF
mv "$FILE.tmp" "$FILE"
echo "Wrote $ip to $FILE"
