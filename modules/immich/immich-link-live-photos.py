"""Link split live photos (HEIC + MP4 with the same stem) in Immich.

Dry-run by default. Pass --apply to actually change anything.

When several same-name photos match one video (for example a full-size
original and a small Google re-encode), the largest one is linked. A smaller
one that was linked earlier is unlinked again. Smaller duplicates are only
touched with --trash-duplicates, which moves them to the Immich trash.

Usage:
  export IMMICH_API_KEY=...
  immich-link-live-photos
  immich-link-live-photos --apply --limit 5
"""
import argparse
import json
import os
import sys
import urllib.error
import urllib.request
from collections import defaultdict
from datetime import datetime
from pathlib import PurePosixPath


def api(base, key, method, path, body=None):
    data = json.dumps(body).encode() if body is not None else None
    req = urllib.request.Request(
        base.rstrip("/") + "/api" + path,
        method=method,
        data=data,
        headers={
            "x-api-key": key,
            "Accept": "application/json",
            "Content-Type": "application/json",
        },
    )
    try:
        with urllib.request.urlopen(req, timeout=120) as r:
            raw = r.read()
            return json.loads(raw) if raw else None
    except urllib.error.HTTPError as e:
        msg = e.read().decode(errors="replace")
        raise RuntimeError(f"{method} {path} -> {e.code}: {msg}")


def fetch_all(base, key, asset_type, with_exif=False):
    assets, page = [], 1
    while page:
        res = api(
            base,
            key,
            "POST",
            "/search/metadata",
            {
                "type": asset_type,
                "page": page,
                "size": 1000,
                "withDeleted": False,
                "withExif": with_exif,
            },
        )["assets"]
        assets.extend(res["items"])
        page = int(res["nextPage"]) if res.get("nextPage") else None
        print(f"  fetched {len(assets)} {asset_type.lower()} assets...", file=sys.stderr)
    return assets


def ts(asset):
    s = asset.get("fileCreatedAt") or asset.get("localDateTime")
    return datetime.fromisoformat(s.replace("Z", "+00:00"))


def stem_ext(asset):
    p = PurePosixPath(asset["originalFileName"])
    return p.stem.lower(), p.suffix.lower()


def size_key(asset):
    exif = asset.get("exifInfo") or {}
    w = exif.get("exifImageWidth") or 0
    h = exif.get("exifImageHeight") or 0
    return (w * h, exif.get("fileSizeInByte") or 0)


def fmt(asset):
    exif = asset.get("exifInfo") or {}
    w = exif.get("exifImageWidth") or "?"
    h = exif.get("exifImageHeight") or "?"
    return f"{asset['originalFileName']} {asset['id']} {w}x{h}"


def build_plans(images, videos, args):
    cand_images = defaultdict(list)
    for a in images:
        stem, ext = stem_ext(a)
        if ext in (".heic", ".heif"):
            cand_images[(a["ownerId"], stem)].append(a)

    plans, used = [], set()
    for v in videos:
        stem, ext = stem_ext(v)
        if ext not in (".mp4", ".mov"):
            continue
        usable = []
        for img in cand_images.get((v["ownerId"], stem), []):
            diff = abs((ts(img) - ts(v)).total_seconds())
            linked = img.get("livePhotoVideoId")
            if diff > args.tolerance or img["id"] in used:
                continue
            if linked in (None, v["id"]):
                usable.append((img, diff))
        if not usable:
            continue

        best, diff = max(usable, key=lambda p: (size_key(p[0]), -p[1]))
        used.update(img["id"] for img, _ in usable)
        others = [img for img, _ in usable if img["id"] != best["id"]]
        stale = [i for i in others if i.get("livePhotoVideoId") == v["id"]]
        need_link = best.get("livePhotoVideoId") != v["id"]
        need_hide = v.get("visibility") != "hidden" and not args.no_hide
        need_trash = args.trash_duplicates and others

        steps = []
        for u in stale:
            steps.append(("UNLINK " + fmt(u), "PUT", f"/assets/{u['id']}", {"livePhotoVideoId": None}))
        if need_link:
            desc = f"LINK   {fmt(best)} <- {fmt(v)} dt={diff:.1f}s"
            steps.append((desc, "PUT", f"/assets/{best['id']}", {"livePhotoVideoId": v["id"]}))
        if need_hide:
            steps.append(("HIDE   " + fmt(v), "PUT", f"/assets/{v['id']}", {"visibility": "hidden"}))
        if need_trash:
            desc = "TRASH  " + ", ".join(fmt(o) for o in others)
            body = {"ids": [o["id"] for o in others], "force": False}
            steps.append((desc, "DELETE", "/assets", body))
        if steps:
            plans.append((v, steps))
    return plans


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--url", default=os.environ.get("IMMICH_URL", "http://localhost:2283"))
    ap.add_argument("--api-key", default=os.environ.get("IMMICH_API_KEY"))
    ap.add_argument("--apply", action="store_true", help="actually change things (default: dry run)")
    ap.add_argument("--tolerance", type=float, default=3.0, help="max capture time difference in seconds")
    ap.add_argument("--limit", type=int, default=0, help="only process the first N changes (for testing)")
    ap.add_argument("--no-hide", action="store_true", help="don't hide the video asset")
    ap.add_argument("--trash-duplicates", action="store_true", help="move smaller same-name duplicates to the trash")
    args = ap.parse_args()
    if not args.api_key:
        sys.exit("Set IMMICH_API_KEY or pass --api-key")

    print("Fetching assets...", file=sys.stderr)
    images = fetch_all(args.url, args.api_key, "IMAGE", True)
    videos = fetch_all(args.url, args.api_key, "VIDEO")

    plans = build_plans(images, videos, args)
    print(f"\n{len(plans)} videos need changes", file=sys.stderr)
    if args.limit:
        plans = plans[: args.limit]

    for i, (video, steps) in enumerate(plans, 1):
        print(f"[{i}/{len(plans)}] {video['originalFileName']}")
        for desc, method, path, body in steps:
            if not args.apply:
                print("  DRY  " + desc)
                continue
            try:
                api(args.url, args.api_key, method, path, body)
                print("  OK   " + desc)
            except RuntimeError as e:
                print("  FAIL " + desc + f"\n       {e}", file=sys.stderr)
                break

    if not args.apply:
        print("\nDry run only. Re-run with --apply (try --limit 5 first).", file=sys.stderr)


if __name__ == "__main__":
    main()
