#!/usr/bin/env python3
"""Build the public CI fixture for one released publication from a full dump (local use only).

Public CI has no data (planning#26), so it could never run a whole release. A fixture holds only
what is already public: the rows of one released publication and the rows they point to.

  scripts/make_fixture.py <dump.sql> <citation key> <out dir>

  1. load the dump into a throwaway PostgreSQL 16 + PostGIS cluster ($WORKDIR/lodam-fixture-pg)
  2. keep: the publication's row in cau.literature, its finds, analyses and analysed elements,
     then, until nothing changes, every row a kept row points to by a foreign key
     (find → feature → site → region, period → culture, type → type_group, …), the links in INWARD
     backwards (culture → all its phases), and the code lists in WHOLE_TABLES
  3. delete every other row in schema cau and dump the rest → <out dir>/dump.sql
     (pg_dump -n cau --no-owner --column-inserts, as the owner's dumps)
  4. the Zotero items of the kept literature rows from .cache/zotero (`make fetch-zotero`)
     → <out dir>/zotero.json + zotero.version

Whether the fixture holds anything beyond the released publication is not decided here but
checked by scripts/test_fixture.sh: the full graph built from the fixture must not contain a
triple that is not in the publication's released file. Run it before committing a new fixture.
Never commit the input dump or anything else from it.
"""
import json
import os
import shutil
import subprocess
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parents[1]
BIN = Path(os.environ.get("PG_BIN", "/usr/lib/postgresql/16/bin"))
PORT = os.environ.get("LODAM_FIXTURE_PG_PORT", "5496")
DB = "lodam_fixture"
ZOTERO = ROOT / ".cache" / "zotero" / "group-6765723.json"
# Seeds: tables whose rows belong to a publication through literature_id
SEED_TABLES = ["find", "chemical_analysis", "lead_isotope_analysis", "analysed_element"]
# Foreign keys also followed backwards (parent kept → keep its children), because the RDF links the
# parent to them: a culture consists of all its phases (crm:P9_consists_of), not only the dated ones
INWARD = {("period", "culture")}
# Code lists no foreign key points to, which the views read whole (lead isotope ratio columns)
WHOLE_TABLES = ["isotope_ratio"]


