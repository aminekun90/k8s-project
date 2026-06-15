# Using Pi-hole + Unbound behind a Freebox Pop

On a Freebox network the **box is the DHCP server**, so to make every device
filter ads/trackers you point the Freebox's DHCP-advertised DNS at Pi-hole.
Pi-hole then forwards to **Unbound**, a local recursive resolver — no public
upstream DNS (Google/Cloudflare) is used.

```
device ──DHCP──> Freebox Pop ──hands out DNS = Pi-hole IP
device ──DNS──>  Pi-hole (192.168.1.42)  ──>  Unbound (recursive)  ──>  root servers
```

## 1. Deploy the cluster

```bash
./deploy.sh            # or: PIHOLE_PASSWORD=… ./deploy.sh
```

Pi-hole gets a MetalLB LoadBalancer IP (default `192.168.1.42`, see
`helm-charts/pihole/values.yaml`). Confirm it:

```bash
kubectl -n pihole get svc pihole-dns
```

## 2. Point the Freebox DHCP at Pi-hole

### Option A — automated (recommended)

```bash
python3 scripts/freebox-dns.py --dns 192.168.1.42
```

First run pairs the app: **press the right arrow on the Freebox front panel**
when prompted (one time; the token is cached). You can also do it in one go:

```bash
FREEBOX_DNS_IP=192.168.1.42 ./deploy.sh
```

Useful commands:

```bash
python3 scripts/freebox-dns.py --show     # show the current DHCP DNS
python3 scripts/freebox-dns.py --revert   # hand DNS back to the Freebox
```

### Option B — manual (Freebox OS UI)

`http://mafreebox.freebox.fr` → **Paramètres de la Freebox → DHCP** → set the
**DNS** field to `192.168.1.42` → save.

After either option, devices pick up the new DNS on their **next DHCP lease**
(reconnect Wi-Fi or reboot to apply now).

## 3. Verify

```bash
# Resolves through Pi-hole:
dig @192.168.1.42 example.com +short
# A blocked domain returns 0.0.0.0 / NXDOMAIN:
dig @192.168.1.42 doubleclick.net +short
```

Then watch the live query log in the Pi-hole UI (`http://192.168.1.42/admin`).

## Notes & caveats

- **Freebox Pop quirks**: some firmware restricts the DHCP DNS field or keeps
  answering DNS on `192.168.1.254`. If clients ignore Pi-hole, set the DNS
  per-device, or disable the Freebox's own DNS/DHCP and let Pi-hole serve DHCP
  (advanced — not covered here).
- **IPv6**: if your LAN uses IPv6, devices may still use the Freebox's IPv6
  DNS and bypass Pi-hole. Disable IPv6 DNS on the Freebox or give Pi-hole an
  IPv6 address for full coverage.
- **Don't lose DNS if the Pi is down**: Pi-hole becomes a single point of
  failure for name resolution. Keep `--revert` handy, or set a secondary DNS.
- **Re-assert after firmware updates**: a Freebox update can reset the DHCP
  DNS. Re-run the script, or schedule it (see below).

## Automating re-assertion (optional)

The DHCP DNS setting persists, but if you want to guarantee it after reboots/
updates, schedule the script on the Pi with a weekly cron entry:

```bash
# crontab -e   (the cached token makes it non-interactive)
0 4 * * 1  /usr/bin/python3 /home/pi/k8s-project/scripts/freebox-dns.py --dns 192.168.1.42 >> /var/log/freebox-dns.log 2>&1
```
