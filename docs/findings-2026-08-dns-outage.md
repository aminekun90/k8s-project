# Findings — LAN-wide DNS outages traced to a dead third-party domain (2026-08)

For several days the whole house saw "latency" and "disconnections" on every
device. Nothing was actually disconnected: **DNS died in 45–52 second windows,
repeatedly**, and everything that needed a name resolution hung, then failed.

Pi-hole was blamed, audited, and found innocent. It was the amplifier, not the
cause.

## TL;DR

`extensions.socalifornian.live` — the API backend of the **Beautiful Lyrics**
Spicetify extension — **was removed from DNS**. The parent zone
`socalifornian.live` is still live on Cloudflare, but the `extensions` subdomain
returns NXDOMAIN from Cloudflare, Google and Quad9 alike. The record is gone.

The extension retries without backoff. One laptop therefore emitted **~300 DNS
queries/second, indefinitely, whether or not Spotify was playing**. That alone
should have been harmless. It took down the LAN because of two cluster-side
defects that turned one noisy client into a network-wide outage.

## The amplification chain

| # | Link | Effect |
|-|-|-|
| 1 | Extension retries a dead domain, no backoff | ~300 q/s from one host, permanently |
| 2 | k3s klipper (`svclb`) proxied `pihole-dns` and **SNATed** every packet | Pi-hole saw the entire LAN as one client: `10.42.0.1` (the cni0 bridge) |
| 3 | FTL's per-client rate limit (1000 q / 60 s) applied to that **aggregate** | Trips within seconds |
| 4 | Rate-limited ⇒ FTL answers `REFUSED` to everything from `10.42.0.1` | **Every device in the house loses DNS**, in 45–52 s bursts |

790 rate-limit events were in the logs. Link 2 also meant the offending device
was **invisible**: every query in the Pi-hole log carried the same source IP, so
the query log could not name the culprit. It had to be found with `tcpdump` on
the node's `eth0`, upstream of the SNAT.

Measured at the time: 8890 packets in 25 s for that one domain, 17 598 of the
21 356 queries in the preceding hour (82% of all DNS traffic).

## Fixes applied

| Problem | Root cause | Fix |
|-|-|-|
| One client can blackhole DNS for the whole LAN | klipper SNAT collapses every client to `10.42.0.1`, so the per-client rate limit is really a per-LAN limit | `service.dns.externalTrafficPolicy: Local`. k3s then drops its `svclb` DaemonSet for this service (klipper does not support `Local`) and MetalLB layer2 announces `.44` alone, preserving the client source IP |
| Rate limit could be silently re-tuned live and outlive a redeploy | `pihole-FTL --config` writes to `pihole.toml` on the PVC | `rateLimitCount` / `rateLimitInterval` in values, pushed as `FTLCONF_dns_rateLimit_*`; env wins over the toml on every start |

Verification — real client IPs now reach the query log instead of one aggregate:

```
10.42.0.1|922      <- genuine in-cluster traffic via CoreDNS (expected)
192.168.1.173|313  <- the laptop
192.168.1.45|16
192.168.1.127|1
```

## Two traps worth remembering

**Blocking a dead domain makes the flood worse.** Denylisting
`extensions.socalifornian.live` was the intuitive first move. It fed the loop:
1636 queries/15 s with the block, **0** without it. A blocked domain answers
NXDOMAIN instantly, the client retries instantly, forever. Letting it resolve
normally lets the negative answer be cached and the client goes quiet. The entry
was removed; Pi-hole's lists are back to their original state.

**A high query rate is not evidence of malware.** The traffic pattern and the
domain name led to an initial "adware / malicious infrastructure" call that the
evidence did not support. The host was clean: no suspicious LaunchAgents, no
third-party browser extensions, no configuration profiles. It was a legitimate
extension failing loudly against a decommissioned backend. Attribute from
evidence, not from shape.

## Not the cause

The Pi itself was healthy throughout and never needed touching: load 0.4,
38.9 °C, no throttling (`throttled=0x0`), disk at 39%, no kernel or SD-card I/O
errors, no pod in crash-loop — every restart count in the cluster dated from the
last reboot 9 days earlier.

## Left to do

Uninstall Beautiful Lyrics from the Spicetify Marketplace. The client still
queries a domain that will never resolve; harmless now, pointless always.
