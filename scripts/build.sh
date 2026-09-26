#!/bin/bash
# Build the Chromium-for-TOS Docker application package (<appid>.tar.gz + .sha256).
#
# Usage: scripts/build.sh [version] [platform]
#   version  default: the accetto image tag pinned in src/docker-compose.yml (e.g. 13)
#            format : <upstream-base>[-<packaging-iteration>], e.g. 13-1, 13-2
#   platform default: x86_64   (TOS asset naming has no platform suffix for Docker apps,
#                               but config.ini.platform must match the submitted arch)
set -euo pipefail

cd "$(dirname "$0")/.."
ROOT=$(pwd)
SRC="$ROOT/src"
STAGE="$ROOT/build/stage"
OUT="$ROOT/out"
APPID="chromiumdocker"

IMAGE_REF=$(grep -oE 'accetto/debian-vnc-xfce-chromium-g3:[0-9a-zA-Z._-]+' "$SRC/docker-compose.yml" | head -1)
IMAGE_TAG="${IMAGE_REF##*:}"

VERSION="${1:-$IMAGE_TAG}"
PLATFORM="${2:-x86_64}"

case "$PLATFORM" in
  x86_64|aarch64) : ;;
  *) echo "FATAL: platform must be x86_64 or aarch64 (got '$PLATFORM')"; exit 1 ;;
esac

UPSTREAM="${VERSION%%-*}"
[ "$IMAGE_TAG" = "$UPSTREAM" ] || {
  echo "FATAL: compose image tag ($IMAGE_TAG) != upstream base of version ($UPSTREAM)"
  exit 1
}

echo ">> packaging ${APPID} version ${VERSION} platform ${PLATFORM}"

# ---------- stage ----------
rm -rf "$STAGE" "$OUT"
mkdir -p "$STAGE" "$OUT"
for f in config.ini "$APPID.lang" "$APPID.svg" docker-compose.yml; do
  cp "$SRC/$f" "$STAGE/$f"
done

python3 - "$STAGE" "$VERSION" "$PLATFORM" "$APPID" <<'PY'
import sys, pathlib
stage, ver, plat, appid = sys.argv[1], sys.argv[2], sys.argv[3], sys.argv[4]
for name in ("config.ini", f"{appid}.lang"):
    p = pathlib.Path(stage) / name
    data = (p.read_text(encoding="utf-8")
             .replace("@@VERSION@@", ver)
             .replace("@@PLATFORM@@", plat))
    p.write_bytes(data.replace("\r\n", "\n").encode("utf-8"))
PY

# build-machine hygiene (packaging guide pitfall 8)
export COPYFILE_DISABLE=1
find "$STAGE" \( -name '._*' -o -name '.DS_Store' \) -delete
xattr -rc "$STAGE" 2>/dev/null || true
python3 - "$STAGE" <<'PY'
import sys, pathlib
stage = pathlib.Path(sys.argv[1])
for p in stage.rglob("*"):
    if p.is_file():
        b = p.read_bytes()
        if b.startswith(b"\xef\xbb\xbf"):
            b = b[3:]
        if b"\r\n" in b:
            b = b.replace(b"\r\n", b"\n")
        p.write_bytes(b)
PY

# ---------- verify (TOS review-standards self-check) ----------
python3 - "$STAGE" "$VERSION" "$PLATFORM" "$APPID" <<'PY'
import json, re, sys, pathlib
import xml.etree.ElementTree as ET

stage, ver, plat, appid = pathlib.Path(sys.argv[1]), sys.argv[2], sys.argv[3], sys.argv[4]
errs = []
def chk(cond, msg):
    if not cond:
        errs.append(msg)

# ---- exactly the four required files at the archive root ----
names = sorted(p.name for p in stage.iterdir())
chk(names == sorted(["config.ini", f"{appid}.lang", f"{appid}.svg", "docker-compose.yml"]),
    f"archive must contain exactly 4 required files, got {names}")

# ---- config.ini ----
raw_cfg = (stage / "config.ini").read_text(encoding="utf-8")
chk("@@" not in raw_cfg, "config.ini still contains unreplaced @@PLACEHOLDER@@")
cfg = json.loads(raw_cfg)
upstream = ver.split("-")[0]

chk(cfg["id"] == appid, "id must equal appid")
chk(cfg["version"] == ver, f"config.ini version must be {ver}")
chk(re.fullmatch(r"[0-9][0-9.]{0,15}(-[0-9]{1,3})?", cfg["version"]) is not None,
    "version must be digits/dots with optional -N suffix, max 20 chars, no zero padding")
