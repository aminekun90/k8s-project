# PostgreSQL de l'API Adhan

Depuis le 2026-10, l'API tourne sur PostgreSQL et plus sur le fichier SQLite de
`/home/pi/data/cities.db`. Tout est dans le chart `aladhan`, sous
`database.enabled` (activé pour la Pi dans `clusters/pi/values/aladhan.yaml`).

| Pièce | Fichier | Rôle |
|-|-|-|
| `qibla-db` (StatefulSet + Service) | `templates/postgres.yaml` | Postgres 17, une réplique, volume `local-path` de 5 Gi |
| `adhan-api-migrate` (Job, PreSync) | `templates/migrate-job.yaml` | `alembic upgrade head`, villes GeoNames, import SQLite unique |
| `qibla-db-backup` (CronJob, 03:30) | `templates/backup-cronjob.yaml` | `pg_dump` dans `/home/pi/backups/postgres`, 14 jours |

Base `qibla`, utilisateur `qibla_app`. Le mot de passe est dans le Secret
`qibla-db` (clé `DB_PASSWORD`), créé à la main, jamais dans git :

```bash
kubectl -n adhan create secret generic qibla-db \
  --from-literal=DB_PASSWORD="$(python3 -c 'import secrets;print(secrets.token_urlsafe(32))')"
```

**Le Secret doit exister avant de déployer le chart** : sinon le Deployment ne
démarre pas, et avec la stratégie `Recreate` l'ancien pod est déjà arrêté.

## Bascule depuis SQLite

Automatique et en un seul déploiement : le premier job de migration d'une image
qui sait migrer importe `database.legacySqlitePath` dans la base vide, puis
l'ignore à chaque déploiement suivant (`--if-empty`). Le fichier SQLite reste en
place, comme archive. Une image d'avant la bascule laisse le job sans effet.

Les écritures faites par l'ancien pod entre l'import et son arrêt (quelques
secondes : un événement d'audit, un passage d'attestation) ne sont pas reprises.

## Sauvegardes hors de la Pi

Le CronJob écrit sur la carte SD, celle qui lâchera la première. Les copier
ailleurs :

```bash
scripts/pull-postgres-backups.sh            # vers ~/Backups/qibla-db
```

## Se connecter

```bash
kubectl -n adhan exec -it qibla-db-0 -- psql -U qibla_app qibla
```

## Mémoire

Postgres demande 128 Mi et plafonne à 384 Mi (`shared_buffers` 64 MB) : la Pi a
environ 1,7 Gi de libre à côté de l'API et de Pi-hole. Mesurer avec
`memory.current` du cgroup, pas le RSS.
