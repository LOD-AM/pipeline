# Scheduled run on the data LXC (planning#6)

`deploy/run.sh`, started nightly by `lodam-pipeline.timer`:

1. **Code:** fast-forward the checkout to `origin/main`. Only the owner merges there. A checkout
   with local changes or off `main` is refused, so that every release matches a commit.
2. **Image:** rebuild `lod-am-pipeline` only when `Dockerfile`, `docker/` or `mapping/pom.xml`
   changed (an image label records which inputs it was built from).
3. **`fetch snapshot changed`:** Zotero, a snapshot of the live database (read-only role, the `PG*`
   lines of `.env`, and nothing else from `.env`), then the decision: has anything changed since the
   live release? It compares the snapshot, the pipeline commit, the knowledge-graph commit and the
   Zotero version.
4. **`release`**, only if something changed: with `RELEASE_STRICT=1` and `--network none`, so the
   conversion provably runs offline.
5. **Hand over:** copy `out/release/` to `LODAM_PUBLISH_DIR` (optional; world-readable, released data
   only, because `out/` itself is owner-only), then a `POST` to `LODAM_RELEASE_WEBHOOK` (optional), so
   that the triplestore fetches the release from there (planning#7). The signal carries only
   `{"manifest_sha256": …}`, never data. An unchanged run still hands over the live release if
   `LODAM_PUBLISH_DIR` is behind (e.g. just configured).

A failing step ends the run with an error (`systemctl --failed` shows it). `out/release/` is only
ever replaced by a fully checked release. If nothing changed, the run ends after the snapshot
(about a minute).

## Install
Prerequisites: the first run by hand has worked (README "On the data LXC"), and the data LXC
has at least **3 GB RAM + 1 GB swap** (README "Memory").
```bash
cd ~/pipeline && git pull
sudo deploy/install.sh                       # writes and enables lodam-pipeline.service + .timer
sudo systemctl start --no-block lodam-pipeline   # optional: run once now (about 40 minutes)
sudo journalctl -u lodam-pipeline -f         # follow the log (or join the systemd-journal group)
```
`install.sh` writes the units with this checkout's path and changes nothing else. Run it again
after a change in `deploy/`. Undo: `sudo deploy/install.sh --remove`.

## Operate
| | |
|---|---|
| Next run | `systemctl list-timers lodam-pipeline.timer` |
| Run now | `sudo systemctl start --no-block lodam-pipeline` (`start` without `--no-block` waits until the run is done) |
| Release although nothing changed | `sudo deploy/run.sh --force` |
| Log of the last run | `sudo journalctl -u lodam-pipeline -e` (lines start with `pipeline-run:`, peak memory per step with `resources:`) |
| Did the last run fail? | `systemctl status lodam-pipeline` |
| Stop a run | `sudo systemctl stop lodam-pipeline` (`restart` also stops the running one; the live release stays) |
| Time | `OnCalendar` in `lodam-pipeline.timer` (default 03:17 ± 15 min); then `sudo deploy/install.sh` again |

**Memory:** every release records the peak memory and duration of each step in
`out/internal/manifest.json` (`resources`), and the run's log shows the peak. When `peak_rss_mb`
approaches the LXC's RAM, give it more (README "Memory").

**Hand-over to the triplestore (planning#7):** set `LODAM_PUBLISH_DIR=/srv/lodam/release`,
`LODAM_RELEASE_WEBHOOK=http://<triplestore LXC>:9300/lodam-release` and
`LODAM_RELEASE_WEBHOOK_TOKEN=` (printed by the triplestore's `deploy/install.sh`) in `.env`; the
whole setup, including the read-only `lodam-release` account, is in the triplestore README
("Releases"). Without them, releases are still built, just not handed over.
