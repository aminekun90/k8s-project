# Findings — Pi-hole/Unbound audit & hostname access (2026-06)

Audit of the live k3s cluster on the Raspberry Pi 4 (`192.168.1.42`), what was
broken, the fixes applied, and how to extend hostname-based access.

## TL;DR

Pi-hole was deployed but **never actually resolved upstream** (0 queries logged
for months). Root cause: the `unbound` Service was **TCP-only**, so Pi-hole's
UDP queries to it failed silently. Several other drifts (`:latest` images, web
LoadBalancer IP conflict) were fixed too. Hostname access (`pi.hole`,
`aladhan.app`) is now driven by a single `localApps` list.

## Bugs found & fixed

| Problem | Root cause | Fix |
|-|-|-|
| Upstream DNS never resolved (0 queries) | `unbound` Service exposed `5335/TCP` only → Pi-hole queries UDP → `host unreachable` | Service exposes **UDP + TCP** |
| Unbound refused queries | No `access-control` for the k3s pod CIDR (default allows only `127.0.0.1`) | `access-control: 10.0.0.0/8 allow` |
| Live images on `:latest` | Manual deploy diverged from the chart | Pinned `pihole:2026.06.0`, `klutchell/unbound:1.25.1` |
| Unbound 1.25 wouldn't start | Image is **distroless** (no `/bin/sh`), chart used `command: /bin/sh -c …` | Drop the command; mount config in `/etc/unbound/custom.conf.d/`; remove `root-hints` (image bundles its own); `so-rcvbuf/sndbuf: 0` |
| Pi-hole web LoadBalancer stuck `<pending>` | MetalLB pool `.42-.44` full (`.42`=adhan, `.43`=traefik, `.44`=pihole-dns); also k3s klipper vs MetalLB conflict | Web back to **NodePort 30080** |
| `pi.hole` resolved to pod IP | Pi-hole pins its own hostname to its listening (pod) IP | `FTLCONF_dns_reply_host_force4=true` + `FTLCONF_dns_reply_host_IPv4=<ingress IP>` |

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
  - host: pi.hole
    namespace: pihole
    service: pihole-web
    port: 80
  - host: aladhan.app
    namespace: adhan
    service: adhan-api
    port: 8000
```

Each entry generates:
- a dnsmasq record `address=/<host>/<lanIngressIP>` (ConfigMap mounted into
  Pi-hole at `/etc/dnsmasq.d/`, requires `FTLCONF_misc_etc_dnsmasq_d=true`)
- a traefik `Ingress` (`<host> → <service>:<port>`) created **in the app's
  namespace** (an Ingress backend must share its Service's namespace)

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

## Known structural issues (not yet fixed)

The cluster runs **two LoadBalancer controllers** (k3s klipper *ServiceLB* +
MetalLB) and **two ingress controllers** (traefik active on `.43`,
`ingress-nginx` stuck `<pending>` — its svclb can't bind `:80`, already held by
traefik). This is the source of the IP-allocation conflicts. Rationalising to a
single LB + single ingress would remove the noise. Left as a follow-up.
