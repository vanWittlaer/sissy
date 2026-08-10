# Simple Shopware on Docker — single-host, prod + stage

A barebones alternative to the Coolify topology: one VPS, `docker compose`,
**no Redis / RabbitMQ / OpenSearch / S3**. MariaDB is the message queue
(Doctrine transport) and the Symfony lock store; cache and sessions are on the
local filesystem. Traefik terminates TLS for both a production and a stage
site on the same box.

```
edge/      shared Traefik (owns :80/:443, ACME)
prod/      web + worker×2 + scheduler + ops-shell + mariadb
stage/     web + worker + scheduler + mariadb   (basic-auth gated)
```

Uses the same container image you already build (`ghcr.io/vanwittlaer/sissy:<tag>`).

## Persistent data (`<stack>/data/`)

Bind-mounted into **web and worker alike** (`x-app-volumes` in `compose.yaml`).
Sharing is not only about surviving a restart: the worker writes thumbnails and
sitemaps that *web* has to serve, so an unshared path means "generated, never
visible".

| `data/`     | mounted at             | written by       | lost = |
|-------------|------------------------|------------------|--------|
| `media`     | `public/media`         | web, worker      | **data loss** |
| `files`     | `files` (private fs)   | web, worker      | **data loss** — invoice PDFs, import/export, theme-config |
| `thumbnail` | `public/thumbnail`     | worker           | regenerable |
| `theme`     | `public/theme`         | `theme:compile`  | regenerable |
| `sitemap`   | `public/sitemap`       | worker (task)    | regenerable |
| `log`       | `var/log`              | all              | logs |
| `mysql`     | mariadb datadir        | mariadb          | **data loss** |

Deliberately *not* mounted: `public/bundles` (baked at build by `assets:install`
— a bind mount would hide the image's copy, since bind mounts don't seed from
the image) and `var/cache` (per-container by design).

## What you trade away vs. Coolify

- **No horizontal web scaling.** Filesystem cache + native sessions are
  per-container. **Keep `web` at 1 replica** (workers scale fine). Add Redis the
  day you need a second web node.
- No RabbitMQ throughput/observability, no ES search, no zero-downtime deploys —
  a `setup` container migrates before the app containers start, so the ordering
  is safe, but `web` still restarts.
- You keep: the same image, a DB-backed queue that works, real workers, TLS,
  and a deploy you can read top to bottom.

## Requirements

- **Ubuntu 24.04 LTS** host, **≥ 8 GB RAM** (two MariaDBs + ~10 containers).
- DNS A-records for the prod and stage hostnames → this host.
- The image published where the host can pull it. GHCR packages inherit the
  repo's visibility and start **private**, so either flip the package to public
  (Packages → sissy → Package settings → Change visibility) or, as `deploy` on
  the host, `echo <PAT> | docker login ghcr.io -u <user> --password-stdin` with
  a `read:packages` token. Otherwise `deploy.sh` fails on pull with
  `error from registry: unauthorized`. Applies to `shopware-ops-shell` too.
- **A network-level firewall in front of the host** (see below) — not optional.

## Firewall: network level, not host level

There is deliberately **no ufw on the host**. A host firewall filters the
`INPUT` chain, but Docker DNATs published ports in `nat/PREROUTING` and routes
them through `FORWARD` — so every `ports:` mapping stays reachable no matter
what ufw says. A host firewall here protects sshd and nothing else, while
looking like it protects everything. That is worse than none.

Put the filtering where it actually sees the traffic — for Hetzner, a Cloud
Firewall attached to the server (inbound; everything else denied):

| Port       | Source              |
|------------|---------------------|
| 22, 80, 443| `0.0.0.0/0`, `::/0` |

SSH is open to the world by choice — a dynamic admin IP makes a `/32` rule a
lockout waiting to happen. What carries the weight instead: key-only auth, no
root login (both set by `cloud-init.yaml`), and `fail2ban`. Narrow port 22 to
a source range the day you have a static IP or a VPN to come from.

Codify it rather than clicking, so it stays part of the recovery record.
`hcloud` is Hetzner's CLI; `context create` prompts for a read/write API token
from Cloud Console → Security → API Tokens (illustrative — check the syntax for
your version):

```bash
hcloud context create sissy          # once, per project
hcloud firewall create --name sissy
hcloud firewall add-rule sissy --direction in --protocol tcp --port 80  --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule sissy --direction in --protocol tcp --port 443 --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall add-rule sissy --direction in --protocol tcp --port 22  --source-ips 0.0.0.0/0 --source-ips ::/0
hcloud firewall apply-to-resource sissy --type server --server <server-name>
```

Second line of defence, on the host: **publish nothing you don't want public.**
Both MariaDBs sit on the `internal` network with no `ports:` at all, which is
what actually keeps them off the internet. `fail2ban` still runs for SSH
brute-force, and works fine without ufw.

## www and non-www (prod)

`DOMAIN` is canonical and what Shopware serves; `DOMAIN_REDIRECT` gets its own
certificate and 301s to it, path and query preserved. Swap the two values to
make the bare domain canonical instead.

Both need A-records, since Let's Encrypt validates each host separately. The
`$$` in the redirect replacement is deliberate — compose eats a single `$`, and
Traefik must receive `${1}`.

Shopware has to agree, or it will redirect back: `APP_URL=https://www.…` in
`.env.local`, and `sales_channel_domain.url` set to the same. Stage keeps a
single host; copy the two `prod-redirect` labels over if it ever needs both.

## Two env files per stack (the #1 compose gotcha)

Neither is mounted. Both are read by the `docker compose` CLI **on the host**,
and that is where the similarity ends:

- `.env` — **interpolated into `compose.yaml`** before anything runs (`TAG`,
  `DOMAIN`, DB passwords, `BASIC_AUTH`). Pure templating; containers never see
  these names.
- `.env.local` — named by `env_file:`, so its lines become **environment
  variables inside the app containers**. Values are **literal**; `${...}` is NOT
  expanded, so `DATABASE_URL`/`LOCK_DSN` spell the password out.

Because `env_file` is baked in at container creation, editing `.env.local` needs
`docker compose up -d` (which recreates) — a `restart` keeps the old values.

On the host, one pair per stack — never a single `.env` at the top, nothing
reads that:

```
/opt/sissy/
├── edge/.env           ACME_EMAIL                    (no .env.local: not a Shopware app)
├── prod/.env           TAG, DOMAIN, DB_PASSWORD, DB_ROOT_PASSWORD
├── prod/.env.local     APP_SECRET, INSTANCE_ID, DATABASE_URL, LOCK_DSN, MAILER_DSN
├── stage/.env          ... the same, plus BASIC_AUTH
└── stage/.env.local
```

Both must be siblings of their `compose.yaml`: `env_file: .env.local` resolves
relative to the compose file, and `.env` is read from Compose's *project
directory*, which defaults to that file's directory — which is why the scripts
can `cd /opt/sissy` and still run `-f prod/compose.yaml` against `prod/.env`.

Copy every `*.example` to its real name and fill in before bootstrapping. These
are gitignored, so they never arrive with the folder — create or `scp` them onto
the host, then `chown deploy:deploy` and `chmod 600` (they hold your DB
passwords and `APP_SECRET`). `bootstrap.sh` aborts if either is missing.

## First-time setup

1. **Provision the host** with `cloud-init.yaml` (installs Docker + compose,
   creates the `deploy` user, `edge` network, fail2ban). Or run those steps by
   hand. **Attach the Cloud Firewall** (above) — the host has none.

   SSH: the keys Hetzner injects for `root` are copied to `deploy`, then
   password auth and root login are disabled — but **only if that copy
   succeeded**, so a provider that injects nothing leaves you a way back in.
   Watch for `ssh: imported N key(s)` in `/var/log/cloud-init-output.log`; if
   you see the `WARNING` instead, fix access before rebooting. From then on
   it's `ssh deploy@host`, and the provider's web console is the way back if
   you lose the key.
2. **Copy this folder** to `/opt/sissy` on the host.
3. **Fill in secrets:** for `edge`, `prod`, `stage`, copy the `*.example`
   files and edit. For stage's `BASIC_AUTH`: `htpasswd -nb user pass`, then
   **double every `$` to `$$`**.
4. **Point DNS** at the host.
5. **Bootstrap:**
   ```bash
   ./bootstrap.sh            # edge + prod + stage; installs Shopware on empty DBs
   ```
   The `setup` container installs Shopware on an empty database and migrates an
   existing one, before web/worker/scheduler start. Traefik issues certs on
   first HTTPS hit.

Effort: ~½–1 day to adapt cloud-init + scripts to your registry/domains once.
Afterwards a new server is: DNS + secrets + `./bootstrap.sh`. DNS and secrets
are the only irreducibly manual bits.

## Updating Shopware (new image)

```bash
./deploy.sh prod 1a2b3c4      # pull tag, recreate services, migrate + theme-compile in live web
./deploy.sh stage latest
```

Wire your CI to `ssh deploy@host '/opt/sissy/deploy.sh prod <sha>'` after
it pushes the image. The theme is compiled *inside the live web container*
because there's no S3 to hold it; migrations apply just after new code goes
live (a brief new-code-vs-old-schema window — the price of single-node simple).

## Import a dump (e.g. from DDEV)

```bash
ddev export-db --file=/tmp/sissy-db.sql.gz     # locally
scp /tmp/sissy-db.sql.gz deploy@host:/tmp/
./import-db.sh stage /tmp/sissy-db.sql.gz      # on the host
```

Drops and recreates the target database, imports, runs the deployment helper
(migrations + theme), then repoints every `sales_channel_domain` containing
`ddev.site` at the stack's own `DOMAIN` — without that the storefront keeps
redirecting to the machine the dump came from. Pass a third argument to rewrite
a different source host. Refuses `prod` unless `FORCE=1`. Media is not in a
dump; the script prints the rsync + `media:generate-thumbnails` follow-up.

## Refresh stage from prod

```bash
./refresh-stage.sh          # prod DB -> stage DB (via host), then deployment helper
```

Only the DB is copied. For stage to match prod's media and documents:
`rsync -a prod/data/media/ stage/data/media/` and likewise `data/files/`.
`theme`, `thumbnail` and `sitemap` regenerate themselves.

## Operational notes

- **The bind-mount dirs must be owned by UID 82** or the app fails with
  Permission denied (logging first). `bootstrap.sh:prep_dirs` creates and chowns
  them before Docker can make them root-owned — extend that list if you add a
  mount.
- **Risk W:** confirm a `worker` container actually runs `messenger:consume` and
  doesn't boot nginx (the shopware docker-base entrypoint decides by args).
  Mirror the `start_command` your Coolify `apps.tf` uses.
- **Workers must consume `async` AND `low_priority`** — separate Doctrine queues;
  dropping `low_priority` silently strands those messages.
- **ops-shell** (prod only) is bash + shopware-cli + rclone with **no app code**
  — it can't run `bin/console`. Its `command` is a `sleep infinity` placeholder;
  check the `shopware-ops-shell` repo for its real backup/entrypoint contract.
- **Recovery record** is this directory + git. Lost host → re-run cloud-init +
  `bootstrap.sh`. The one piece of provider state is the Cloud Firewall — keep
  it as `hcloud` commands here and it stays reproducible, no `tofu import`.