def main(dump, key, out):
    work = Path(os.environ.get("WORKDIR", "/tmp")).resolve() / "lodam-fixture-pg"
    as_pg = ["su", "postgres", "-s", "/bin/sh", "-c"] if os.getuid() == 0 else ["sh", "-c"]
    run = lambda cmd: subprocess.run(as_pg + [cmd], check=True, stdout=subprocess.DEVNULL)  # noqa: E731
    psql = ["psql", "-h", str(work), "-p", PORT, "-U", "postgres", "-v", "ON_ERROR_STOP=1", "-q", "-At"]

    def sql(q, db=DB):
        return subprocess.run(psql + ["-d", db, "-c", q], check=True, capture_output=True,
                              text=True).stdout.strip()

    if work.exists():
        shutil.rmtree(work)
    work.mkdir(parents=True)
    if os.getuid() == 0:
        shutil.chown(work, "postgres")
    run(f"{BIN}/initdb -D '{work}/data' -A trust -U postgres")
    run(f"{BIN}/pg_ctl -D '{work}/data' -o \"-k '{work}' -p {PORT} -c listen_addresses=''\" "
        f"-l '{work}/log' -w start")
    try:
        sql(f"CREATE DATABASE {DB}", db="postgres")
        sql("CREATE EXTENSION postgis")
        subprocess.run(psql + ["-d", DB, "-f", str(dump)], check=True, stdout=subprocess.DEVNULL)

        lit = sql(f"SELECT literature_id FROM cau.literature WHERE zotero_key = '{key}' "
                  "AND released_on IS NOT NULL AND released_on <= current_date")
        if not lit:
            sys.exit(f"FAIL: {key} is not a released publication in this dump")
        tables = sql("SELECT table_name FROM information_schema.columns WHERE table_schema = 'cau' "
                     "AND column_name = 'id_uuid' ORDER BY 1").split()
        all_tables = sql("SELECT tablename FROM pg_tables WHERE schemaname = 'cau' ORDER BY 1").split()
        if set(all_tables) - set(tables):
            sys.exit(f"FAIL: tables without id_uuid: {sorted(set(all_tables) - set(tables))}")

        sql("CREATE TABLE public.keep (tbl text, id uuid, PRIMARY KEY (tbl, id))")
        sql(f"INSERT INTO public.keep SELECT 'literature', id_uuid FROM cau.literature WHERE literature_id = {lit}")
        for t in SEED_TABLES:
            sql(f"INSERT INTO public.keep SELECT '{t}', id_uuid FROM cau.{t} WHERE literature_id = {lit}")
        for t in WHOLE_TABLES:
            sql(f"INSERT INTO public.keep SELECT '{t}', id_uuid FROM cau.{t}")

        # Foreign keys as (child, child columns, parent, parent columns), composite keys included
        fks = []
        for row in sql("""SELECT c.conrelid::regclass, c.confrelid::regclass,
                 (SELECT string_agg(a.attname, ',' ORDER BY k.i) FROM unnest(c.conkey) WITH ORDINALITY k(n, i)
                    JOIN pg_attribute a ON a.attrelid = c.conrelid AND a.attnum = k.n),
                 (SELECT string_agg(a.attname, ',' ORDER BY k.i) FROM unnest(c.confkey) WITH ORDINALITY k(n, i)
                    JOIN pg_attribute a ON a.attrelid = c.confrelid AND a.attnum = k.n)
               FROM pg_constraint c WHERE c.contype = 'f' AND c.connamespace = 'cau'::regnamespace""").splitlines():
            child, parent, ccols, pcols = row.split("|")
            fks.append((child.removeprefix("cau."), ccols.split(","), parent.removeprefix("cau."), pcols.split(",")))
        while True:
            added = 0
            for child, ccols, parent, pcols in fks:
                on = " AND ".join(f"p.{p} = c.{q}" for p, q in zip(pcols, ccols))
                n = sql(f"""WITH ins AS (INSERT INTO public.keep
                      SELECT DISTINCT '{parent}', p.id_uuid FROM cau.{parent} p JOIN cau.{child} c ON {on}
                      WHERE c.id_uuid IN (SELECT id FROM public.keep WHERE tbl = '{child}')
                      ON CONFLICT DO NOTHING RETURNING 1) SELECT count(*) FROM ins""")
                added += int(n.splitlines()[-1])
                if (child, parent) in INWARD:
                    n = sql(f"""WITH ins AS (INSERT INTO public.keep
                          SELECT DISTINCT '{child}', c.id_uuid FROM cau.{child} c JOIN cau.{parent} p ON {on}
                          WHERE p.id_uuid IN (SELECT id FROM public.keep WHERE tbl = '{parent}')
                          ON CONFLICT DO NOTHING RETURNING 1) SELECT count(*) FROM ins""")
                    added += int(n.splitlines()[-1])
            if not added:
                break

        # Delete the rest; triggers off (replica) so the order of deletes does not matter
        stmts = ["SET session_replication_role = replica"] + [
            f"DELETE FROM cau.{t} WHERE id_uuid NOT IN (SELECT id FROM public.keep WHERE tbl = '{t}')"
            for t in tables] + ["DROP TABLE public.keep"]
        subprocess.run(psql + ["-d", DB], input=";\n".join(stmts) + ";\n", text=True, check=True,
                       stdout=subprocess.DEVNULL)
        counts = {t: int(sql(f"SELECT count(*) FROM cau.{t}")) for t in tables}
        cited = set(sql("SELECT zotero_key FROM cau.literature").split())

        out.mkdir(parents=True, exist_ok=True)
        dumped = subprocess.run([str(BIN / "pg_dump"), "-h", str(work), "-p", PORT, "-U", "postgres",
                                 "-n", "cau", "--no-owner", "--column-inserts", DB],
                                check=True, capture_output=True, text=True).stdout
        lines = [l for l in dumped.splitlines() if not l.startswith(("\\restrict", "\\unrestrict"))]
        (out / "dump.sql").write_text("\n".join(lines) + "\n", encoding="utf-8")
    finally:
        run(f"{BIN}/pg_ctl -D '{work}/data' -m fast stop")
        shutil.rmtree(work, ignore_errors=True)

    # The Zotero items the fixture's literature rows cite (the group is public), matched as in
    # scripts/literature.py: by data.citationKey
    items = json.loads(ZOTERO.read_text(encoding="utf-8"))
    picked = [i for i in items if i["data"]["itemType"] not in ("attachment", "note")
              and i["data"].get("citationKey") in cited]
    missing = cited - {i["data"]["citationKey"] for i in picked}
    if missing:
        sys.exit(f"FAIL: citation keys not in {ZOTERO.relative_to(ROOT)}: {sorted(missing)}")
    (out / "zotero.json").write_text(json.dumps(picked, ensure_ascii=False, sort_keys=True, indent=0) + "\n",
                                     encoding="utf-8")
    shutil.copy(ZOTERO.with_suffix(".version"), out / "zotero.version")
    print(f"fixture {key}: {out}/dump.sql ({', '.join(f'{t} {n}' for t, n in counts.items() if n)}), "
          f"zotero.json ({len(picked)} item(s))")


if __name__ == "__main__":
    if len(sys.argv) != 4:
        sys.exit(__doc__)
    main(Path(sys.argv[1]).resolve(), sys.argv[2], Path(sys.argv[3]).resolve())