chk(cfg["application_type"] == "docker", "application_type must be docker")
chk("DockerEngine" in cfg["depend"], "depend must include DockerEngine")
chk("docker" in cfg["relation"] and "DockerEngine" in cfg["relation"], "relation must list docker + DockerEngine")
chk("type" not in cfg, "deb-only 'type' field must NOT appear (Docker apps use open_path)")
chk(cfg.get("open_path") is True, "open_path must be true")
chk(cfg["icon"] == f"/images/icons/{appid}.svg", "icon must be /images/icons/<appid>.svg")
chk(cfg["compose_project"] == appid, "compose_project must equal appid")
chk(cfg["platform"] == plat, f"config.ini platform must be {plat}")
chk(cfg.get("beta") is False, "beta must be false for a store submission")
chk(cfg.get("publisher") == "Moechz", "publisher must be Moechz (packaging guide pitfall 49)")
chk(isinstance(cfg.get("category"), list) and 1 <= len(cfg["category"]) <= 3,
    "category must be a list of 1..3 official categories")
for field in ("id", "icon", "publisher", "exec", "version", "low_version",
              "category", "depend", "platform", "application_type", "user",
              "all_user_display", "allow_open_in_mobile"):
    chk(field in cfg, f"required config.ini field missing: {field}")
m = re.fullmatch(r"http://\$\{ip\}:(\d+)", cfg["path"])
chk(m is not None, "path must be http://${ip}:<port> (Docker app URL form)")
cfg_port = int(m.group(1)) if m else 0
for bad in ("help", "official", "Official"):
    v = cfg.get(bad)
    if v:
        chk(v.startswith("https://github.com/"),
            f"{bad} must be a github.com URL (link checker does an HTTP GET)")

# ---- lang ----
lang = (stage / f"{appid}.lang").read_text(encoding="utf-8")
chk("@@" not in lang, "lang still contains unreplaced @@PLACEHOLDER@@")
secs = re.findall(r"^\[([a-z]{2}-[a-z]{2})\]$", lang, re.M)
required14 = set("zh-cn zh-hk en-us fr-fr de-de it-it es-es hu-hu ja-jp ko-kr "
                 "pl-pl ru-ru tr-tr pt-pt".split())
chk(required14.issubset(set(secs)), f"lang missing required languages: {sorted(required14 - set(secs))}")
chk(len(secs) == len(set(secs)), "lang has duplicate language sections")
for s in secs:
    body = lang.split(f"[{s}]", 1)[1].split("[", 1)[0]
    for key in ("name", "auth", "version", "descript", "release_note", "important"):
        mm = re.search(rf'{key}\s*=\s*"(.+)"', body)
        chk(mm is not None and mm.group(1).strip(), f"[{s}] {key} empty or missing")
    chk(f'version      = "{ver}"' in body, f"[{s}] version != {ver}")
chk(re.search(r"\bbeta\b", lang, re.I) is None, "lang must not contain the word 'beta' (V11)")

# ---- svg icon (TOS Icon Compliance: <= 50 KB, <= 50 elements) ----
svg_path = stage / f"{appid}.svg"
svg_bytes = svg_path.read_bytes()
chk(len(svg_bytes) <= 50 * 1024, f"icon too large: {len(svg_bytes)} bytes (limit 50 KB)")
svg_txt = svg_bytes.decode("utf-8")
try:
    root = ET.fromstring(svg_txt)
    n_elems = sum(1 for _ in root.iter())
    chk(root.tag.endswith("svg"), "icon root element must be <svg>")
    chk("viewBox" in root.attrib, "icon svg must declare viewBox")
    chk(n_elems <= 50, f"icon has {n_elems} elements (limit 50)")
except ET.ParseError as e:
    errs.append(f"icon is not valid XML: {e}")
for banned in ("<filter", "<use", "sodipodi", "inkscape", "<metadata", "rdf:"):
    chk(banned not in svg_txt, f"icon must not contain {banned}")

# ---- docker-compose.yml ----
comp = (stage / "docker-compose.yml").read_text(encoding="utf-8")
# comments are prose (they deliberately name the forbidden options), so drop them
comp_nc = "\n".join(l for l in comp.splitlines() if not l.lstrip().startswith("#"))
for banned in ("privileged", "network_mode", "docker.sock", "cap_add", "pid:", "ipc:"):
    chk(banned not in comp_nc, f"compose must not use {banned}")
chk(re.search(r"ghcr\.io|quay\.io|lscr\.io|registry\.", comp_nc) is None,
    "images must come from Docker Hub (bare names)")
chk(":latest" not in comp_nc, "image must use a fixed tag, never :latest")
chk(f"accetto/debian-vnc-xfce-chromium-g3:{upstream}" in comp_nc,
    f"chromium image tag must equal upstream base of version ({upstream})")
