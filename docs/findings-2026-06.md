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

## Known structural issues (not yet fixed)

The cluster runs **two LoadBalancer controllers** (k3s klipper *ServiceLB* +
MetalLB) and **two ingress controllers** (traefik active on `.43`,
`ingress-nginx` stuck `<pending>` — its svclb can't bind `:80`, already held by
traefik). This is the source of the IP-allocation conflicts. Rationalising to a
single LB + single ingress would remove the noise. Left as a follow-up.
