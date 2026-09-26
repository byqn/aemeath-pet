"""Chunked, resumable, multi-connection downloader for the tiny-sd weights.

The plain huggingface_hub download stalled on this link, so fetch the three weight files in
ranged chunks with retries and a few parallel connections.
"""
import os
import sys
import threading
import time
import urllib.error
import urllib.request

DEST = r"C:\Users\32022\Desktop\000\aemeath-pet\models\tiny-sd"
REPO = "segmind/tiny-sd"
MIRRORS = ["https://hf-mirror.com", "https://huggingface.co"]

FILES = [
    "text_encoder/pytorch_model.bin",
    "unet/diffusion_pytorch_model.bin",
    "vae/diffusion_pytorch_model.bin",
]

CHUNK = 4 * 1024 * 1024
CONNECTIONS = 3
RETRIES = 6

lock = threading.Lock()
done_bytes = [0]


def fetch_chunk(url, start, end, timeout=90):
    req = urllib.request.Request(url, headers={"User-Agent": "chunkdl/1.0", "Range": "bytes=%d-%d" % (start, end)})
    for attempt in range(RETRIES):
        try:
            with urllib.request.urlopen(req, timeout=timeout) as r:
                return r.read()
        except Exception:
            time.sleep(1.5 * (attempt + 1))
    return None


def download(rel):
    target = os.path.join(DEST, rel.replace("/", os.sep))
    os.makedirs(os.path.dirname(target), exist_ok=True)
    tmp = target + ".part"

    url = None
    size = None
    for base in MIRRORS:
        try:
            req = urllib.request.Request(base + "/" + REPO + "/resolve/main/" + rel, method="HEAD",
                                         headers={"User-Agent": "chunkdl/1.0"})
            with urllib.request.urlopen(req, timeout=40) as r:
                size = int(r.headers.get("Content-Length") or 0)
                url = base + "/" + REPO + "/resolve/main/" + rel
                if size:
                    break
        except Exception as e:
            print("  head failed on %s: %s" % (base, type(e).__name__), flush=True)
    if not url or not size:
        print("  cannot resolve", rel, flush=True)
        return False

    have = os.path.getsize(tmp) if os.path.exists(tmp) else 0
    print("  %s: %.1f MB, resuming from %.1f MB" % (rel, size / 1e6, have / 1e6), flush=True)

    pieces = []
    start = have
    while start < size:
        end = min(start + CHUNK - 1, size - 1)
        pieces.append((start, end))
        start = end + 1

    results = [None] * len(pieces)

    def worker(indices):
        for i in indices:
            s, e = pieces[i]
            data = fetch_chunk(url, s, e)
            if data is None:
                print("    chunk %d failed permanently" % i, flush=True)
                results[i] = b""
                continue
            results[i] = data
            with lock:
                done_bytes[0] += len(data)

    threads = []
    for k in range(CONNECTIONS):
        t = threading.Thread(target=worker, args=(range(k, len(pieces), CONNECTIONS),))
        t.start()
        threads.append(t)
    t0 = time.time()
    while any(t.is_alive() for t in threads):
        time.sleep(6)
        with lock:
            got = done_bytes[0]
        print("    %s: %.1f MB downloaded (%.2f MB/s)" % (rel, got / 1e6, got / 1e6 / max(time.time() - t0, 1)), flush=True)
    for t in threads:
        t.join()

    if any(r == b"" for r in results):
        print("  incomplete, will retry next run:", rel, flush=True)
        with open(tmp, "ab") as f:
            for r in results:
                if r:
                    f.write(r)
        return False

    with open(tmp, "wb") as f:
        for i, (s, e) in enumerate(pieces):
            f.write(results[i])
    os.replace(tmp, target)
    print("  done", rel, "%.1f MB in %.1f min" % (size / 1e6, (time.time() - t0) / 60), flush=True)
    return True


total_ok = True
for rel in FILES:
    if os.path.exists(os.path.join(DEST, rel.replace("/", os.sep))):
        print("already have", rel, flush=True)
        continue
    ok = download(rel)
    total_ok = total_ok and ok

print("ALL DONE" if total_ok else "PARTIAL")
