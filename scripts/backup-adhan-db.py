#!/usr/bin/env python3
"""Sauvegarde de la base Adhan (SQLite) sur la Raspberry Pi.

Deux natures de données, donc deux cadences :

  --static   `cities` : 13,4 M de lignes, ~1,6 Go, **immuable**. Une archive
             suffit ; à refaire seulement après un `build_cities_db.py`.
  --daily    tout le reste : mosquées, comptes, revendications, contributions,
             réglages. Quelques milliers de lignes, quelques Mo compressés.
             C'est la seule partie irremplaçable — un ré-import OSM la
             reconstruit en partie, jamais les comptes ni les revendications.

    ./backup-adhan-db.py --daily
    ./backup-adhan-db.py --static
    ./backup-adhan-db.py --list

Le snapshot passe par l'API `backup()` de SQLite, pas par une copie de fichier :
la base est ouverte en écriture par l'application pendant l'opération, et copier
le fichier sous elle produirait une archive corrompue en silence.

⚠️ Ces archives vivent sur la même carte SD que la base. Elles protègent d'une
suppression ou d'une corruption, **pas de la mort de la carte**. Une copie hors
de la Pi reste nécessaire — voir `--mirror`.
"""
import argparse
import gzip
import os
import shutil
import sqlite3
import sys
import tempfile
from datetime import datetime, timezone
from pathlib import Path

DB = Path("/home/pi/data/cities.db")
ROOT = Path("/home/pi/backups")
DAILY = ROOT / "daily"
STATIC = ROOT / "static"

# Denylist et non allowlist, à l'inverse de la règle habituelle : ici l'oubli
# doit pencher vers « sauvegardé ». Une table ajoutée plus tard entre dans la
# sauvegarde quotidienne toute seule ; l'inverse la perdrait sans rien dire.
STATIC_TABLES = {"cities"}

KEEP_DAILY = 30


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__,
                                     formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument("--daily", action="store_true", help="tables mutables")
    parser.add_argument("--static", action="store_true", help="cities, une fois")
    parser.add_argument("--list", action="store_true", help="ce qui existe")
    parser.add_argument("--mirror", metavar="DEST",
                        help="rsync des archives vers une destination hors Pi")
    args = parser.parse_args()

    if args.list:
        return show()

    if not DB.exists():
        print(f"ERREUR : {DB} introuvable", file=sys.stderr)
        return 1

    if args.daily:
        backup_daily()
    if args.static:
        backup_static()
    if args.mirror:
        mirror(args.mirror)

    if not any([args.daily, args.static, args.mirror]):
        parser.print_help()
        return 1
    return 0


# --- Sauvegardes -------------------------------------------------------------

def backup_daily() -> None:
    """Les tables mutables, en SQL, compressé."""
    stamp = datetime.now(timezone.utc).strftime("%Y%m%dT%H%M%SZ")
    target = DAILY / f"adhan-{stamp}.sql.gz"
    DAILY.mkdir(parents=True, exist_ok=True)

    with snapshot() as snap:
        tables = [t for t in tables_in(snap) if t not in STATIC_TABLES]
        with gzip.open(target, "wt", encoding="utf-8") as out:
            out.write(f"-- adhan daily backup {stamp}\n")
            out.write(f"-- tables: {', '.join(tables)}\n")
            for line in dump(snap, tables):
                out.write(line + "\n")
        counts = {t: snap.execute(f"select count(*) from [{t}]").fetchone()[0]
                  for t in tables}

    size = target.stat().st_size
    print(f"{target}  ({size / 1024:.0f} Ko)")
    for table, n in sorted(counts.items()):
        print(f"    {n:>8}  {table}")

    prune()


