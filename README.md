# chromium-for-tos

> TerraMaster TOS 7 App Center — **Docker application** package for
> [Chromium](https://www.chromium.org/), the open-source web browser project.

## What this is

A four-file TOS Docker application archive (`chromiumdocker.tar.gz`) that installs
a ready-to-use Chromium browser on TOS 7 through the App Center + Docker Engine:

- `config.ini` — TOS application metadata (`application_type: docker`, id `chromiumdocker`)
- `chromiumdocker.lang` — 23-language superset (TOS requires 14)
- `chromiumdocker.svg` — simplified Chromium mark (6 SVG elements, 414 bytes)
- `docker-compose.yml` — one service, image `accetto/debian-vnc-xfce-chromium-g3:13`

Open the app from its desktop icon: the NAS streams a full Linux desktop with
Chromium already maximised to your browser through noVNC on port **8901**.
Bookmarks, history, extensions, saved logins and downloads are stored on the NAS.

## Design highlights

- **Non-root by design.** The upstream image runs as an unprivileged user
  (uid 1000/1001) and serves its web client over **plain HTTP** — exactly what the
  TOS Docker model (`http://${ip}:<port>`) needs. Every service pins `user: "1000:1000"`.
- **No hardcoded credentials.** The VNC access password is generated from
  `/dev/urandom` on first start and written to
  `/Volume*/DockerAppData/chromiumdocker/config/.vnc_password`.
- **No privileged mode, no host networking, no Docker socket, no `cap_add`.**
- **Data persistence** for the whole browser profile under
  `/Volume*/DockerAppData/chromiumdocker/` (backup/migrate/reset friendly).
- **Healthcheck on the service** (`wget` against the noVNC port), explicit `TZ`,
  `restart: unless-stopped`, `x-app-meta` at the end of the compose file.
- **Docker Hub image only with a fixed tag** (never `:latest`).

## Why not `linuxserver/chromium`

The obvious candidate does not fit the TOS Docker application model, for two
independent and unavoidable reasons:

1. **It must start as root.** Its s6 init writes `/etc/nginx/...`, edits
   `/etc/sudoers`, creates device nodes and chowns paths. TOS forbids root
   containers and requires a non-root `user:` field. Running it as uid 1000
   leaves the web server unconfigured (empty page).
2. **Its web client requires a secure context.** Selkies/WebCodecs only work over
   HTTPS — the upstream docs state that the plain-HTTP port "gives you a broken
   client". TOS opens Docker apps as `http://${ip}:<port>`.

The `accetto` image family avoids both problems: it is explicitly built to run as
a non-root user (its `/etc/passwd` is world-writable precisely so arbitrary
`--user` values work) and it uses TigerVNC + noVNC, which work fine over HTTP.

### Use the Debian variant, not the Ubuntu one

the `accetto` project publishes two flavours. The Ubuntu images pin a **frozen**
`chromium-browser` `.deb` and their image label reports
`chromium112.0.5615.49` — a browser from April 2023. The Debian images install
`chromium` from the Debian archive instead; tag `13` reports
`debian13.6-chromium151.0.7922.137`. This package therefore uses
`accetto/debian-vnc-xfce-chromium-g3:13`.

## Build

```bash
scripts/build.sh                # -> out/chromiumdocker.tar.gz + .sha256
scripts/build.sh 13-2           # packaging iteration bump
scripts/build.sh 13-1 aarch64
```

Version format: `<upstream-image-tag>-<packaging-iteration>`; the upstream base
must equal the image tag in `docker-compose.yml`. The build stages the four files,
substitutes `@@VERSION@@` / `@@PLATFORM@@`, removes CRLF/BOM/AppleDouble, then runs
a **review-standards self-check**: archive layout, JSON validity, required fields,
language coverage and version consistency, Docker-Hub-only images, fixed tag,
reserved/recommended host ports, non-root user, per-service healthcheck/TZ/restart,
data path, `x-app-meta` position, no literal secrets, SVG size/element limits.

## Store submission checklist

1. Public GitHub repo (code + README only).
2. Release **tag `v13-1`** (must equal `config.ini` version), assets
   `chromiumdocker.tar.gz` + `chromiumdocker.tar.gz.sha256`.
   Docker asset naming: `<app_id>.tar.gz` — **no platform suffix**.
3. Developer platform → Add Application: ID `chromiumdocker`, package type Docker,
   repo URL.
4. Version Management → Add Version `13-1` → automated validation → review.
5. Version bumps: strictly increasing (`13-2`, …), upstream base keeps matching
   the image tag. Note that the container image carries the browser: when upstream
   rebuilds the image, bump the iteration so users get the updated Chromium.

## License / branding

Chromium is © The Chromium Authors (BSD-3-Clause). The container image is built by
[accetto](https://github.com/accetto/debian-vnc-xfce-g3) (GPL-3.0) and is used
unmodified from Docker Hub. The icon here is an independent simplified rendering of
the Chromium mark. This packaging is an independent community submission by Moechz.
