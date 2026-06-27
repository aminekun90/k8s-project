# Make your whole network use Pi-hole (any ISP / router, worldwide)

Pi-hole only filters devices that use it for DNS. There are three ways to make
that happen — pick the first that your router allows.

```
device ─DNS→ Pi-hole (192.168.1.42) ─→ Unbound (recursive) ─→ root DNS servers
```

| Method | Works on | Effort |
|-|-|-|
| 1. Router DHCP → Pi-hole DNS | Most routers (incl. Freebox) | Easiest |
| 2. Pi-hole as DHCP server | **Anything, worldwide** (when the box blocks custom DNS) | Medium |
| 3. Per-device DNS | Any single device | Per device |

Pi-hole's IP is the MetalLB LoadBalancer address (`192.168.1.42` by default —
see `helm-charts/pihole/values.yaml`). Confirm it:

```bash
kubectl -n pihole get svc pihole-dns
```

---

## Method 1 — point the router's DHCP DNS at Pi-hole

Set the **DNS server the router advertises via DHCP** to `192.168.1.42`. Every
device then uses Pi-hole automatically.

### 🇫🇷 Free — Freebox (Pop / Delta / Revolution) — automated

The Freebox has a local API, so this repo automates it:

```bash
python3 scripts/freebox-dns.py --dns 192.168.1.42   # press the Freebox arrow once
python3 scripts/freebox-dns.py --show                # check current DHCP DNS
python3 scripts/freebox-dns.py --revert              # hand DNS back to the Freebox
```

Or in one go during deploy: `FREEBOX_DNS_IP=192.168.1.42 ./deploy.sh`.
Manual path: `http://mafreebox.freebox.fr` → **Paramètres → DHCP → DNS**.

A Freebox firmware update can reset the DNS; re-assert it weekly via cron (the
cached token keeps it non-interactive):

```bash
# crontab -e
0 4 * * 1  /usr/bin/python3 /home/pi/k8s-project/scripts/freebox-dns.py --dns 192.168.1.42 >> /var/log/freebox-dns.log 2>&1
```

### 🇫🇷 Orange — Livebox

`http://192.168.1.1` → **Configuration avancée → DHCP**. Many Liveboxes **do
not** let you change the DNS handed to clients — if the DNS field is missing or
ignored, use **Method 2** (Pi-hole DHCP) or Method 3.

### 🇫🇷 Bouygues — Bbox

`http://mabbox.bytel.fr` (or `192.168.1.254`) → **Réseau → DHCP** (sometimes
under **DNS**). Set the primary DNS to `192.168.1.42`.

### 🇫🇷 SFR / RED — SFR Box

`http://192.168.1.1` → **Réseau → DHCP**. Set the DNS to `192.168.1.42`.
(Older NB6/NB6V boxes may not expose it — use Method 2.)

### 🌍 Any other router (worldwide)

Open the router admin (often `192.168.0.1` / `192.168.1.1`), find **LAN / DHCP
settings**, and set the **DNS server** to `192.168.1.42`. Save and reboot the
router (or renew leases). If there's no such field, use Method 2.

> After changing it, devices apply the new DNS on their **next DHCP lease**
> (reconnect Wi-Fi or reboot).

---

## Method 2 — Pi-hole as the DHCP server (universal fallback)

When the ISP box won't let you set a custom DNS (common on Orange Livebox and
some SFR boxes), let **Pi-hole hand out DHCP** instead. This works behind *any*
router, anywhere.

1. **Disable the router's own DHCP server** (so there's only one). Leave the
   router as the gateway.
2. Enable Pi-hole DHCP and redeploy:

   ```bash
   helm upgrade --install pihole helm-charts/pihole -n pihole \
     --set existingSecret=pihole-admin \
     --set dhcp.enabled=true \
     --set dhcp.start=192.168.1.100 \
     --set dhcp.end=192.168.1.200 \
     --set dhcp.router=192.168.1.254     # your gateway (the ISP box) IP
   ```

   This switches the Pi-hole pod to `hostNetwork` (needed to receive DHCP
   broadcasts) and turns on its DHCP server. Adjust the range/gateway to your
   LAN in `helm-charts/pihole/values.yaml`.

3. Renew a device's lease and confirm it got an IP in your range with DNS =
   Pi-hole.

> Trade-off: Pi-hole is now the DHCP **and** DNS authority — if the Pi is down,
> new devices won't get a lease. Keep the router DHCP config handy to re-enable.

---

## Method 3 — per-device DNS (quick test / single device)

