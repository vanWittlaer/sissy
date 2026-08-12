# CLAUDE.md

This file provides guidance to Claude Code (claude.ai/code) when working with code in this repository.

## What this repository is

**sissy** — **S**imple **S**hopware **S**erver: the server-side topology for running Shopware 6 on a single cloud server with nothing but Docker Compose. No Coolify, no Terraform, no PaaS. Compose stacks, bootstrap/deploy/backup scripts, cloud-init, and the reusable GitHub Actions workflows that drive them.

It holds **no Shopware application code**. A consuming project brings its own app and Dockerfile and uses sissy two ways, both pinned to the same tag:

- **On the host** — `git clone --branch v1 https://github.com/vanWittlaer/sissy.git /opt/sissy`. `.env`, `.env.local` and `data/` are gitignored, so they persist as untracked files across `git checkout` of another tag. That is what makes upgrade, rollback and "which version is this host on?" ordinary git commands.
- **In CI** — `uses: vanWittlaer/sissy/.github/workflows/build-docker.yml@v1`. Reusable workflows resolve their context against the *caller*, so `actions/checkout` fetches the consumer's source and the image name derives from the consumer's repository.

One tag covers both halves on purpose: `deploy-ssh.yml` invokes `$DEPLOY_PATH/deploy.sh '<stack>' '<tag>'`, so the workflow and the script are one interface and must not drift.

This was `sissy/` inside the vanWittlaer/sissy monorepo until 2026-08-12, split out with `git subtree split` (history preserved). Deploy target on the host has been `/opt/sissy` since 2026-08-08, `/opt/shop-server` before that.

## Production topology

Three compose stacks on one VPS, joined by an external Docker network named `edge`:

```
edge/      Traefik v3.3 — owns :80/:443, ACME TLS, docker provider (exposedbydefault=false)
prod/      web + worker×2 + scheduler + mariadb
stage/     web + worker + scheduler + mariadb   (Traefik basic-auth middleware)
```

The defining architectural choice: **MariaDB is the message queue and the lock store**. `MESSENGER_TRANSPORT_DSN` is left unset so Symfony falls back to `doctrine://`, `LOCK_DSN` points at the DB, and cache/sessions are on the local filesystem. No Redis, RabbitMQ, OpenSearch, or S3 anywhere in the server stacks — a consuming project whose `composer.json` still requires `shopware/elasticsearch` disables it with `SHOPWARE_ES_ENABLED=0`.

Consequences that constrain any change you make here:
- **`web` must stay at 1 replica.** Filesystem cache + native PHP sessions are per-container. Workers scale freely. A second web node requires introducing Redis first.
- **Workers must consume both `async` and `low_priority`** — separate Doctrine queues; dropping `low_priority` silently strands those messages.
- **Theme compilation happens inside the live `web` container** (via `shopware-deployment-helper`), because there is no S3 to hold the compiled theme. This is why deploys are not zero-downtime.
- `scheduler` runs `scheduled-task:run` as a blocking long-running process — no `--no-wait`.

### The two-env-file rule (the #1 compose gotcha here)

Every stack dir has **both**, and they are not interchangeable:

- `.env` — sits next to `compose.yaml` and is **interpolated into it** (`TAG`, `DOMAIN`, `DB_PASSWORD`, `BASIC_AUTH`).
- `.env.local` — named by `env_file:`, so its lines are injected as **environment variables** in the app containers. Values are **literal**; `${...}` is *not* expanded, so `DATABASE_URL`/`LOCK_DSN` must spell the password out in full.

Neither file is mounted — both are read host-side by the Compose CLI. Since `env_file` is applied at container creation, a changed `.env.local` needs `docker compose up -d` to take effect; `restart` reuses the old values.

Change a DB password and you must edit it in both files, in every DSN.

Stage's `BASIC_AUTH` htpasswd hash goes through compose interpolation, so **every `$` must be doubled to `$$`** (`htpasswd -nb user pass`, then double). Forgetting this silently breaks auth.

The root `.gitignore` blocks `**/.env`, `**/.env.local`, `**/data/` and `backups/` — only the `*.example` files are ever committed. On a host this is load-bearing, not hygiene: it is why `/opt/sissy` can be a git clone whose secrets and data survive checking out a different tag.

### Server operations

```bash
./bootstrap.sh                   # edge + prod + stage; idempotent; default stacks: prod stage
./bootstrap.sh stage             # one stack only
./deploy.sh prod 1a2b3c4         # pull tag, recreate services, migrate + theme-compile
./deploy.sh stage latest
./refresh-stage.sh               # prod DB -> stage DB (routed via host), then deployment helper
./backup.sh prod                 # db + media + files -> backups/prod/<UTC timestamp>/, rotated
./restore.sh stage 20260811-030000   # DESTRUCTIVE; FORCE=1 required for prod
```

