"""Download the smallest usable SD model (segmind/tiny-sd) using fp16 weights where available.
Runs against the China mirror endpoint and prints progress-friendly output.
"""
import json
import os
import sys
import time
import urllib.request

os.environ.setdefault("HF_ENDPOINT", "https://hf-mirror.com")

REPO = "segmind/tiny-sd"
DEST = r"C:\Users\32022\Desktop\000\aemeath-pet\models\tiny-sd"
os.makedirs(DEST, exist_ok=True)

with urllib.request.urlopen("https://huggingface.co/api/models/%s?blobs=true" % REPO, timeout=40) as r:
    data = json.load(r)

files = []
for s in data.get("siblings", []):
    name = s.get("rfilename", "")
    size = s.get("size") or 0
    if name.endswith((".safetensors", ".bin")):
        files.append((name, size))
print("weight files in repo:")
for name, size in files:
    print("   %-60s %7.1f MB" % (name, size / 1e6))

have_fp16 = {os.path.dirname(n): (n, s) for n, s in files if "fp16" in n}
chosen = []
for name, size in files:
    top = name.split("/")[0]
    if "fp16" in name:
        chosen.append(name)
    elif top not in have_fp16:
        chosen.append(name)

total = sum(s for n, s in files if n in chosen)
print("chosen files:", len(chosen), "total %.0f MB" % (total / 1e6))

from huggingface_hub import snapshot_download  # noqa: E402

patterns = ["*.json", "*.txt", "vocab.json", "merges.txt"] + chosen
t0 = time.time()
path = snapshot_download(repo_id=REPO, local_dir=DEST, allow_patterns=patterns, max_workers=4)
print("downloaded to", path, "in %.1f min" % ((time.time() - t0) / 60))
size = sum(os.path.getsize(os.path.join(dp, f)) for dp, _dn, fn in os.walk(DEST) for f in fn)
print("on-disk size: %.2f GB" % (size / 1e9))