def backup_static() -> None:
    """`cities` ne change pas : une archive, et on n'y revient plus."""
    STATIC.mkdir(parents=True, exist_ok=True)
    existing = sorted(STATIC.glob("cities-*.db.gz"))
    if existing:
        print(f"déjà présent : {existing[-1].name}")
        print("cities est immuable — supprimer l'archive pour en refaire une.")
        return

    stamp = datetime.now(timezone.utc).strftime("%Y%m%d")
    target = STATIC / f"cities-{stamp}.db.gz"

    with tempfile.NamedTemporaryFile(suffix=".db", delete=False) as tmp:
        temp_path = Path(tmp.name)
    try:
        # Un fichier SQLite ne contenant que `cities`, pour restaurer sans
        # traîner les tables mutables d'un état périmé.
        with snapshot() as snap:
            snap.execute("vacuum into ?", (str(temp_path),))
        with sqlite3.connect(temp_path) as slim:
            for table in tables_in(slim):
                if table not in STATIC_TABLES and not table.startswith("sqlite_"):
                    slim.execute(f"drop table if exists [{table}]")
            slim.commit()
            slim.execute("vacuum")

        with open(temp_path, "rb") as raw, gzip.open(target, "wb") as out:
            shutil.copyfileobj(raw, out, length=1024 * 1024)
    finally:
        temp_path.unlink(missing_ok=True)

    print(f"{target}  ({target.stat().st_size / 1024 / 1024:.0f} Mo)")


# --- Outils ------------------------------------------------------------------

def snapshot() -> sqlite3.Connection:
    """Une copie cohérente, prise pendant que l'application écrit.

    `backup()` traverse le verrou de SQLite correctement ; `cp` ne le fait pas
    et produit une archive que rien ne signale comme cassée avant la restauration.
    """
    source = sqlite3.connect(f"file:{DB}?mode=ro", uri=True)
    memory = sqlite3.connect(":memory:")
    source.backup(memory)
    source.close()
    return memory


def tables_in(connection: sqlite3.Connection) -> list[str]:
    rows = connection.execute(
        "select name from sqlite_master where type='table' "
        "and name not like 'sqlite_%' order by name"
    )
    return [name for (name,) in rows]


def dump(connection: sqlite3.Connection, tables: list[str]):
    for table in tables:
        schema = connection.execute(
            "select sql from sqlite_master where type='table' and name=?", (table,)
        ).fetchone()
        if schema and schema[0]:
            yield f"DROP TABLE IF EXISTS [{table}];"
            yield f"{schema[0]};"
        for row in connection.execute(f"select * from [{table}]"):
            values = ", ".join(literal(v) for v in row)
            yield f"INSERT INTO [{table}] VALUES ({values});"


def literal(value) -> str:
    if value is None:
        return "NULL"
    if isinstance(value, (int, float)):
        return str(value)
    if isinstance(value, bytes):
        return "X'" + value.hex() + "'"
    return "'" + str(value).replace("'", "''") + "'"


def prune() -> None:
    archives = sorted(DAILY.glob("adhan-*.sql.gz"))
    for old in archives[:-KEEP_DAILY]:
        old.unlink()
        print(f"    purgé : {old.name}")


def mirror(destination: str) -> None:
    """Copie hors Pi. Sans elle, la sauvegarde meurt avec la carte SD."""
    code = os.system(f"rsync -az --delete {ROOT}/ {destination}")
    print(f"rsync -> {destination} : {'ok' if code == 0 else f'ECHEC ({code})'}")


def show() -> int:
    for label, folder, pattern in (("statique", STATIC, "cities-*.db.gz"),
                                   ("quotidien", DAILY, "adhan-*.sql.gz")):
        print(f"--- {label} ---")
        if not folder.exists():
            print("  (aucune)")
            continue
        for archive in sorted(folder.glob(pattern)):
            size = archive.stat().st_size
            unit = f"{size / 1024 / 1024:.0f} Mo" if size > 1024 * 1024 else f"{size / 1024:.0f} Ko"
            print(f"  {archive.name:<34} {unit:>8}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
