#!/usr/bin/env bash
#
# Health-checked DNS failover for the k3s node's dnsmasq.
#
# Why this exists rather than a second `server=` line in dnsmasq:
#
#   - `strict-order` does NOT fail over on timeout. dnsmasq retries the first
#     server forever and only advances on an explicit error reply. Measured on
#     2026-09-09 with Pi-hole scaled to 0: no answer at 2s, 5s, 10s or 20s.
#   - Dropping `strict-order` makes dnsmasq race every upstream in parallel and
#     keep the first reply. Ads would still be blocked (the fallback filters
#     too), but the filtering POLICY becomes nondeterministic: custom
#     allow/deny entries would apply only when Pi-hole happens to win the race,
#     and the query log would stop reflecting reality.
#
# So: exactly one upstream is active at any time, chosen by an actual health
# check. Normal operation is unchanged and fully deterministic; the fallback is
# an ad-filtering resolver, so no window exists where ads get through.
set -euo pipefail

CANARY="${CANARY:-example.com}"
PRIMARY="${PRIMARY:-192.168.1.44}"          # Pi-hole (in-cluster LoadBalancer)
FALLBACK1="${FALLBACK1:-94.140.14.14}"      # AdGuard DNS — filters ads
FALLBACK2="${FALLBACK2:-94.140.15.15}"
CONF=/etc/dnsmasq.d/pihole.conf
STATE=/run/dns-failover.state
# Require N consecutive verdicts before switching, so one dropped packet or a
# rolling pod restart does not flap the whole LAN's resolver.
THRESHOLD="${THRESHOLD:-2}"

log() { logger -t dns-failover "$1"; }

write_primary() {
  cat <<EOF
# MANAGED BY dns-failover.service — edits are overwritten.
# State: PRIMARY (Pi-hole). Source of truth: clusters/pi/node-dns/ in k8s-project.
no-resolv
interface=eth0
server=$PRIMARY
EOF
}

write_fallback() {
  cat <<EOF
# MANAGED BY dns-failover.service — edits are overwritten.
# State: FALLBACK — Pi-hole unreachable. Upstream filters ads too, so no leak.
no-resolv
interface=eth0
# .home records only exist in Pi-hole; a public resolver answers NXDOMAIN for
# them. Keep them pointed at Pi-hole so they resolve the moment it returns,
# instead of caching a negative answer for the whole TTL.
server=/home/$PRIMARY
server=$FALLBACK1
server=$FALLBACK2
EOF
}

healthy() { dig "@$PRIMARY" "$CANARY" +short +time=2 +tries=1 >/dev/null 2>&1; }

current=$(cat "$STATE" 2>/dev/null || echo primary)
streak_file="/run/dns-failover.streak"
streak=$(cat "$streak_file" 2>/dev/null || echo 0)

if healthy; then verdict=primary; else verdict=fallback; fi

# Decide the target state: only switch after THRESHOLD consecutive disagreeing
# verdicts, so one dropped packet or a rolling pod restart cannot flap the LAN.
target="$current"
if [ "$verdict" = "$current" ]; then
  echo 0 > "$streak_file"
else
  streak=$((streak + 1))
  echo "$streak" > "$streak_file"
  if [ "$streak" -ge "$THRESHOLD" ]; then
    target="$verdict"
    echo 0 > "$streak_file"
  fi
fi

# Reconcile the file against the target state on EVERY run, not just on
# transitions: a config edited by hand, restored from an old copy, or left over
# from a previous design would otherwise persist unnoticed until the next
# failover. dnsmasq is only restarted when the content actually changes.
tmp=$(mktemp)
trap 'rm -f "$tmp"' EXIT
if [ "$target" = "fallback" ]; then write_fallback > "$tmp"; else write_primary > "$tmp"; fi

if ! cmp -s "$tmp" "$CONF"; then
  install -m 0644 "$tmp" "$CONF"
  if [ "$target" != "$current" ]; then
    if [ "$target" = "fallback" ]; then
      log "Pi-hole unreachable at $PRIMARY — switching to filtering fallback"
    else
      log "Pi-hole is back at $PRIMARY — switching back to primary"
    fi
  else
    log "dnsmasq config drifted from state '$target' — rewritten"
  fi
  systemctl restart dnsmasq
fi
echo "$target" > "$STATE"
