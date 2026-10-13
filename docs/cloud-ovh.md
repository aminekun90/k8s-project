# Le nœud public sur OVH

Préparé le 2026-10-13, **rien n'est commandé**. Le VPS portera le backend public :
l'API de l'app iOS, l'annuaire, le portail et la trésorerie. La Pi garde le lecteur
Sonos, qui ne peut pas quitter le réseau de la maison.

| | Pi (`clusters/pi`) | OVH (`clusters/cloud`) |
|-|-|-|
| Rôle | lecteur Sonos, Pi-hole | backend public |
| Lecteur | `player.enabled: true`, hostNetwork | coupé : les routes des appareils n'ont pas d'authentification |
| HTTPS | DuckDNS, défi DNS-01, nom résolu sur le LAN seulement | Let's Encrypt, défi TLS-ALPN-01 sur :443 |
| Postgres | 5 Gi, réglé pour une carte SD | 20 Gi, réglé pour 4 Go et du NVMe |
| Sauvegardes | dumps sur la carte, à tirer à la main | dumps sur le disque, emportés par la sauvegarde quotidienne d'OVH |

## Ce qu'il faut avant de commencer

- Un **VPS-1** OVHcloud sous Debian 13 ou Ubuntu 24.04, commandé avec la clé SSH du Mac
- Un **nom de domaine**, et un enregistrement `A` (et `AAAA` si le VPS a de l'IPv6) qui pointe vers le VPS. Le certificat ne s'émet qu'une fois le nom résolu
- Le pare-feu d'OVH (« Network Firewall ») limité à 22, 80 et 443

## 1. Le serveur

```bash
ssh debian@<ip>     # ubuntu@ sous Ubuntu
sudo apt update && sudo apt full-upgrade -y
sudo apt install -y unattended-upgrades ufw
sudo dpkg-reconfigure -plow unattended-upgrades

sudo ufw default deny incoming
sudo ufw allow 22/tcp && sudo ufw allow 80/tcp && sudo ufw allow 443/tcp
sudo ufw enable

# SSH par clé seulement
sudo sed -i 's/^#\?PasswordAuthentication .*/PasswordAuthentication no/' /etc/ssh/sshd_config
sudo systemctl reload ssh

# Les dossiers que le chart monte, à l'uid du job de sauvegarde (1000)
sudo mkdir -p /var/lib/qibla/data /var/lib/qibla/backups/postgres
sudo chown -R 1000:1000 /var/lib/qibla && sudo chmod 700 /var/lib/qibla/backups/postgres
```

L'API Kubernetes (6443) n'est **pas** ouverte : on la joint par un tunnel SSH
(`ssh -L 6443:127.0.0.1:6443 debian@<ip>`), jamais depuis internet.

## 2. k3s et traefik

```bash
curl -sfL https://get.k3s.io | sh -s - --write-kubeconfig-mode 600
sudo k3s kubectl apply -f clusters/cloud/traefik-helmchartconfig.yaml   # depuis une copie du dépôt
```

Même version de k3s que la Pi (1.34) : le traefik livré est le même, et
`traefik-helmchartconfig.yaml` en dépend.

## 3. Les Secrets — jamais dans git

```bash
kubectl create namespace adhan

# Mot de passe de la base, généré sur le serveur et jamais affiché
kubectl -n adhan create secret generic qibla-db \
  --from-literal=DB_PASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
```

Les clés de session et de TOTP sont **copiées depuis la Pi, jamais régénérées** :
une nouvelle clé TOTP perdrait toutes les 2FA, une nouvelle clé de session
déconnecterait tout le monde. Copie de Secret à Secret, sans passer par le terminal :

```bash
ssh pi@192.168.1.42 'sudo k3s kubectl -n adhan get secret adhan-api-env -o json' \
  | jq 'del(.metadata.uid, .metadata.resourceVersion, .metadata.creationTimestamp, .metadata.managedFields, .metadata.annotations)' \
  | ssh debian@<ip> 'sudo k3s kubectl apply -f -'
```

## 4. Argo CD

```bash
kubectl create namespace argocd
kubectl apply -n argocd --server-side -f https://raw.githubusercontent.com/argoproj/argo-cd/stable/manifests/install.yaml
```

Avant d'appliquer `root.yaml`, renseigner `ingress.host` dans
`clusters/cloud/values/aladhan.yaml` et merger : sans nom, le rendu s'arrête exprès.

```bash
kubectl apply -f clusters/cloud/argocd/root.yaml
```

L'app `adhan` démarre vide : le job de migration crée le schéma et charge les villes.

## 5. La bascule des données

Pendant la bascule, l'API de la Pi ne doit plus écrire : sinon, ce qui est écrit
entre le dump et la restauration est perdu.

```bash
# 1. La Pi en lecture seule : l'API arrêtée, Postgres reste
ssh pi@192.168.1.42 'sudo k3s kubectl -n adhan scale deploy adhan-api --replicas=0'

# 2. Dump de la Pi, restauré sur le VPS (l'API du VPS arrêtée pendant ce temps)
kubectl -n adhan scale deploy adhan-api --replicas=0
ssh pi@192.168.1.42 'sudo k3s kubectl -n adhan exec qibla-db-0 -- pg_dump -Fc -U qibla_app qibla' > qibla.dump
kubectl -n adhan exec -i qibla-db-0 -- pg_restore --clean --if-exists --no-owner -U qibla_app -d qibla < qibla.dump
kubectl -n adhan scale deploy adhan-api --replicas=1
```

Le dump contient des données personnelles : le supprimer du Mac une fois la
restauration vérifiée.

3. Vérifier `https://<domaine>/api/v1/health`, une connexion au portail avec la 2FA,
   et les horaires publiés d'une mosquée
4. Pointer l'app iOS sur le nouvel hôte (Gist de découverte signé) et ajouter
   `clusters/cloud/values/aladhan.yaml` à l'étape d'écriture de `publish.yml`
5. Remettre l'API de la Pi en marche **pour le lecteur seulement** : elle ne sert plus
   le public

## Ce qui reste ouvert

- **La Pi après la bascule** : elle garde-t-elle une copie de l'annuaire pour le
  lecteur, ou interroge-t-elle l'API publique ? À trancher avant l'étape 5
- **Une copie des dumps hors d'OVH** : la sauvegarde du VPS reste chez OVH.
  `scripts/pull-postgres-backups.sh` sait tirer des dumps vers le Mac ; il vise la Pi
  aujourd'hui