All `cd` to their own directory first, so they work from anywhere.

`backup.sh` dumps the database with `mariadb-dump --single-transaction` inside the
stack's own `database` container, plus `tar`s `data/media` and `data/files`;
`thumbnail`/`theme`/`sitemap` are skipped since they regenerate. **Don't "modernise"
that dump to `shopware-cli project dump`** — it opens no transaction, so its output
isn't consistent across tables, and its per-table `FLUSH TABLES ... WITH READ LOCK`
is what forces the dump to run as root. `--single-transaction` is consistent, lock-free
and needs no `RELOAD`, so `backup.sh` reads `DB_PASSWORD`, not `DB_ROOT_PASSWORD`
(`restore.sh` still needs root — it drops and recreates the database).
`BACKUP_ROOT` (default `./backups`, gitignored) should point at an actually-mounted
backup volume in production. See `README.md#backups` for the full rundown.

Install and migration both run in a dedicated **`setup` container** (`entrypoint: /setup`, the deployment helper), which the app services gate on via `depends_on: {setup: {condition: service_completed_successfully}}`. So `up -d` *is* the deploy — `bootstrap.sh` and `deploy.sh` no longer exec the helper themselves. The ordering matters: migrations land while the old containers still serve, then new ones start, rather than new code meeting an old schema. `setup` overrides the `x-app` anchor's `depends_on` so it doesn't depend on itself, and `restart: "no"` so a completed run isn't restarted.

`shopware/deployment-helper` is a direct requirement in `composer.json` on purpose — it reached the project only via `shopware/docker`, and the whole deploy path depends on it.

`refresh-stage.sh` pipes `mariadb-dump` through the *host* because prod's and stage's `internal` networks are isolated from each other. It does not copy media — `rsync prod/data/media stage/data/media` separately if needed.

### Reverse proxy / TLS

Traefik terminates TLS and forwards **plain HTTP** to the container on `:8000`. Shopware's public filesystem has no `url` set, so asset URLs are built from the incoming request — which reads as `http://` unless the proxy headers are trusted, producing blocked mixed-content on every `/bundles/...` asset.

The fix is one variable in each stack's `.env.local`: **`SYMFONY_TRUSTED_PROXIES=0.0.0.0/0`**. Note the name — Symfony's FrameworkBundle defaults `trusted_proxies` to `%env(default::SYMFONY_TRUSTED_PROXIES)%`, so a plain `TRUSTED_PROXIES` is read by nothing and no config file is needed. `SYMFONY_TRUSTED_HEADERS` can stay unset; `Kernel.php` then trusts `FOR|PORT|PROTO`, which covers the scheme. It's an env var, so `up -d` suffices — no rebuild.

`0.0.0.0/0` is safe only because no service publishes a port: Traefik is the sole route in, and it strips inbound `X-Forwarded-*` from untrusted clients. Publish an app port and this becomes a live spoofing vector.

To check it's actually applied (`debug:config` fails on a frozen prod container):

```bash
docker compose -f prod/compose.yaml exec -T web php bin/console debug:container --parameter=kernel.trusted_proxies
curl -s https://<domain>/admin | grep -o 'src="[^"]*"' | head   # server-side truth, no browser cache
```

### Firewall

**There is deliberately no host firewall — don't add one back.** ufw/iptables filter the `INPUT` chain, but dockerd DNATs published ports in `nat/PREROUTING` and routes them through `FORWARD`, so every `ports:` mapping stays reachable regardless of the rules. A host firewall here would protect sshd only while appearing to protect everything, which is worse than none.

Inbound filtering is a **network-level Hetzner Cloud Firewall** (22/80/443 open, everything else denied), documented as `hcloud` commands in `README.md` so it stays part of the recovery record. Port 22 is open deliberately — the admin IP is dynamic — so key-only auth, no root login, and fail2ban are what actually guard SSH. On the host, the control that actually works is **not publishing ports**: both MariaDBs sit on `internal` with no `ports:`. fail2ban still runs for SSH brute-force; the `[sshd]` jail works out of the box on 24.04, so `/etc/fail2ban/jail.local` only tunes ban timings.

### SSH access

