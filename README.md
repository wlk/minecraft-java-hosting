# minecraft-java-hosting

All Minecraft Java servers on one Docker host, managed as one Docker Compose
project ([`compose.yaml`](compose.yaml)) using the
[`itzg/minecraft-server`](https://github.com/itzg/docker-minecraft-server) image.

## Servers

Listed in start order (see [Staggered start](#staggered-start)).

| Service                 | Host port | Type                      | Mode     |
| ----------------------- | --------- | ------------------------- | -------- |
| `minecraft-przetrwanie` | 25565     | Vanilla                   | survival |
| `minecraft-kreatywny`   | 25566     | Vanilla                   | survival |
| `redstone`              | 25570     | Vanilla                   | creative |
| `pvp`                   | 25581     | Vanilla, PvP on           | survival |
| `coblemon-przetrwanie`  | 25567     | Fabric 1.21.1 + Cobblemon | survival |
| `coblemon-kreatywny`    | 25568     | Fabric 1.21.1 + Cobblemon | creative |

## Layout on the host

```
~/minecraft-java-hosting/      # compose.yaml, scripts/, systemd/ (synced by scripts/deploy.sh)
~/minecraft-data/<service>/    # each server's /data volume (worlds, configs, mods)
```

The data root can be overridden with `DATA_ROOT` (e.g. in a `.env` file next to `compose.yaml`
on the host; deploys leave it alone).

## Deploying changes (from your machine)

Local settings live in `.env`, which is gitignored and loaded by [direnv](https://direnv.net/)
through `.envrc`. Set it up once:

```sh
cp .env.example .env   # set DEPLOY_HOST=user@host
direnv allow
```

```sh
scripts/deploy.sh --dry-run    # validate, show compose.yaml diff, change nothing
scripts/deploy.sh              # sync compose.yaml, scripts/, systemd/; servers untouched
scripts/deploy.sh --apply      # sync, then `docker compose up -d` (recreates changed servers)
scripts/deploy.sh --upgrade    # sync, then upgrade all servers (below)
```

The target is `DEPLOY_HOST` (required) and `DEPLOY_DIR` (default `minecraft-java-hosting` in the
remote user's home). The host has no GitHub access, so this is how files get there.

## Upgrading servers

`scripts/upgrade.sh` (on the host) or `scripts/deploy.sh --upgrade` (from your machine):

1. refuses if any player is online (override with `--force`)
2. `docker compose stop`
3. `docker compose pull`; if this fails the servers still come back on their old images
4. `docker compose up -d --wait`, which starts servers one by one and waits until they are healthy

Vanilla servers have no pinned `VERSION`, so they also pick up the newest Minecraft release on start.
The Cobblemon servers stay on `1.21.1`.

## Staggered start

Starting six JVMs at once overloads the host, so servers start one at a time:

- **`docker compose up -d`**: each service `depends_on` the previous one with
  `condition: service_healthy`, so it starts only after the previous server is up. `required: false`
  means a server that crashes or never becomes healthy only delays the chain (by up to ~6 min).
  Health is probed every 5s during startup, so a healthy server unblocks the next one quickly.
- **Host boot**: the Docker daemon would restart all `unless-stopped` containers at once. The
  [`systemd/minecraft@.service`](systemd/minecraft@.service) template unit stops the stack on shutdown
  (so Docker does not auto-start it) and runs `docker compose up -d` at boot. The instance name is the
  user that owns `~/minecraft-java-hosting`. Install once on the host, as that user:

  ```sh
  sudo cp ~/minecraft-java-hosting/systemd/minecraft@.service /etc/systemd/system/
  sudo systemctl daemon-reload && sudo systemctl enable "minecraft@$USER.service"
  ```

  After a power loss (no clean shutdown) Docker may still start them all together.

Because of the chain, `docker compose up -d pvp` also starts every server before `pvp`.
Use `--no-deps` to start one server only.

## Day-to-day

Run from `~/minecraft-java-hosting` on the host:

```sh
docker compose ps                         # status + health
docker compose logs -f redstone           # follow logs
docker compose exec pvp rcon-cli          # server console
docker compose exec pvp rcon-cli list     # who is online
docker compose restart pvp                # restart one server
docker compose stop pvp                   # stop one server (world is saved)
docker compose up -d --no-deps pvp        # start one server
docker compose down                       # stop and remove all containers (data is kept)
```

Servers restart automatically after a crash (`restart: unless-stopped`).

## Tuning

Shared settings live in the `x-server` and `x-env` anchors in `compose.yaml`:

- **Memory**: heaps start small and grow (`INIT_MEMORY`/`MAX_MEMORY`: vanilla 1G→2G, Cobblemon 2G→5G)
  instead of reserving the max up front. All servers use Aikar's JVM flags, but with
  `-XX:-AlwaysPreTouch` so the whole heap is not pinned in RAM at boot, and
  `-XX:G1PeriodicGCInterval=300000` so idle servers hand unused heap back to the OS. If a Cobblemon
  server logs `OutOfMemoryError`, raise its `MAX_MEMORY`.
- **Shutdown**: 90 s (vanilla) / 2 min (Cobblemon) to save before Docker kills the container; the image
  itself waits up to 60 s for the save.
- **Logs**: Docker logs rotate at 10 MB × 3 files per server.

## Adding a server

1. Add a service to `compose.yaml` (copy an existing one; `<<: *server` pulls in shared settings).
2. Pick an unused host port, mount `${DATA_ROOT:-~/minecraft-data}/<service>:/data`, and add it to
   the end of the start chain (`depends_on: {<last-service>: *after}`).
3. `scripts/check-compose.sh` catches duplicate ports / data dirs; then `scripts/deploy.sh --apply`.

## Migrating from the old per-directory layout

Before this repo every server had its own `~/<server>/docker-compose.yml` and `~/<server>/data`.
[`scripts/migrate-data.sh`](scripts/migrate-data.sh) stops each old stack, moves its data to
`~/minecraft-data/<server>` and parks the old compose dir in `~/minecraft-legacy/`:

```sh
cd ~/minecraft-java-hosting
scripts/migrate-data.sh --dry-run   # print what would happen
scripts/migrate-data.sh             # do it
docker compose up -d && docker compose ps
```

## CI and tests

`.github/workflows/ci.yml` runs on every PR and push to `main`:

- `yamllint --strict` (config in `.yamllint.yaml`)
- `actionlint` for workflow files
- `shellcheck` for `scripts/*.sh` and the test stubs
- `scripts/check-compose.sh`: `docker compose config` plus duplicate host port / data dir checks
- [bats](https://github.com/bats-core/bats-core) tests in `tests/` for `deploy.sh` and `upgrade.sh`.
  `ssh` and `docker` are stubbed; rsync runs for real against a temp dir. Run locally with
  `npx bats@1.11.0 tests`.
