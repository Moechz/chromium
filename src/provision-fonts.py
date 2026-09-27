import hashlib, io, os, sys, tarfile, urllib.request

DEST, MARK = sys.argv[1], sys.argv[2]

# Ordered by measured throughput from inside the container (6-25 MB/s).
MIRRORS = ["https://mirrors.ustc.edu.cn/debian",
           "https://mirrors.tuna.tsinghua.edu.cn/debian",
           "https://deb.debian.org/debian",
           "https://mirrors.cloud.tencent.com/debian",
           "https://mirrors.aliyun.com/debian"]

# (pool-relative path, sha256, set-of-basenames-to-keep or None)
ITEMS = [
    ("pool/main/f/fonts-noto-cjk/fonts-noto-cjk_20240730+repack1-1_all.deb",
     "f5dc28a754e17327d99f0a612134d92c8dd6187314ae967cb77f25df60860139",
     {"NotoSansCJK-Regular.ttc", "NotoSansCJK-Bold.ttc"}),
    ("pool/main/f/fonts-noto/fonts-noto-core_20201225-6_all.deb",
     "377bbf625c0db815703ada0a4efc79e20af87104488c0368f529e2d05919b9ff",
     None),
    ("pool/main/f/fonts-noto-color-emoji/fonts-noto-color-emoji_2.051-0+deb13u1_all.deb",
     "03141cd51c0e9ff8ad858fcf2d8234f8a00ae4d7a0872df43a71519359c54e8c",
     None),
]

FONT_EXT = (".ttf", ".otf", ".ttc", ".otc")


def sha256(path):
    h = hashlib.sha256()
    with open(path, "rb") as fh:
        for chunk in iter(lambda: fh.read(1 << 20), b""):
            h.update(chunk)
    return h.hexdigest()


def download(urls, tmp):
    for url in urls:
        try:
            with urllib.request.urlopen(url, timeout=180) as res, open(tmp, "wb") as out:
                while True:
                    chunk = res.read(1 << 16)
                    if not chunk:
                        break
                    out.write(chunk)
            if os.path.getsize(tmp) > 0:
                return url
        except Exception as exc:                                  # noqa: BLE001
            print("fonts: %s failed (%s)" % (url, exc), flush=True)
        if os.path.exists(tmp):
            os.unlink(tmp)
    return None


def extract_deb(path, dest, keep):
    """Write the wanted font files of a .deb into dest (flat), stdlib only."""
    blob = open(path, "rb").read()
    if blob[:8] != b"!<arch>\n":
        return 0
    pos, written = 8, 0
    while pos + 60 <= len(blob):
        header = blob[pos:pos + 60]
        pos += 60
        name = header[0:16].decode("ascii", "replace").strip()
        try:
            size = int(header[48:58].decode("ascii").strip())
        except ValueError:
            return written
        member = blob[pos:pos + size]
        pos += size + (size & 1)
        if not name.startswith("data.tar"):
            continue
        mode = {"xz": "r:xz", "gz": "r:gz", "bz2": "r:bz2"}.get(name.rsplit(".", 1)[-1], "r:")
        with tarfile.open(fileobj=io.BytesIO(member), mode=mode) as tf:
            for entry in tf:
                base = os.path.basename(entry.name)
                if not entry.isfile() or not base.lower().endswith(FONT_EXT):
                    continue
                if keep is not None and base not in keep:
                    continue
                src = tf.extractfile(entry)
                if src is None:
                    continue
                with open(os.path.join(dest, base), "wb") as out:
                    out.write(src.read())
                written += 1
        break
    return written


def main():
    os.makedirs(DEST, exist_ok=True)
    # /tmp is a different filesystem from the mounted data dir, so a rename from
    # /tmp would fail with EXDEV: download into DEST and rename there.
    tmp = os.path.join(DEST, ".dl.part")
    if os.path.exists(tmp):
        os.unlink(tmp)
    done = True
    for ref, want, keep in ITEMS:
        stamp = os.path.join(DEST, ".got-" + want[:12])
        if os.path.exists(stamp):
            continue
        got = download([m + "/" + ref for m in MIRRORS], tmp)
        if not got:
            print("fonts: could not fetch %s from any mirror" % os.path.basename(ref), flush=True)
            done = False
            continue
        digest = sha256(tmp)
        if digest != want:
            print("fonts: checksum mismatch for %s (%s)" % (os.path.basename(ref), digest), flush=True)
            os.unlink(tmp)
            done = False
            continue
        count = extract_deb(tmp, DEST, keep)
        os.unlink(tmp)
        if count:
            open(stamp, "w").close()
            print("fonts: installed %d file(s) from %s" % (count, os.path.basename(ref)), flush=True)
        else:
            print("fonts: no matching font inside %s" % os.path.basename(ref), flush=True)
            done = False
    if done:
        open(MARK, "w").write("ok\n")
        print("fonts: provisioning complete", flush=True)
    else:
        print("fonts: incomplete, will retry on the next start", flush=True)
    return 0 if done else 1


sys.exit(main())