chk(re.search(rf"container_name:\s*{appid}\s*$", comp_nc, re.M) is not None,
    "main container_name must equal appid")
services = comp_nc.count("container_name:")
chk(services >= 1, "expected at least one service")
chk(comp_nc.count('user: "1000:1000"') == services, "every service must pin non-root user 1000:1000")
chk(comp_nc.count("restart: unless-stopped") == services, "every service must use restart: unless-stopped")
chk(comp_nc.count("healthcheck:") == services, "every service must define a healthcheck")
chk(len(re.findall(r"^\s+TZ:\s*\S", comp_nc, re.M)) == services, "every service must set TZ explicitly")
chk(re.search(r"user:\s*[\"']?(0|root)", comp_nc) is None, "containers must not run as root")
chk(f"/Volume*/DockerAppData/{appid}/" in comp_nc, f"volumes must live under /Volume*/DockerAppData/{appid}/")
chk(comp_nc.rstrip().endswith("protocol: http"), "x-app-meta must be the last block")
chk("x-app-meta:" in comp_nc and f'port: {cfg_port}' in comp_nc,
    "x-app-meta web.port must match config.ini path port")
ports = re.findall(r"^\s*-\s*[\"'](\d+):(\d+)[\"']\s*$", comp_nc, re.M)
chk(len(ports) == 1, f"compose must publish exactly one host port, got {ports}")
if len(ports) == 1:
    host, cont = int(ports[0][0]), int(ports[0][1])
    chk(host == cfg_port, f"published host port {host} != config.ini path port {cfg_port}")
    chk(host not in (22, 80, 443, 445, 3306, 5050, 5432, 6379, 8181, 8443),
        f"host port {host} is reserved")
    chk(8000 <= host <= 19999, f"host port {host} outside the TOS-recommended 8000-19999 range")
    chk(cont == 6901, f"container port should be 6901 (noVNC), got {cont}")
# no literal secrets anywhere in the compose
for pat, msg in ((r"PASSWORD:\s*\S", "compose must not contain a literal password"),
                 (r"VNC_PW:\s*\S", "compose must not contain a literal VNC password")):
    chk(re.search(pat, comp_nc) is None, msg)
chk("http://127.0.0.1:6901/" in comp_nc, "healthcheck must probe the noVNC port")

if errs:
    print("VERIFY FAIL:")
    for e in errs:
        print("  -", e)
    sys.exit(1)
print(f"verify OK: files={names} langs={len(secs)} icon_elements={n_elems} "
      f"icon_bytes={len(svg_bytes)} host_port={cfg_port}")
PY

# ---------- pack ----------
# GNU-format tar, deterministic ownership/timestamps; plain gzip
python3 - "$STAGE" "$OUT" "$APPID" <<'PY'
import tarfile, pathlib, gzip, io, os, sys
stage, out, appid = pathlib.Path(sys.argv[1]), pathlib.Path(sys.argv[2]), sys.argv[3]
tarpath = out / f"{appid}.tar.gz"
buf = io.BytesIO()
with tarfile.open(fileobj=buf, mode="w", format=tarfile.GNU_FORMAT) as tf:
    for p in sorted(stage.iterdir()):
        ti = tf.gettarinfo(str(p), arcname=p.name)
        ti.uid = ti.gid = 0
        ti.uname = ti.gname = "root"
        ti.mtime = 0
        ti.mode = 0o644
        with open(p, "rb") as fh:
            tf.addfile(ti, fh)
# deterministic gzip (no embedded timestamp / filename)
with open(tarpath, "wb") as fh:
    with gzip.GzipFile(fileobj=fh, mode="wb", compresslevel=9, mtime=0) as gz:
        gz.write(buf.getvalue())
print("packed", tarpath, f"{tarpath.stat().st_size} bytes")
PY

# ---------- checksum (portable: macOS has no sha256sum) ----------
python3 - "$OUT" "$APPID" <<'PY'
import hashlib, pathlib, sys
out, appid = pathlib.Path(sys.argv[1]), sys.argv[2]
p = out / f"{appid}.tar.gz"
h = hashlib.sha256(p.read_bytes()).hexdigest()
(out / f"{appid}.tar.gz.sha256").write_text(f"{h}  {appid}.tar.gz\n")
print(f"{h}  {appid}.tar.gz")
PY

# ---------- volume-resolved copy for manual (non-store) testing ----------
mkdir -p "$ROOT/test/compose-resolved"
sed 's#/Volume\*/DockerAppData/#/Volume1/DockerAppData/#g' "$SRC/docker-compose.yml" \
  > "$ROOT/test/compose-resolved/docker-compose.yml"

echo ">> done:"
ls -la "$OUT"
