# Onboarding — putting a shop on sissy

The path from "I have a Shopware project" to "it serves production on my own
box", in order. [`README.md`](README.md) is the reference — it explains *why*
each piece is shaped the way it is, and you will want it open when something
surprises you. This file is the *how*, once.

Two journeys share almost every step:

- **Greenfield** — no shop yet. sissy installs Shopware on an empty database.
- **Existing shop** — a running installation you are moving here. Same setup,
  then [§8](#8-existing-shop-bring-your-data-across) replaces the fresh install
  with your data, and [§10](#10-cutover) is the go-live.

Budget half a day to a day the first time, most of it waiting on DNS and
reading. A second server afterwards is DNS + secrets + `./bootstrap.sh`.

---

## 0. What sissy expects of your project

sissy hosts an image; it does not build your app or live inside it. Your
project must satisfy three things before any of this works.

**1. A Dockerfile, from `shopware/docker`.** The whole design is built on it:

```bash
composer require shopware/docker
```

The Flex recipe writes the Dockerfile into your project, and keeps it
up-to-date — [Shopware's docs][swdocker] are explicit that you require the
package rather than copy the file. It is a two-stage build: `shopware-cli`
runs `shopware-cli project ci /src`, and the result is copied `--chown=82` into
the runtime base image.

```dockerfile
ARG PHP_VERSION=8.3
FROM ghcr.io/shopware/docker-base:$PHP_VERSION-frankenphp AS base-image
FROM ghcr.io/shopware/shopware-cli:latest-php-$PHP_VERSION AS shopware-cli
```

Override `PHP_VERSION` via build args if you need a different one. sissy's
build workflow defaults to `./shopware/docker/Dockerfile` with build context
`./shopware` — i.e. the app lives in a `shopware/` subdirectory of your repo.
If your layout differs, pass the `context` and `dockerfile` inputs in
[§2](#2-get-the-image-building) rather than moving files around.

### Which web server variant

`docker-base` ships in two shapes, and which one you get is decided entirely by
the tag:

| tag | serves with | entrypoint | ports |
|---|---|---|---|
| `:8.4-frankenphp` (recipe default) | FrankenPHP, one process | `docker-php-entrypoint` | 8000, 80, 443, 2019 |
| `:8.4`, `:8.4-caddy`, `:8.4-nginx` | web server **+ PHP-FPM**, two processes under supervisord | `supervisord` | 8000, 9000 |

Shopware [recommends FrankenPHP][swdocker] — "automatic resource allocation and
requires just one process to run PHP, which is better suited for containerized
environments" — so **take the recipe default for a new project**. Both shapes
work here: each serves on 8000, which is the port Traefik is pointed at, and
sissy's `worker`/`scheduler` set an explicit `entrypoint:` that overrides
whichever the image declares.

Two things not to do:

- **Don't turn on FrankenPHP worker mode.** It is opt-in — it needs
  `FRANKENPHP_CONFIG="worker ./public/index.php"` plus
  `APP_RUNTIME=Runtime\FrankenPhpSymfony\Runtime` — and the default of booting
  per request is the safe one. Shopware's [compatibility issue][swworker] for
  long-running runtimes is still open, and a plugin holding request state
  leaks it between customers. sissy also gives you nowhere to hedge: `web` is
  one replica, so it is all-or-nothing on production.
- **Don't switch variants while migrating** an existing shop. If your current
  Dockerfile pins something FPM-based and works, move to sissy first, pass the
  smoke test, then change web server as its own deliberate step. Two variables
  at once turns any regression into guesswork.

[swworker]: https://github.com/shopware/shopware/issues/13921

If you install **commercial plugins**, note that the recipe's Dockerfile reads
the packages token from a BuildKit *secret mount*
(`--mount=type=secret,id=packages_token`), not a build arg — see the note in
[§2](#2-get-the-image-building).

[swdocker]: https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html

**2. The deployment helper, as a direct dependency.**

```bash
composer require shopware/deployment-helper
```

It arrives transitively via `shopware/docker`, but requiring it directly is
deliberate: the `setup` container's entrypoint *is* the helper, so every deploy
depends on it. A transitive dependency can vanish in an unrelated upgrade and
take your deploys with it.

**3. No infrastructure sissy doesn't have.** MariaDB is the message queue and
the lock store; cache and sessions are on local disk. There is no Redis,
RabbitMQ, OpenSearch or S3 anywhere. If your `composer.json` still requires
`shopware/elasticsearch`, disable it with `SHOPWARE_ES_ENABLED=0` in
`.env.local` ([§4](#4-fill-in-the-env-files)) rather than removing the package.

---

## 1. Provision the host

Ubuntu 24.04 LTS, **≥ 8 GB RAM** (two MariaDBs and ~10 containers). Create the
server with [`cloud-init.yaml`](cloud-init.yaml) as user-data — it installs
Docker and compose, creates the `deploy` user, the shared `edge` network, and
fail2ban.

**Attach a network-level firewall** (22/80/443 inbound, everything else denied)
— see [README § Firewall](README.md#firewall-network-level-not-host-level) for
the `hcloud` commands and for why there is deliberately no ufw on the host.

Then verify SSH before you close the console tab:

```bash
grep 'ssh:' /var/log/cloud-init-output.log      # want: imported N key(s)
ssh deploy@<host>                                # from your machine
```

If you see the `WARNING` instead of `imported N key(s)`, the provider injected
no keys and hardening was skipped on purpose so you are not locked out. Fix
access before rebooting.

---

## 2. Get the image building

sissy ships the workflows; your project calls them. Add to **your** repo as
`.github/workflows/ci-cd.yml`:

```yaml
name: CI/CD
on:
  push:
    branches: [main, develop]

jobs:
  build:
    permissions: { contents: read, packages: write }
    uses: vanWittlaer/sissy/.github/workflows/build-docker.yml@v1
    with:
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'stage' }}
    secrets: inherit
  deploy:
    needs: build
    uses: vanWittlaer/sissy/.github/workflows/deploy-ssh.yml@v1
    with:
      environment: ${{ github.ref == 'refs/heads/main' && 'prod' || 'stage' }}
      stack: ${{ github.ref == 'refs/heads/main' && 'prod' || 'stage' }}
      tag: ${{ needs.build.outputs.tag }}
    secrets: inherit
```

Which branch maps to which environment is *your* policy — sissy has no opinion
and ships no `ci-cd.yml` of its own.

Create GitHub **environments** named `prod` and `stage` (Settings →
Environments); both workflows run under `environment:`, so that is where the
secrets are read from. Then:

| Name | Kind | Required | What |
|---|---|---|---|
| `SSH_PRIVATE_KEY` | secret | yes | Private half of a key whose public half is in `/home/deploy/.ssh/authorized_keys` on the host. **cloud-init only imports the provider's console keys — this one you add yourself.** |
| `DEPLOY_HOST` | variable | yes | Hostname or IP the runner SSHes to. |
| `SSH_KNOWN_HOSTS` | variable | recommended | Output of `ssh-keyscan <host>`. Without it the deploy still runs but trusts the host key on first use and logs a warning. |
| `BEARER_PACKAGES_SHOPWARE` | secret | only for commercial plugins | Your `packages.shopware.com` token. Passed to the build as the BuildKit secret `packages_token`, which is what the recipe's Dockerfile mounts; also passed as `SHOPWARE_PACKAGES_TOKEN` build arg for hand-written Dockerfiles that declare it. Leave unset and the build runs unauthenticated — fine until a commercial plugin is required. |

Push once and let the build run. It publishes to
`ghcr.io/<owner>/<repo>`, **lowercased** — GHCR rejects uppercase, so
`vanWittlaer/my-shop` becomes `ghcr.io/vanwittlaer/my-shop`. Note that exact
string; it is `APP_IMAGE` in [§4](#4-fill-in-the-env-files).

Each build pushes two tags: the immutable commit SHA, and a moving pointer
(`latest` when `environment: prod`, otherwise `stage`). **Deploys always use
the SHA** — `build` outputs it and `deploy` consumes it, so what ships is
exactly what was built.

The `deploy` job will fail until the host is set up; that is expected at this
point.

---

## 3. Clone sissy onto the host

```bash
sudo git clone --branch v1 https://github.com/vanWittlaer/sissy.git /opt/sissy
sudo chown -R deploy:deploy /opt/sissy
```

Pin to a release tag, not a branch. `.env`, `.env.local` and `data/` are
gitignored, so they live in the working tree as untracked files and survive
every checkout — which is what makes ordinary git commands answer the
operational questions:

```bash
git -C /opt/sissy describe --tags     # which version is this host on?
git -C /opt/sissy status              # what did someone hand-edit at 3am?
git -C /opt/sissy checkout v1.1       # upgrade
git -C /opt/sissy checkout v1.0.0     # roll back
```

---

## 4. Fill in the env files

**Every stack has two, and they are not interchangeable** — this is the single
most common thing to get wrong. `.env` is *interpolated into* `compose.yaml`
(templating; containers never see these names). `.env.local` is named by
`env_file:`, so its lines become environment variables *inside* the containers,
**literally** — `${...}` is not expanded, so DSNs spell the password out in
full. Change a DB password and you edit it in both files, in every DSN.

```bash
cd /opt/sissy
for s in edge prod stage; do
  for f in .env .env.local; do
    [ -f "$s/$f.example" ] && cp -n "$s/$f.example" "$s/$f"
  done
done
chmod 600 */.env */.env.local        # DB passwords and APP_SECRET live here
```

Now edit each one. The values that need thought:

| Key | File | Notes |
|---|---|---|
| `APP_IMAGE` | `.env` | Exactly the lowercased image from [§2](#2-get-the-image-building). **Identical in prod and stage** — they differ by tag, never by repository, which is what makes promoting a build just deploying an existing tag. `bootstrap.sh` warns if they diverge. |
| `TAG` | `.env` | The SHA you are deploying. `deploy.sh` rewrites this on every deploy, so after the first one it stays truthful by itself. |
| `DOMAIN` | `.env` | Canonical host Shopware serves. Prod also has `DOMAIN_REDIRECT` (the other of www/bare), which gets its own certificate and 301s to `DOMAIN`. |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | `.env` | Must also appear, spelled out, in `.env.local`'s `DATABASE_URL` and `LOCK_DSN`. |
| `BASIC_AUTH` | `stage/.env` | `htpasswd -nb user pass`, then **double every `$` to `$$`** — compose interpolation eats single ones and auth silently breaks. |
| `ACME_EMAIL` | `edge/.env` | Let's Encrypt contact. `edge` has no `.env.local`; it is not a Shopware app. |
| `APP_URL` | `.env.local` | `https://` + your `DOMAIN`. Must agree with `sales_channel_domain.url` or the shop redirects in circles. |
| `SYMFONY_TRUSTED_PROXIES` | `.env.local` | Leave at `0.0.0.0/0`. Traefik forwards plain HTTP to `:8000`; without this every asset URL comes out `http://` on an `https://` page and browsers block it. Safe only because no app port is published — note the `SYMFONY_` prefix, a bare `TRUSTED_PROXIES` is read by nothing. |
| `APP_SECRET`, `INSTANCE_ID` | `.env.local` | See below. |

### APP_SECRET and INSTANCE_ID

Both must be **stable** for the life of an installation, and the right value
depends on your journey:

- **Greenfield, and always for `stage`:** generate fresh ones.
  ```bash
  openssl rand -hex 32                       # INSTANCE_ID
  bin/console system:generate-app-secret     # APP_SECRET
  ```
- **Existing shop moving to sissy, keeping the same domain:** copy the values
  from the old installation's `.env`. Apps stay registered and sessions survive.

Give `stage` its *own* pair even when migrating. A copy of a shop that reuses
production's identity re-registers against app servers as if it were
production; a distinct pair makes it a separate shop id, which is what you
want. See [Benny's notes on generating these][notebook].

[notebook]: https://notebook.vanwittlaer.de/hosting/how-to-generate-instance_id-and-app_secret

---

## 5. Point DNS

A-records for prod's `DOMAIN` **and** `DOMAIN_REDIRECT`, plus stage's `DOMAIN`,
all at the host. Let's Encrypt validates each host separately, so a missing
record for the redirect host means a missing certificate.

If you are migrating a live shop, point only **stage** here for now and leave
production DNS alone until [§10](#10-cutover).

---

## 6. Make sure the host can pull your image

GHCR packages inherit the repo's visibility and start **private**. Either flip
the package to public (Packages → your image → Package settings → Change
visibility), or authenticate on the host as `deploy`:

```bash
echo <PAT> | docker login ghcr.io -u <user> --password-stdin   # read:packages
docker pull ghcr.io/<owner>/<repo>:<sha>                       # prove it works
```

Skip this and `bootstrap.sh` fails on pull. Note that GHCR reports a private
package you cannot see as **`not found`**, not `unauthorized` — so "tag not
found" for a tag you know exists usually means auth, not a bad tag.

---

## 7. Bootstrap

```bash
cd /opt/sissy
./bootstrap.sh                 # edge + prod + stage
./bootstrap.sh stage           # or one stack at a time
```

Idempotent, so re-running after a fix is fine. It creates the `edge` network,
starts Traefik, pre-creates the bind-mount directories with the right ownership
(UID 82 — the app runs as that user), fixes `mariadb.cnf`'s mode, and brings up
each stack. The `setup` container installs Shopware on an empty database and
migrates an existing one, and must exit 0 before `web`/`worker`/`scheduler`
start.

Traefik issues certificates on the first HTTPS hit, so the first page load is
slow and may briefly show a self-signed warning.

**Greenfield stops here** — go to [§9](#9-smoke-test).

---

## 8. Existing shop: bring your data across

**Order matters: bootstrap first, then import.** `import-db.sh` execs into the
running `database` and `web` containers, so the stack has to be up. The fresh
install from §7 is scaffolding you are about to overwrite — that is expected,
not waste.

Rehearse on **stage** first. Everything below works the same for prod, with one
extra guard.

### 8.1 Database

On the old server:

```bash
mariadb-dump --single-transaction --hex-blob --routines --events --triggers \
  -u <user> -p <database> | gzip > /tmp/shop.sql.gz
```

`--single-transaction` reads from one InnoDB snapshot, so the dump is
consistent across tables and takes no locks — do not substitute a per-table
tool. (`ddev export-db --file=/tmp/shop.sql.gz` is the local-dev equivalent.)

Then, on the sissy host:

```bash
scp /tmp/shop.sql.gz deploy@<host>:/tmp/
./import-db.sh stage /tmp/shop.sql.gz oldshop.example.com
```

The third argument is **the hostname the dump came from** (it defaults to
`ddev.site`). Every `sales_channel_domain.url` containing it is repointed at
this stack's `DOMAIN`; get it wrong and the storefront keeps redirecting to the
old server. The script drops and recreates the database, imports, runs the
deployment helper to migrate your schema up to the image's Shopware version,
clears `messenger_messages` so old queued jobs are not replayed here, and
clears the cache.

For **prod** it refuses unless you mean it — the guard exists because this
command aimed at prod is usually a mistake:

```bash
FORCE=1 ./import-db.sh prod /tmp/shop.sql.gz oldshop.example.com
```

### 8.2 Media and documents

Not in the dump — the database only holds references.

```bash
# from the old server
rsync -a <old>/public/media/ deploy@<host>:/opt/sissy/prod/data/media/
rsync -a <old>/files/        deploy@<host>:/opt/sissy/prod/data/files/

# on the sissy host
sudo chown -R 82:82 prod/data/media prod/data/files
docker compose -f prod/compose.yaml exec -T web php bin/console media:generate-thumbnails
```

`media` and `files` are the two whose loss is unrecoverable — `files` holds
invoice PDFs, import/export and `theme-config`. `thumbnail`, `theme` and
`sitemap` regenerate themselves and are not worth copying.

### 8.3 What came across, and what didn't

Admin logins now come from the dump, not from the fresh install — your old
credentials, not any created in §7. Plugin state, orders and customers came
with the database. What did *not* come across: anything in the old server's
`.env` you did not carry into `.env.local` (§4), cron entries, and mail
configuration — set `MAILER_DSN` in `.env.local`.

---

## 9. Smoke test

```bash
cd /opt/sissy
docker compose -f prod/compose.yaml ps          # all Up; setup shows Exited (0)
docker compose -f prod/compose.yaml logs --tail=20 worker scheduler
```

`setup` having exited 0 is success, not a failure. A `worker` stuck in
`Restarting` is the failure mode to watch for — with `restart: unless-stopped`
a crash-loop reads as healthy at a glance while the queue silently stops
draining.

Then from outside:

```bash
curl -sI https://<domain> | head -3                       # 200, valid TLS
curl -s https://<domain> | grep -o 'src="[^"]*"' | head    # asset URLs https://
```

Any `src="http://..."` means `SYMFONY_TRUSTED_PROXIES` did not apply — check
the spelling of the variable, then `docker compose ... up -d` (a `restart`
reuses the old environment).

Finally: log in at `/admin`, place a test order, and confirm the mail arrives —
that exercises `web`, the database queue, the worker and `MAILER_DSN` in one
go. On stage, expect the Traefik basic-auth prompt first; `/api` is
deliberately exempt, because the admin's bearer token replaces basic
credentials and would otherwise re-prompt forever.

---

## 10. Cutover

Only for an existing shop, once stage has proven the import works.

1. **Lower the TTL** on the production DNS records to ~300s, at least a day
   ahead. This is the step people skip and then wait hours for.
2. **Freeze the old shop** — maintenance mode, or at minimum stop taking
   orders. Anything written after your final dump is lost.
3. **Final dump and delta sync**, exactly as §8 but into `prod`:
   ```bash
   FORCE=1 ./import-db.sh prod /tmp/final.sql.gz oldshop.example.com
   rsync -a <old>/public/media/ deploy@<host>:/opt/sissy/prod/data/media/
   sudo chown -R 82:82 prod/data/media
   ```
   The media rsync is incremental, so the pre-sync from §8.2 makes this quick.
4. **Flip DNS** to the sissy host, for both `DOMAIN` and `DOMAIN_REDIRECT`.
5. **Watch** the first certificate issuance and the first orders:
   ```bash
   docker compose -f edge/compose.yaml logs -f
   docker compose -f prod/compose.yaml logs -f web worker
   ```
6. **Keep the old server** running and untouched for a few days. Rollback is
   pointing DNS back at it — which only works if you have not let it drift.

---

## 11. Day two

```bash
./deploy.sh prod <sha>       # CI does this for you on every push
./deploy.sh prod             # re-deploy the tag recorded in prod/.env
./refresh-stage.sh           # prod DB -> stage (DB only; media is separate)
./backup.sh prod             # -> backups/prod/<UTC timestamp>/
```

Two things to set up while it is fresh:

- **Backups on a timer, as root**, pointed at a real mounted volume. Not a
  precaution: Shopware writes `files/theme-config/` mode 0700, so only UID 82
  or root can read it and `tar` aborts otherwise.
  ```
  # /etc/cron.d/sissy-backup
  0 3 * * * root BACKUP_ROOT=/mnt/backup/sissy /opt/sissy/backup.sh prod >> /var/log/sissy-backup.log 2>&1
  ```
  Then **test a restore into stage** — an untested backup is a hypothesis.
- **Upgrading sissy itself** is `git -C /opt/sissy checkout v1.1` followed by
  `./bootstrap.sh`. Read the release notes first; your `.env`, `.env.local` and
  `data/` are untracked and come through untouched.

From here, [`README.md`](README.md) is the reference for everything above —
particularly [Operational notes](README.md#operational-notes), which is the
list of things that fail *silently* and is worth reading once in full before
you need it.