No key is committed. `cloud-init.yaml` copies the keys the provider injected for `root` (Hetzner's console selection) onto `deploy`, stripping any leading `command="..."` options cloud-init's `disable_root` may have prefixed — copying those verbatim would give `deploy` a login that prints a message and exits. It then disables password auth and root login via `/etc/ssh/sshd_config.d/99-hardening.conf`.

**The ordering is the point.** That hardening is a guarded `runcmd`, not cloud-init's `ssh_pwauth: false` / `disable_root: true`, because those fire unconditionally in an earlier stage — on a provider that injects no keys they'd produce an unreachable box. The script checks `deploy`'s `authorized_keys` is non-empty, skips with a warning otherwise, and reverts the drop-in if `sshd -t` rejects it. Preserve that check-before-lockdown shape if you touch it.

Also note `users:` starts with `- default`: declaring the list at all replaces the image default, and the provider's keys are handed to the default entry — drop it and there may be nothing to copy from.

### Volumes

`x-app-volumes` in each `compose.yaml` is shared by **web and worker**: `public/media`, `public/thumbnail`, `public/theme`, `public/sitemap`, `files` (Shopware's private filesystem — invoice PDFs, import/export, `theme-config`), and `var/log`. The sharing matters as much as the persistence — the worker generates thumbnails and sitemaps that only `web` serves, so an unshared path means the work happens and is never visible. `files` and `media` are the ones whose loss is unrecoverable; theme/thumbnail/sitemap regenerate.

Never mount `public/bundles` (baked at build by `assets:install`; a bind mount hides the image's copy, as bind mounts don't seed from the image) or share `var/cache` (per-container by design).

All of these must be **owned by UID 82** or the app fails with Permission denied. `bootstrap.sh:prep_dirs` creates and chowns them before Docker can make them root-owned — its `app_dirs` list must stay in sync with `x-app-volumes`.

### Image

The Dockerfile lives in the **consuming project**, not here — it is ~20 lines and projects customise it. `build-docker.yml` defaults to `./shopware/docker/Dockerfile` with context `./shopware`; pass the `dockerfile`/`context` inputs for another layout. The expected shape is a two-stage build: `ghcr.io/shopware/shopware-cli` runs `shopware-cli project ci /src`, and the result is copied `--chown=82` into `ghcr.io/shopware/docker-base:8.4`. The compose files here reference `${APP_IMAGE:?...}:${TAG:-latest}`.

`APP_IMAGE` is the one identifier that names *the shop*, not the platform — everything else (`/opt/sissy`, `99-sissy.cnf`, the `io.sissy.*` labels) names sissy itself and is meant to be identical across projects. It lives in each stack's `.env`, and CI derives the same value from the **caller's** `github.repository`, so a new project needs no edit here at all. Compose's `:?` form is deliberate: an unset `APP_IMAGE` fails with that message instead of docker's `invalid reference format`. `bootstrap.sh` warns when prod's and stage's values differ, since that silently breaks promote-by-tag.

**One image name for every environment** — prod and stage differ by *tag*, never by repository, so promoting a build is just deploying an existing tag. `build-docker.yml` pushes two tags per build: a moving pointer (`latest` for `prod`, `stage` otherwise) and the immutable commit SHA. Deploys always use the SHA, passed from the build job's `tag` output, so what ships is exactly what was built. The environment is also recorded as an OCI label (`io.sissy.environment`).

## Known open items

Carried over from `README.md` — treat as unfinished, not as settled design:

- **`worker`/`scheduler` must use `entrypoint:`, never `command:`** — the image entrypoint is supervisord, which takes a command as positional args and aborts. With `restart: unless-stopped` that crash-loop reads as "Up" in `docker ps`; the queue simply stops draining.
- CI deploy needs its own key: add the `SSH_PRIVATE_KEY` secret's public half to `/home/deploy/.ssh/authorized_keys` on the host, plus repo variables `DEPLOY_HOST` and `SSH_KNOWN_HOSTS`. cloud-init only imports the provider's console keys.

## CI/CD (`.github/workflows/`)

Three workflows, only one of which runs on this repo's own pushes:

- **`build-docker.yml`** — `workflow_call` only. Builds the caller's Dockerfile and pushes two tags: a moving pointer (`latest` for `prod`, `stage` otherwise) and the immutable commit SHA, which is what deploys pull. `context`/`dockerfile` inputs default to `./shopware` and `./shopware/docker/Dockerfile`.
- **`deploy-ssh.yml`** — `workflow_call` only. SSHes to `vars.DEPLOY_HOST` as `deploy` and runs `$DEPLOY_PATH/deploy.sh <stack> <sha>`; `deploy_path` defaults to `/opt/sissy`.
- **`lint.yml`** — this repo's own CI: shellcheck over `*.sh`, plus `docker compose config` per stack seeded from that stack's `.env.example`. The examples are the fixture, so a compose file that grows a `${VAR:?}` without a matching example line fails here instead of on someone's host.

There is deliberately no `ci-cd.yml` here. Which branch builds which environment is the consuming project's policy, not sissy's.

`stage` names both the GitHub environment and the stack directory, so `inputs.environment` and `inputs.stack` are usually the same string — they're separate inputs because the environment carries the secrets while the stack is a path on disk.

**Changing either reusable workflow's inputs breaks every project pinned to that major tag.** Add inputs with defaults; if a change can't be made backwards-compatible, cut `v2` rather than editing `v1` in place.
