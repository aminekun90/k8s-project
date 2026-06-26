# Findings — Pi-hole/Unbound audit & hostname access (2026-06)

Audit of the live k3s cluster on the Raspberry Pi 4 (`192.168.1.42`), what was
broken, the fixes applied, and how to extend hostname-based access.

## TL;DR

Pi-hole was deployed but **never actually resolved upstream** (0 queries logged
for months). Root cause: the `unbound` Service was **TCP-only**, so Pi-hole's
UDP queries to it failed silently. Several other drifts (`:latest` images, web
LoadBalancer IP conflict) were fixed too. Hostname access (`pihole.home`,
`aladhan.home`) is now driven by a single `localApps` list.

**Browser URLs:** `http://pihole.home` (redirects to `/admin/`) and
`http://aladhan.home`. The old `.app`/`.hole` names are gone — `.app` is
HSTS-preloaded and unusable without a publicly-trusted cert.

## Bugs found & fixed

| Problem | Root cause | Fix |
|-|-|-|
| Upstream DNS never resolved (0 queries) | `unbound` Service exposed `5335/TCP` only → Pi-hole queries UDP → `host unreachable` | Service exposes **UDP + TCP** |
| Unbound refused queries | No `access-control` for the k3s pod CIDR (default allows only `127.0.0.1`) | `access-control: 10.0.0.0/8 allow` |
| Live images on `:latest` | Manual deploy diverged from the chart | Pinned `pihole:2026.06.0`, `klutchell/unbound:1.25.1` |
| Unbound 1.25 wouldn't start | Image is **distroless** (no `/bin/sh`), chart used `command: /bin/sh -c …` | Drop the command; mount config in `/etc/unbound/custom.conf.d/`; remove `root-hints` (image bundles its own); `so-rcvbuf/sndbuf: 0` |
| Pi-hole web LoadBalancer stuck `<pending>` | MetalLB pool `.42-.44` full (`.42`=adhan, `.43`=traefik, `.44`=pihole-dns); also k3s klipper vs MetalLB conflict | Web back to **NodePort 30080** |
| `pi.hole` resolved to pod IP | Pi-hole pins its own hostname to its listening (pod) IP | `FTLCONF_dns_reply_host_force4=true` + `FTLCONF_dns_reply_host_IPv4=<ingress IP>` |
| **Whole-LAN DNS outage after a reboot** | upstream was a **hostname** (`unbound...svc.cluster.local`); dnsmasq resolves `server=` at startup → chicken-and-egg on cold boot → FTL refuses to start (`CRIT: Cannot resolve server name`) | Point `upstreamDns` at unbound's **fixed ClusterIP** (`10.43.110.126`, pinned in `unbound-service.yaml`) — no resolution at boot |
| Pi-hole diag: `TCP connection failed (Host is unreachable)` to unbound | The live `unbound` Service had only the **UDP** port; the TCP port had silently dropped (`kubectl apply` 3-way merge didn't add it on a service created without the last-applied annotation) | `kubectl patch` to set both ports explicitly; template keeps UDP+TCP |
| `aladhan.app`/`pi.hole` blocked in browser (`MOZILLA_PKIX_ERROR_SELF_SIGNED_CERT`, can't bypass) | `.app` is **HSTS-preloaded** → browsers force HTTPS and refuse any non-public cert (no click-through). `.hole` hit the same HTTPS-first wall | Switch local hostnames to **`.home`** (`pihole.home`, `aladhan.home`) — plain HTTP everywhere, no cert |
| `pihole.home` resolved to `.42` (403) | Stale `dns.hosts` entries (`192.168.1.42 pi.hole` / `pihole.home`) overrode the dnsmasq records | Force `FTLCONF_dns_hosts=""`; local records come only from `/etc/dnsmasq.d` |

## IP map (MetalLB pool 192.168.1.42–.44)

| IP | Owner |
|-|-|
| `.42` | k3s node InternalIP + `adhan-api` LoadBalancer (`:8000`) |
| `.43` | **traefik** LoadBalancer (`:80/:443`) — the HTTP entrypoint |
| `.44` | `pihole-dns` LoadBalancer (`:53`) — set your DNS to this |

Pi-hole admin UI is also on NodePort: `http://192.168.1.42:30080/admin`.

## Hostname access — how it works & how to add an app

A single list in `helm-charts/pihole/values.yaml` drives **both** the local DNS
record and the traefik Ingress:

```yaml
ingressClassName: traefik
lanIngressIP: 192.168.1.43   # traefik LoadBalancer IP
localApps:
  - host: pihole.home
    namespace: pihole
    service: pihole-web
    port: 80
    rootRedirectTo: /admin/   # optional: bare host -> this path (traefik middleware)
  - host: aladhan.home
    namespace: adhan
    service: adhan-api
    port: 8000
```

Each entry generates:
- a dnsmasq record `address=/<host>/<lanIngressIP>` (ConfigMap mounted into
  Pi-hole at `/etc/dnsmasq.d/`, requires `FTLCONF_misc_etc_dnsmasq_d=true`)
- a traefik `Ingress` (`<host> → <service>:<port>`) created **in the app's
  namespace** (an Ingress backend must share its Service's namespace)
- optionally, if `rootRedirectTo` is set, a traefik `Middleware` that redirects
  the bare host `/` to that path (e.g. Pi-hole serves its UI under `/admin/`)

**Use `.home`, not `.app`/`.hole`**: `.app` is on the HSTS preload list so
browsers force HTTPS and reject self-signed certs with no bypass. `.home` works
over plain HTTP on every device (no per-device cert/CA to install).

**To add a new app:** append one entry to `localApps` and run `./deploy.sh`
(or `helm upgrade … pihole`). Nothing else to touch.

> Requirement: a client only resolves these names if it uses **`192.168.1.44`**
> (Pi-hole) as its DNS server. See `docs/dns-setup.md`.

## LAN-wide DNS rollout (done)

Pi-hole only serves a device if that device uses **`192.168.1.44`** as its DNS.
This was rolled out to the whole house via the Freebox DHCP.

### Freebox (whole house)

The Freebox is the LAN DHCP server, so the clean way to push Pi-hole everywhere
is to set the DHCP-advertised DNS. Done via `scripts/freebox-dns.py` (Freebox OS
API, stdlib only):

```bash
python3 scripts/freebox-dns.py --show              # current DHCP DNS
python3 scripts/freebox-dns.py --dns 192.168.1.44  # point the house at Pi-hole
python3 scripts/freebox-dns.py --revert            # back to the Freebox itself
```

Gotchas encountered:
- **First run pairs the app**: press the RIGHT ARROW on the Freebox front panel
  within 60s. Token is cached in `scripts/.fbx_token.json` (gitignored).
- **Permission must be enabled manually**: after pairing, the update failed with
  *"Cette application n'est pas autorisée à accéder à cette fonction"*. Fix:
  Freebox OS → Paramètres → Gestion des accès → Applications → "Aladhan DNS
  Setup" → enable **"Modification des réglages de la Freebox"**, then re-run.
- Result: DHCP DNS went from `['192.168.1.254', ...]` to `['192.168.1.44', ...]`.
- **`--host` now defaults to the LAN IP `192.168.1.254`**, not
  `mafreebox.freebox.fr`: once the LAN uses Pi-hole/unbound, that hostname
  resolves to Free's **public** IP (no split-horizon) and the local API times out.
- **Don't add `8.8.8.8` as a secondary DNS**: it isn't a true failover — clients
  query either resolver unpredictably, so part of the traffic bypasses Pi-hole's
  filtering. Keep Pi-hole alone (`--dns 192.168.1.44`). It was briefly added as a
  safety net during an outage, then removed once Pi-hole was hardened.

### Clients pick it up on lease renewal

Devices use the new DNS only after a DHCP lease renewal. To force it on macOS,
a `ipconfig set en0 DHCP` was **not** enough — had to **cycle Wi-Fi**:

```bash
networksetup -setdnsservers Wi-Fi empty   # use DHCP-provided DNS (not a manual one)
networksetup -setairportpower en0 off && sleep 3 && networksetup -setairportpower en0 on
scutil --dns | grep 'nameserver\[0\]'     # should now show 192.168.1.44
```

For a quick single-machine test without touching the Freebox:
`networksetup -setdnsservers Wi-Fi 192.168.1.44` (revert with `… empty`).

### Static IP for the Pi (reboot safety)

The whole setup depends on the Pi being `192.168.1.42` (node IP + MetalLB pool
`.42-.44`). The Pi's `eth0` is **DHCP** (`ipv4.method: auto`), so after a Freebox
reboot a different IP could in theory be leased and break everything. Fixed with
a **static DHCP lease** on the Freebox:

```bash
python3 scripts/freebox-dns.py --reserve dc:a6:32:a7:78:41=192.168.1.42 \
  --comment "Raspberry Pi k3s (Pi-hole)"
```

(Pi `eth0` MAC: `dc:a6:32:a7:78:41`.) The Pi now always gets `.42`.

### ⚠️ Operational note — rebooting the Freebox is safe

- The DHCP DNS setting (`192.168.1.44`) and the static lease are **persistent**;
  they survive a Freebox reboot.
- Pi-hole runs on the Pi independently — as long as the **Pi stays up**, DNS keeps
  working. Reboot the Freebox alone without worry.
- The only hard dependency: **if the Pi is down, there is no DNS on the LAN.**
  Emergency rollback to the Freebox resolver: `python3 scripts/freebox-dns.py --revert`.

## Blocklists (gravity) — enriched

Default was only StevenBlack (~84k domains). Added curated lists → **~1.86M
unique domains**. Lists live in the gravity DB on the PVC (persistent across
restarts) but are **not** in git — re-add them with:

```bash
kubectl exec -n pihole deploy/pihole -- pihole-FTL sqlite3 /etc/pihole/gravity.db "
INSERT OR IGNORE INTO adlist (address, enabled, comment) VALUES
 ('https://big.oisd.nl', 1, 'OISD Big (all-in-one)'),
 ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/pro.txt', 1, 'Hagezi Multi PRO'),
 ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/native.samsung.txt', 1, 'Hagezi Samsung Tizen telemetry/ads'),
 ('https://raw.githubusercontent.com/hagezi/dns-blocklists/main/adblock/tif.txt', 1, 'Hagezi Threat Intelligence');"
kubectl exec -n pihole deploy/pihole -- pihole -g   # rebuild gravity
```

If a site breaks, whitelist the domain (Pi-hole UI → Domains → Allow) rather
than removing a whole list.

### YouTube ads — Pi-hole can't block them

YouTube serves ads from the **same domains as the video** (`googlevideo.com`);
blocking them breaks playback. No DNS blocklist fixes this reliably.
- **Android TV / Fire TV / Shield**: SmartTube (sideloaded) blocks them client-side.
- **Samsung Tizen / Apple TV**: no good blocker → YouTube Premium, or watch via a
  browser/device that has an ad blocker. Pi-hole still blocks Samsung's own
  telemetry/ads (`ads.samsung.com`, `samsungads.com`, etc.).

### Smart TVs that bypass Pi-hole

Many TVs hardcode `8.8.8.8` or use DoH, ignoring the DHCP-advertised DNS. To
force them through Pi-hole you'd need to redirect/block outbound port 53 (and
DoH) at the router — not easily doable on the Freebox.

## Known structural issues (not yet fixed)

The cluster runs **two LoadBalancer controllers** (k3s klipper *ServiceLB* +
MetalLB) and **two ingress controllers** (traefik active on `.43`,
`ingress-nginx` stuck `<pending>` — its svclb can't bind `:80`, already held by
traefik). This is the source of the IP-allocation conflicts. Rationalising to a
single LB + single ingress would remove the noise. Left as a follow-up.
