# Database stack (data LXC)

The research database's own Docker stack, next to the pipeline on the data LXC (planning review
2026-11-25, 5.4: the former `kartoza/postgis:16-3.4` is no longer rebuilt and stays on 16.2).
Run it from a copy, not from the pipeline checkout (its backups and `.env` live there):
`cp -r ~/pipeline/deploy/database ~/database-stack`, then `.env` from `.env.example`.

| Service | Image | Note |
|---|---|---|
| `db` | `postgis/postgis:16-3.6` | PostgreSQL 16.x, PostGIS 3.6.x (the pipeline image's line); port 5432 only on `127.0.0.1` |
| `backup` | same image | `./backups/<date>/`: `globals.sql` (roles) + `<database>.dump` (custom format), daily 02:30, 14 days |
| `pgadmin` | `dpage/pgadmin4:9` | port 80 in the LAN; server: host `db`, port 5432 |
| `watchtower` | `nickfedor/watchtower:1.24.2` | daily 12:00 (not during backup or pipeline), mails |

## Migration from the kartoza stack (16.2 → 16.x), about an hour
Not between 02:00 and 05:00 (backup, pipeline run). Nothing is changed in the old stack's volumes,
so going back is always possible.

1. **Full dump of the old server** (roles and all databases):
   ```bash
   cd <old stack folder>
   docker compose exec -T db pg_dumpall -U <user> > ~/pg16.2-all.sql   # check: ls -lh ~/pg16.2-all.sql
   docker compose down          # stops the old containers; volumes stay
   ```
2. **Start the new database:**
   ```bash
   cp -r ~/pipeline/deploy/database ~/database-stack && cd ~/database-stack
   cp .env.example .env && chmod 600 .env          # same database name, user and password as before
   mkdir backups
   docker compose up -d db && docker compose ps    # wait for "healthy"
   ```
3. **Load the dump.** Expected errors, which you can ignore: the user and the database already exist,
   and `pgrouting` isn't in this image (`cau` doesn't use it).
   ```bash
   docker compose exec -T db psql -U <user> -d postgres < ~/pg16.2-all.sql > ~/restore.log 2>&1
   grep ERROR ~/restore.log
   ```
4. **Passwords:** the old server may have stored them as MD5; the new one accepts only SCRAM.
   ```bash
   docker compose exec db psql -U <user> -d postgres -c "SELECT rolname, left(rolpassword, 6) FROM pg_authid WHERE rolpassword IS NOT NULL"
   ```
   Re-set every role that shows `md5…`, at least `lodam_pipeline` and your own user:
   ```bash
   docker compose exec db psql -U <user> -d postgres -c "ALTER ROLE lodam_pipeline PASSWORD '<same password as in ~/pipeline/.env>'"
   ```
5. **PostGIS and checks** in the research database:
   ```bash
   docker compose exec db psql -U <user> -d <database> -c "ALTER EXTENSION postgis UPDATE" -c "SELECT version(), postgis_full_version()"
   psql -h 127.0.0.1 -U lodam_pipeline -d <database> -c "SELECT count(*) FROM cau.site"   # the pipeline's login; same count as on the old server
   ```
   Then the grants check from the pipeline README ("On the data LXC", three times `true`).
6. **The rest:** `docker compose up -d`. In pgAdmin, add the server again (host `db`); run
   `cau_help` (ingest `scripts/database/fixes/2026-11-22_28_helper_views.sql`) again if it is missing.
7. **The proof:** `sudo systemctl start lodam-pipeline`. The snapshot counts as new (the server
   version is in the dump), but the full graph's `canonical_sha256` (`out/internal/manifest.json`) must
   be the same as after the last run on the old server. The release then differs only in its
   manifest, which records the server version.

**Rollback:** in `~/database-stack`, `docker compose down`; in the old folder, `docker compose up -d`.
After a week without problems, remove the old volumes (`docker volume ls`).

## Day to day
- Backups: `ls backups/`; restore one database: `pg_restore -U <user> -d <database> --clean backups/<date>/<database>.dump`.
- Copy `backups/` off the machine now and then (planning review 2026-11-25, 1.2).
- `docker compose logs --tail 50 backup` shows the last backups and any failure.
