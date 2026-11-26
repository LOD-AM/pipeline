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
Done on 2026-11-26 (owner): the next full graph had the same `canonical_sha256` as before. The steps
as they worked, with the pitfalls met on the way. Not between 02:00 and 05:00 (backup, pipeline
run). Nothing is changed in the old stack's volumes, so going back is always possible. Only one of
the two stacks can run at a time (both want port 5432).

0. **A current Compose plugin.** An old hand-copied plugin (`/root/.docker/cli-plugins/docker-compose`,
   v2.3.3) fails against Docker 29 with `client version 1.42 is too old`:
   ```bash
   sudo docker info --format '{{range .ClientInfo.Plugins}}{{.Name}} {{.Version}} {{.Path}}{{"\n"}}{{end}}'
   sudo apt install docker-compose-v2        # then move an old plugin from ~/.docker/cli-plugins aside
   ```
1. **Full dump of the old server** (roles and all databases). Kartoza's server lets `postgres` in on
   the local socket only by "peer" authentication, so run it as the container's `postgres` user, not
   as root (`-U postgres` with a password is refused):
   ```bash
   cd <old stack folder>
   docker compose exec -T -u postgres db pg_dumpall > ~/pg16.2-all.sql
   tail -1 ~/pg16.2-all.sql            # "-- PostgreSQL database cluster dump complete"
   docker compose down                 # stops the old containers; volumes stay
   ```
   An error of the dump goes to the screen, not into the file: always check the file.
2. **Start the new database:**
   ```bash
   cp -r ~/pipeline/deploy/database ~/database-stack && cd ~/database-stack
   cp .env.example .env && chmod 600 .env          # database name and user as before; see step 4
   mkdir backups
   docker compose up -d db && docker compose ps    # wait for "healthy"
   ```
3. **Load the dump.** The log has a line per statement; expected errors: the user and the database
   already exist, and `pgrouting` isn't in this image (`cau` doesn't use it). An empty log means
   nothing was loaded (go back to step 1).
   ```bash
   docker compose exec -T db psql -U postgres -d postgres < ~/pg16.2-all.sql > ~/restore.log 2>&1
   wc -l ~/restore.log; grep ERROR ~/restore.log
   ```
4. **Passwords.** The dump brings the old roles with their stored passwords, including `postgres`
   (it overrides `POSTGRES_PASSWORD` from `.env`). The old server may not have checked some of them
   at all (kartoza's rules let the Docker network in), the new one checks every login with SCRAM.
   So set them again, in psql's prompt (nothing lands in the shell history):
   ```bash
   docker compose exec db psql -U postgres -d postgres
   #   \password lodam_pipeline    the value of PGPASSWORD in ~/pipeline/.env, exactly
   #   \password postgres          a new one; the same into POSTGRES_PASSWORD in .env
   ```
   Then the pipeline's own login, exactly as `run.sh` uses it (`docker --env-file` with the `PG*` lines):
   ```bash
   grep -E '^PG[A-Z]+=' ~/pipeline/.env > ~/pg.env && chmod 600 ~/pg.env
   docker run --rm --network host --env-file ~/pg.env postgis/postgis:16-3.6 psql -c "SELECT current_user, count(*) FROM cau.site"
   rm ~/pg.env
   ```
   The role `replicator` (kartoza's default, for replication) isn't needed: `DROP ROLE replicator;`.
5. **PostGIS and checks** in the research database:
   ```bash
   docker compose exec db psql -U postgres -d <database> -c "ALTER EXTENSION postgis UPDATE" -c "SELECT version()" -c "SELECT postgis_full_version()"
   ```
   Then the grants check from the pipeline README ("On the data LXC", three times `true`).
6. **The rest:** `docker compose up -d`; the backup's login: `docker compose exec backup psql -d postgres -c "SELECT 1"`.
   In pgAdmin, add the server again with host **`db`** (not `127.0.0.1`: inside the pgAdmin container
   that is pgAdmin itself). Run `cau_help` (ingest `scripts/database/fixes/2026-11-22_28_helper_views.sql`)
   again if it is missing.
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
