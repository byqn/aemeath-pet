"""Find HF Spaces that run on free CPU hardware (no ZeroGPU quota) and can generate or edit images.
ZeroGPU quota is exhausted, so CPU spaces are the only unauthenticated GPU-free path on HF.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

QUERIES = ["stable diffusion", "img2img", "text to image", "anime image generator", "sprite"]
spaces = {}
for q in QUERIES:
    url = "https://huggingface.co/api/spaces?" + urllib.parse.urlencode({
        "search": q, "sort": "likes", "direction": -1, "limit": 40, "full": "true",
    })
    try:
        with urllib.request.urlopen(url, timeout=40) as r:
            data = json.load(r)
    except Exception as e:
        print("search '%s' failed: %s" % (q, type(e).__name__))
        continue
    for item in data:
        hw = (item.get("runtime") or {}).get("hardware", {})
        stage = (item.get("runtime") or {}).get("stage")
        spaces[item["id"]] = (item.get("likes", 0), json.dumps(hw)[:40], stage)

cpu = [(sid, likes, hw, stage) for sid, (likes, hw, stage) in spaces.items()
       if "cpu" in hw.lower()]
print("candidates on CPU hardware:", len(cpu))
for sid, likes, hw, stage in sorted(cpu, key=lambda x: -x[1])[:15]:
    sub = sid.replace("/", "-").replace(".", "-").lower()
    try:
        with urllib.request.urlopen("https://%s.hf.space/gradio_api/info" % sub, timeout=20) as r:
            info = json.load(r)
        eps = {n: [p.get("parameter_name") for p in e.get("parameters", [])][:6]
               for n, e in list(info.get("named_endpoints", {}).items())[:4]}
        print("  OK  %-45s likes=%-5s %-14s %s" % (sid, likes, hw, json.dumps(eps)[:170]))
    except Exception as e:
        print("  --  %-45s likes=%-5s %-14s %s" % (sid, likes, hw, type(e).__name__))
