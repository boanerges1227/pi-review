#!/usr/bin/env python3
"""Download a pinned public local embedding model; exclude its cache from Git and incur no model API charges."""
from concurrent.futures import ThreadPoolExecutor
from pathlib import Path
import hashlib
import json
import subprocess

REPO = "Qdrant/all-MiniLM-L6-v2-onnx"
REVISION = "d13954661f83248295ba75c1ed411eef3b7b936e"
FILES = ("config.json", "model.onnx", "special_tokens_map.json", "tokenizer.json", "tokenizer_config.json", "vocab.txt")
ROOT = Path(__file__).resolve().parent.parent / "artifacts" / "embedding-cache"


def download(name):
    # Pin the revision, download to temporary files, and replace atomically on success so models cannot load partial files.
    target = ROOT / "hub" / ("models--" + REPO.replace("/", "--")) / "snapshots" / REVISION / name
    target.parent.mkdir(parents=True, exist_ok=True)
    if not target.exists():
        temp = target.with_suffix(target.suffix + ".partial")
        subprocess.run(["curl", "--fail", "--location", "--silent", "--show-error", "--retry", "2", "--max-time", "240", "https://huggingface.co/" + REPO + "/resolve/" + REVISION + "/" + name, "-o", str(temp)], check=True)
        temp.replace(target)
    return {"file": name, "bytes": target.stat().st_size, "sha256": hashlib.sha256(target.read_bytes()).hexdigest()}


def main():
    with ThreadPoolExecutor(max_workers=3) as pool:
        manifest = list(pool.map(download, FILES))
    ref = ROOT / "hub" / ("models--" + REPO.replace("/", "--")) / "refs" / "main"
    ref.parent.mkdir(parents=True, exist_ok=True)
    ref.write_text(REVISION)
    (ROOT / "manifest.json").write_text(json.dumps({"repo": REPO, "revision": REVISION, "files": manifest}, indent=2))
    print("EMBEDDING_CACHE_READY", sum(x["bytes"] for x in manifest), "bytes")


if __name__ == "__main__":
    main()
