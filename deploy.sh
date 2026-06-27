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
#   KEEL_ENABLED=false ./deploy.sh       # skip installing the Keel OTA auto-updater
#   ARGOCD_ENABLED=false ./deploy.sh     # bootstrap only, deploy charts with helm directly
#
# With Argo CD enabled (default), this script only bootstraps the cluster
# (namespaces, MetalLB, the Pi-hole Secret, Keel and Argo CD itself); the charts
# are then deployed from git by Argo CD — review the diff in its UI and Sync.
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

ARGOCD_ENABLED="${ARGOCD_ENABLED:-true}"

if [ "$ARGOCD_ENABLED" != "true" ]; then
  echo "==> Deploying Pi-hole + Unbound"
  helm upgrade --install pihole helm-charts/pihole -n "$PIHOLE_NS" \
    --set existingSecret="$PIHOLE_SECRET"
fi

echo "==> Keel (OTA auto-updater — polls Docker Hub, redeploys on new images)"
if [ "${KEEL_ENABLED:-true}" = "true" ]; then
  helm repo add keel https://charts.keel.sh >/dev/null 2>&1 || true
  helm repo update keel >/dev/null
  helm upgrade --install keel keel/keel \
    --namespace keel --create-namespace \
    --set helmProvider.enabled=false \
    --set image.tag=latest
else
  echo "    Skipped (KEEL_ENABLED=false)."
fi

if [ "$ARGOCD_ENABLED" = "true" ]; then
  echo "==> Argo CD (GitOps — syncs this repo to the cluster)"
  kubectl get ns argocd >/dev/null 2>&1 || kubectl create namespace argocd
  kubectl apply -n argocd -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
  # Serve the UI over plain HTTP so traefik (argocd.home) can reach it.
  kubectl -n argocd patch configmap argocd-cmd-params-cm --type merge \
    -p '{"data":{"server.insecure":"true"}}'
  kubectl -n argocd rollout restart deploy/argocd-server >/dev/null 2>&1 || true
  echo "    Registering apps (App-of-Apps)"
  kubectl apply -f argocd/root.yaml
  echo "    Charts are now managed by Argo CD — open http://argocd.home and Sync,"
  echo "    or: argocd app sync pihole adhan increaser"
  echo "    Admin password: kubectl -n argocd get secret argocd-initial-admin-secret -o jsonpath='{.data.password}' | base64 -d"
else
  echo "==> Deploying Adhan API"
  ADHAN_ARGS=()
  if [ -n "${ADHAN_NODE:-}" ]; then
    echo "    Pinning Adhan to node '$ADHAN_NODE'"
    ADHAN_ARGS+=(--set "nodeSelector.kubernetes\.io/hostname=$ADHAN_NODE")
  fi
  helm upgrade --install adhan helm-charts/adhan -n "$ADHAN_NS" ${ADHAN_ARGS[@]+"${ADHAN_ARGS[@]}"}
fi

# Local DNS records + traefik Ingress for hostname access (pi.hole, aladhan.app,
# ...) are generated from `localApps` in the pihole chart values — no extra apply
# needed. Add a new app = one entry in helm-charts/pihole/values.yaml.

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