Set the device's DNS manually to `192.168.1.42`:

- **Windows**: Adapter settings → IPv4 → Preferred DNS.
- **macOS**: System Settings → Network → Details → DNS.
- **iOS/Android**: Wi-Fi network → configure DNS → Manual.

---

## Verify

```bash
dig @192.168.1.42 example.com +short        # resolves
dig @192.168.1.42 doubleclick.net +short    # blocked -> 0.0.0.0 / NXDOMAIN
```

Then watch the live query log at `http://192.168.1.42/admin`.

## `.home` hostnames flaky / ads still get through — the IPv6 DNS race

Symptom: `http://aladhan.home` works one second and "can't resolve" the next,
and some ads slip past Pi-hole.

**Root cause** — devices get **two** DNS resolvers and race between them:

| Family | Resolver | Knows `.home`? | Filters ads? |
|-|-|-|-|
| IPv4 | `192.168.1.44` (Pi-hole, via DHCP) | yes | yes |
| IPv6 | `fd0f:ee:b0::1` (the Freebox itself, via RA/RDNSS) | **no** | **no** |

When the IPv6 (Freebox) resolver answers first, `.home` returns NXDOMAIN and ad
queries bypass Pi-hole entirely. Confirmed: querying Pi-hole directly is 10/10,
but the macOS system resolver is 0/10 for `.home` while both nameservers are set.

**Also note the port:** services are exposed by Traefik on **port 80** —
use `http://aladhan.home`, not `http://aladhan.home:8000` (`:8000` is the raw
service IP and bypasses the ingress).

### Fixes

1. **Per-device stopgap (macOS/iOS)** — force `*.home` to Pi-hole only:
   ```bash
   sudo mkdir -p /etc/resolver
   echo "nameserver 192.168.1.44" | sudo tee /etc/resolver/home
   sudo dscacheutil -flushcache && sudo killall -HUP mDNSResponder
   ```
   Doesn't scale (per machine) — use a LAN-wide fix below.

2. **LAN-wide — make Pi-hole the only resolver.** IPv4 is already done
   (`freebox-dns.py --dns 192.168.1.44`). The IPv6 side is the problem:

   - This cluster's **k3s is single-stack IPv4** (`service-cidr` is IPv4 only), so
     you **cannot** give the `pihole-dns` Service an IPv6 via MetalLB without
     rebuilding the cluster dual-stack. Don't do that for home DNS.
   - **Option A (simplest, recommended): disable IPv6 on the Freebox.** Devices
     then get only the IPv4 Pi-hole resolver → `.home` solid, ads filtered.
     Trade-off: no IPv6 on the LAN (fine for a home LAN with no NAS / remote
     access — IPv4 covers all browsing, streaming, apps; fully reversible).
     - **On the Freebox Pop the API rejects the toggle** ("Impossible de
       récupérer l'état de la connexion"), so do it in the **UI**:
       `http://mafreebox.freebox.fr → Paramètres de la Freebox → Configuration
       IPv6 (ou Mode réseau) → désactiver → valider`. (`freebox-dns.py
       --disable-ipv6` tries the API and prints these steps on failure.)
     - **Re-enable later** (e.g. you add a NAS or want IPv6 remote access): same
       UI toggle, or `freebox-dns.py --enable-ipv6`. Re-enabling brings back the
       IPv6 DNS race, so you'd then need a node-level IPv6 forwarder (Option B).
   - **Option B (keep IPv6): a node-level IPv6 DNS forwarder.** Give the Pi a
     static ULA (e.g. `fd0f:ee:b0::44`), run a tiny forwarder there
     (`[fd0f:ee:b0::44]:53` → `192.168.1.44#53`), and set the Freebox DHCPv6
     custom DNS to it (`PUT /api/v8/dhcpv6/config {"enabled": true,
     "use_custom_dns": true, "dns": {...}}`). More moving parts, and **macOS/iOS
     often prefer the RA/RDNSS resolver over DHCPv6**, so test that clients
     actually pick it up before relying on it.

## Caveats (all methods)

- **IPv6**: if your LAN hands out IPv6 DNS, devices may bypass Pi-hole — see the
  IPv6 DNS race section above.
- **DoH/DoT**: browsers/phones with "secure DNS" enabled ignore your LAN DNS.
  Turn that off per device for full coverage.
- **Single point of failure**: if the Pi is down, DNS (and DHCP in Method 2)
  stop. Consider a secondary resolver.
- **Firmware updates** can reset router DNS/DHCP settings — re-apply after.
