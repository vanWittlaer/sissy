# Onboarding — putting a shop on sissy

The steps from "I have a Shopware project" to "it serves production", in order.
[`README.md`](README.md) is the reference for *why* things are shaped this way.

Two journeys share almost every step:

- **Greenfield** — no shop yet. sissy installs Shopware on an empty database.
- **Existing shop** — same setup, then [§8](#8-existing-shop-bring-your-data-across)
  replaces the fresh install with your data and [§10](#10-cutover) is the go-live.

Budget half a day to a day the first time. A second server afterwards is
DNS + secrets + `./bootstrap.sh`.

---

## 0. What sissy expects of your project

sissy hosts an image; it does not build your app or live inside it. Three
prerequisites:

**1. A Dockerfile, from `shopware/docker`:**

```bash
composer require shopware/docker
```

The Flex recipe writes the Dockerfile into your project and keeps it updated —
require the package, don't copy the file. sissy's build workflow defaults to
`./shopware/docker/Dockerfile` with context `./shopware` (app in a `shopware/`
subdirectory); for another layout pass the `context`/`dockerfile` inputs in
[§2](#2-get-the-image-building) rather than moving files.

### Which web server variant

The `docker-base` tag decides the shape:

| tag | serves with | entrypoint | ports |
|---|---|---|---|
| `:8.4-frankenphp` (recipe default) | FrankenPHP, one process | `docker-php-entrypoint` | 8000, 80, 443, 2019 |
| `:8.4`, `:8.4-caddy`, `:8.4-nginx` | web server + PHP-FPM under supervisord | `supervisord` | 8000, 9000 |

Both work with sissy (each serves on 8000). Take the recipe default
([Shopware recommends FrankenPHP][swdocker]) for a new project. Two don'ts:

- **Don't turn on FrankenPHP worker mode** (`FRANKENPHP_CONFIG` +
  `APP_RUNTIME`). Shopware's [compatibility issue][swworker] is still open, and
  with `web` at one replica there is no hedge on production.
- **Don't switch variants while migrating.** Move to sissy on your current
  variant first, pass the smoke test, then change web server as its own step.

[swworker]: https://github.com/shopware/shopware/issues/13921
[swdocker]: https://developer.shopware.com/docs/guides/hosting/installation-updates/docker.html

For **commercial plugins**: the recipe's Dockerfile takes the packages token as
`ARG SHOPWARE_PACKAGES_TOKEN`, which lands in the pushed image's history. Swap
it for `--mount=type=secret,id=packages_token,env=SHOPWARE_PACKAGES_TOKEN`
(frontend >= 1.10) and pass `legacy_token_build_arg: false` — see
[§2](#2-get-the-image-building).

**2. The deployment helper, as a direct dependency:**

```bash
composer require shopware/deployment-helper
```

It arrives transitively via `shopware/docker`, but every deploy depends on it
(the `setup` container's entrypoint *is* the helper) — a transitive dependency
can vanish in an unrelated upgrade.

**3. No infrastructure sissy doesn't have.** MariaDB is the queue and lock
store; cache and sessions are local disk. No Redis, RabbitMQ, OpenSearch or
S3. Basically the shopware/production template as it ships.

---

## 1. Provision the host

Ubuntu 24.04 LTS or Ubuntu 26.04 LTS, **≥ 8 GB RAM**. Create the server with
[`cloud-init.yaml`](cloud-init.yaml) as user-data — it installs Docker and
compose, creates the `deploy` user, the `edge` network, and fail2ban.

**Attach a network-level firewall** (22/80/443 inbound, everything else
denied).

---

## 2. Get the image building

Add to **your** repo as `.github/workflows/ci-cd.yml`:

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

Which branch maps to which environment is your policy — sissy ships no
`ci-cd.yml` of its own.

Create GitHub **environments** named `prod` and `stage` (Settings →
Environments) — that is where the secrets are read from:

| Name | Kind | Required | What |
|---|---|---|---|
| `SSH_PRIVATE_KEY` | secret | yes | Private half of a key whose public half is in `/home/deploy/.ssh/authorized_keys` on the host. **cloud-init only imports the provider's console keys — this one you add yourself.** |
| `DEPLOY_HOST` | variable | yes | Hostname or IP the runner SSHes to. |
| `SSH_KNOWN_HOSTS` | variable | recommended | Output of `ssh-keyscan <host>`. Without it the deploy trusts the host key on first use and logs a warning. |
| `BEARER_PACKAGES_SHOPWARE` | secret | commercial plugins only | Your `packages.shopware.com` token. Passed as BuildKit secret `packages_token` and, unless `legacy_token_build_arg: false`, as the `SHOPWARE_PACKAGES_TOKEN` build arg (which is recorded in image history — prefer the secret). |
| `COMPOSER_AUTH` | secret | private composer sources only | A whole composer `auth.json` (not a bare token), mounted as BuildKit secret `composer_auth` at `/src/auth.json`. For private VCS repos or a second registry. |

Push once and let the build run. It publishes to `ghcr.io/<owner>/<repo>`,
**lowercased** (GHCR rejects uppercase). Note that exact string — it is
`APP_IMAGE` in [§4](#4-fill-in-the-env-files).

Each build pushes two tags: the immutable commit SHA (what deploys use) and a
moving pointer (`latest` for `prod`, otherwise `stage`).

The `deploy` job fails until the host is set up; expected at this point.

---

## 3. Clone sissy onto the host

Note the below commands have already been run on the host by cloud-init.

```bash
sudo git clone --branch v1 https://github.com/vanWittlaer/sissy.git /opt/sissy
sudo chown -R deploy:deploy /opt/sissy
```

Pin to a release tag, not a branch. `.env`, `.env.local` and `data/` are
gitignored, so they survive every checkout:

```bash
git -C /opt/sissy describe --tags     # which version is this host on?
git -C /opt/sissy status              # what did someone hand-edit at 3am?
git -C /opt/sissy checkout v1.1       # upgrade
git -C /opt/sissy checkout v1.0.0     # roll back
```

---

## 4. Fill in the env files

**Every stack has two, and they are not interchangeable.** `.env` is
interpolated into `compose.yaml` (templating; containers never see it).
`.env.local` becomes environment variables inside the containers, **literally**
— `${...}` is not expanded, so DSNs spell the password out in full. Change a
DB password and you edit both files, in every DSN.

```bash
cd /opt/sissy
for s in edge prod stage; do
  for f in .env .env.local; do
    [ -f "$s/$f.example" ] && cp -n "$s/$f.example" "$s/$f"
  done
done
chmod 600 */.env */.env.local        # DB passwords and APP_SECRET live here
```

The values that need thought:

| Key | File | Notes |
|---|---|---|
| `APP_IMAGE` | `.env` | Exactly the lowercased image from [§2](#2-get-the-image-building). **Identical in prod and stage** — they differ by tag, never by repository. `bootstrap.sh` warns if they diverge. |
| `TAG` | `.env` | The SHA you are deploying. `deploy.sh` rewrites this on every deploy. |
| `DOMAIN` | `.env` | Canonical host. Prod also has `DOMAIN_REDIRECT` (the other of www/bare), which gets its own certificate and 301s to `DOMAIN`. |
| `DB_PASSWORD`, `DB_ROOT_PASSWORD` | `.env` | Must also appear, spelled out, in `.env.local`'s `DATABASE_URL` and `LOCK_DSN`. |
| `BASIC_AUTH` | `stage/.env` | `htpasswd -nb user pass`, then **double every `$` to `$$`** — compose interpolation eats single ones and auth silently breaks. |
| `ACME_EMAIL` | `edge/.env` | Let's Encrypt contact. `edge` has no `.env.local`. |
| `APP_URL` | `.env.local` | `https://` + your `DOMAIN`. Must agree with `sales_channel_domain.url` or the shop redirects in circles. |
| `SYMFONY_TRUSTED_PROXIES` | `.env.local` | Leave at `0.0.0.0/0`. Without it every asset URL comes out `http://` and browsers block it. Note the `SYMFONY_` prefix — a bare `TRUSTED_PROXIES` is read by nothing. Safe only because no app port is published. |
| `APP_SECRET`, `INSTANCE_ID` | `.env.local` | See below. |

### APP_SECRET and INSTANCE_ID

Both must stay **stable** for the life of an installation:

- **Greenfield, and always for `stage`:** generate fresh ones.
  ```bash
  openssl rand -hex 32                       # INSTANCE_ID
  bin/console system:generate-app-secret     # APP_SECRET
  ```
- **Existing shop, keeping the same domain:** copy the values from the old
  installation's `.env`. Apps stay registered and sessions survive.

Give `stage` its *own* pair even when migrating — reusing production's pair
makes stage impersonate production against app servers. See
[Benny's notes][notebook].

[notebook]: https://notebook.vanwittlaer.de/hosting/how-to-generate-instance_id-and-app_secret

---

## 5. Point DNS

A-records for prod's `DOMAIN` **and** `DOMAIN_REDIRECT`, plus stage's `DOMAIN`
**and** `mailpit.<stage DOMAIN>` (stage's mail-capture UI). Let's Encrypt
validates each host separately — a missing record means a missing certificate.

Migrating a live shop? Point only **stage** here for now; production DNS moves
in [§10](#10-cutover).

---

## 6. Make sure the host can pull your image

GHCR packages inherit the repo's visibility and start **private**. Either flip
the package to public (Packages → your image → Package settings → Change
visibility), or authenticate on the host as `deploy`:

```bash
echo <PAT> | docker login ghcr.io -u <user> --password-stdin   # read:packages
docker pull ghcr.io/<owner>/<repo>:<sha>                       # prove it works
```

GHCR reports a private package you cannot see as **`not found`**, not
`unauthorized` — "tag not found" for a tag you know exists usually means auth.

---

## 7. Bootstrap

```bash
cd /opt/sissy
./bootstrap.sh                 # edge + prod + stage
./bootstrap.sh stage           # or one stack at a time
```

Idempotent — re-running after a fix is fine. It creates the `edge` network,
starts Traefik, pre-creates the bind-mount directories with the right
ownership (UID 82), fixes `mariadb.cnf`'s mode, and brings up each stack. The
`setup` container installs/migrates and must exit 0 before
`web`/`worker`/`scheduler` start.

Traefik issues certificates on the first HTTPS hit, so the first page load is
slow and may briefly show a self-signed warning.

**Greenfield stops here** — go to [§9](#9-smoke-test).

---

## 8. Existing shop: bring your data across

**Bootstrap first, then import** — `import-db.sh` execs into the running
`database` and `web` containers. The fresh install from §7 is scaffolding you
are about to overwrite.

Rehearse on **stage** first.

### 8.1 Database

On the old server:

```bash
mariadb-dump --single-transaction --hex-blob --routines --events --triggers \
  -u <user> -p <database> | gzip > /tmp/shop.sql.gz
```

`--single-transaction` gives a consistent, lock-free dump — do not substitute
a per-table tool. (`ddev export-db --file=/tmp/shop.sql.gz` is the local-dev
equivalent.)

On the sissy host:

```bash
scp /tmp/shop.sql.gz deploy@<host>:/tmp/
./import-db.sh stage /tmp/shop.sql.gz oldshop.example.com
```

The third argument is **the hostname the dump came from** (default
`ddev.site`). Every `sales_channel_domain.url` containing it is repointed at
this stack's `DOMAIN`; get it wrong and the storefront redirects to the old
server. The script drops and recreates the database, imports, migrates the
schema up to the image's Shopware version, clears `messenger_messages`, and
clears the cache.

For **prod** it refuses without the guard:

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

`media` and `files` are unrecoverable if lost (`files` holds invoice PDFs,
import/export, `theme-config`). `thumbnail`, `theme` and `sitemap` regenerate
— don't copy them.

### 8.3 What came across, and what didn't

Admin logins, plugin state, orders and customers now come from the dump. What
did *not*: anything from the old server's `.env` you did not carry into
`.env.local` (§4), cron entries, and mail — set `MAILER_DSN` in `.env.local`.

---

## 9. Smoke test

```bash
cd /opt/sissy
docker compose -f prod/compose.yaml ps          # all Up; setup shows Exited (0)
docker compose -f prod/compose.yaml logs --tail=20 worker scheduler
```

`setup` exited 0 is success. A `worker` stuck in `Restarting` is the failure
mode to watch — with `restart: unless-stopped` a crash-loop reads as healthy
while the queue silently stops draining.

From outside:

```bash
curl -sI https://<domain> | head -3                       # 200, valid TLS
curl -s https://<domain> | grep -o 'src="[^"]*"' | head    # asset URLs https://
```

Any `src="http://..."` means `SYMFONY_TRUSTED_PROXIES` did not apply — check
the spelling, then `docker compose ... up -d` (a `restart` reuses the old
environment).

Finally: log in at `/admin`, place a test order, confirm the mail arrives —
that exercises `web`, the queue, the worker and `MAILER_DSN` in one go. On
stage the mail lands in Mailpit (`https://mailpit.<stage DOMAIN>`), not a real
inbox. Expect the basic-auth prompt first; `/api` is deliberately exempt
(the admin's bearer token would otherwise re-prompt forever).

---

## 10. Cutover

Only for an existing shop, once stage has proven the import works.

1. **Lower the TTL** on production DNS to ~300s, at least a day ahead.
2. **Freeze the old shop** — maintenance mode, or at minimum stop taking
   orders. Anything written after the final dump is lost.
3. **Final dump and delta sync**, as §8 but into `prod`:
   ```bash
   FORCE=1 ./import-db.sh prod /tmp/final.sql.gz oldshop.example.com
   rsync -a <old>/public/media/ deploy@<host>:/opt/sissy/prod/data/media/
   sudo chown -R 82:82 prod/data/media
   ```
   The rsync is incremental, so the pre-sync from §8.2 makes this quick.
4. **Flip DNS** to the sissy host, both `DOMAIN` and `DOMAIN_REDIRECT`.
5. **Watch** the first certificate issuance and the first orders:
   ```bash
   docker compose -f edge/compose.yaml logs -f
   docker compose -f prod/compose.yaml logs -f web worker
   ```
6. **Keep the old server** running and untouched for a few days. Rollback is
   pointing DNS back at it.

---

## 11. Day two

```bash
./deploy.sh prod <sha>       # CI does this for you on every push
./deploy.sh prod             # re-deploy the tag recorded in prod/.env
./refresh-stage.sh           # prod DB -> stage (DB only; media is separate)
./backup.sh prod             # -> backups/prod/<UTC timestamp>/
```

Set up while it is fresh:

- **Backups on a timer, as root**, pointed at a real mounted volume (root
  because Shopware writes `files/theme-config/` mode 0700, so `tar` aborts
  otherwise):
  ```
  # /etc/cron.d/sissy-backup
  0 3 * * * root BACKUP_ROOT=/mnt/backup/sissy /opt/sissy/backup.sh prod >> /var/log/sissy-backup.log 2>&1
  ```
  Then **test a restore into stage** — an untested backup is a hypothesis.
- **Upgrading sissy** is `git -C /opt/sissy checkout v1.1` +
  `./bootstrap.sh`. Read the release notes first; `.env`, `.env.local` and
  `data/` are untracked and come through untouched.

When something fails silently, read
[README § Operational notes](README.md#operational-notes) — that is the list
of exactly those failures.
