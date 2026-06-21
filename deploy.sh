#!/usr/bin/env bash
#
# One-shot deploy for the k3s home cluster (Pi-hole + Unbound + Adhan API).
# Idempotent: safe to re-run (helm upgrade --install). Run it on the Pi, or
# from your Mac with KUBECONFIG pointing at the cluster.
#
# Usage:
#   ./deploy.sh                          # prompts for the Pi-hole password (first run)
#   PIHOLE_PASSWORD=secret ./deploy.sh   # non-interactive
#   FREEBOX_DNS_IP=192.168.1.42 ./deploy.sh   # also point the Freebox DHCP at Pi-hole
#   ADHAN_NODE=raspberrypi ./deploy.sh   # pin Adhan to the Pi with the speakers
#
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
cd "$SCRIPT_DIR"

PIHOLE_NS="${PIHOLE_NS:-pihole}"
ADHAN_NS="${ADHAN_NS:-adhan}"
PIHOLE_SECRET="${PIHOLE_SECRET:-pihole-admin}"

need() { command -v "$1" >/dev/null 2>&1 || { echo "ERROR: '$1' not found in PATH"; exit 1; }; }
need kubectl
need helm

echo "==> Namespaces"
kubectl apply -f namespaces/pihole-namespace.yaml
kubectl apply -f namespaces/adhan-namespace.yaml

echo "==> MetalLB address pool"
kubectl apply -f metallb-pool.yaml

echo "==> Pi-hole admin password (Secret '$PIHOLE_SECRET')"
if kubectl -n "$PIHOLE_NS" get secret "$PIHOLE_SECRET" >/dev/null 2>&1; then
  echo "    Secret already exists — keeping the current password."
else
  PW="${PIHOLE_PASSWORD:-}"
  if [ -z "$PW" ]; then
    read -rsp "    Enter a Pi-hole admin password: " PW; echo
  fi
  kubectl -n "$PIHOLE_NS" create secret generic "$PIHOLE_SECRET" --from-literal=password="$PW"
  echo "    Created Secret '$PIHOLE_SECRET'."
fi

echo "==> Deploying Pi-hole + Unbound"
helm upgrade --install pihole helm-charts/pihole -n "$PIHOLE_NS" \
  --set existingSecret="$PIHOLE_SECRET"

echo "==> Deploying Adhan API"
ADHAN_ARGS=()
if [ -n "${ADHAN_NODE:-}" ]; then
  echo "    Pinning Adhan to node '$ADHAN_NODE'"
  ADHAN_ARGS+=(--set "nodeSelector.kubernetes\.io/hostname=$ADHAN_NODE")
fi
helm upgrade --install adhan helm-charts/adhan -n "$ADHAN_NS" ${ADHAN_ARGS[@]+"${ADHAN_ARGS[@]}"}

echo "==> Pi-hole ingress"
kubectl apply -f pihole-ingress.yaml

# Optional: point the Freebox Pop DHCP at Pi-hole so every device uses it.
if [ -n "${FREEBOX_DNS_IP:-}" ]; then
  echo "==> Configuring Freebox DHCP DNS -> $FREEBOX_DNS_IP"
  need python3
  python3 scripts/freebox-dns.py --dns "$FREEBOX_DNS_IP"
fi

echo
echo "Done. Status:"
kubectl get pods,svc -n "$PIHOLE_NS"
kubectl get pods,svc -n "$ADHAN_NS"
