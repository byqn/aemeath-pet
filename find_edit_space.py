"""Find a public HF Space that can do image-to-image / instruction editing (needed to ground
each animation row on the canonical base). Probes the running state and API signature.
"""
import json
import urllib.error
import urllib.parse
import urllib.request

QUERIES = ["kontext", "qwen-image-edit", "flux img2img", "sd img2img", "image edit"]

seen = []
for q in QUERIES:
    url = "https://huggingface.co/api/spaces?" + urllib.parse.urlencode({
        "search": q, "sort": "likes", "direction": -1, "limit": 12,
    })
    try:
        with urllib.request.urlopen(url, timeout=40) as r:
            data = json.load(r)
    except Exception as e:
        print("search '%s' failed: %s %s" % (q, type(e).__name__, str(e)[:100]))
        continue
    for item in data:
        sid = item.get("id")
        if sid and sid not in [s[0] for s in seen]:
            seen.append((sid, item.get("likes", 0), item.get("sdk")))

print("candidate spaces:", len(seen))
for sid, likes, sdk in sorted(seen, key=lambda x: -x[1])[:18]:
    sub = sid.replace("/", "-").replace(".", "-").lower()
    try:
        with urllib.request.urlopen("https://%s.hf.space/gradio_api/info" % sub, timeout=20) as r:
            info = json.load(r)
        eps = {}
        for name, ep in list(info.get("named_endpoints", {}).items())[:6]:
            eps[name] = [p.get("parameter_name") for p in ep.get("parameters", [])]
        print("  OK  %-50s likes=%-5s %s" % (sid, likes, json.dumps(eps)[:220]))
    except urllib.error.HTTPError as e:
        print("  --  %-50s likes=%-5s HTTP %s" % (sid, likes, e.code))
    except Exception as e:
        print("  --  %-50s likes=%-5s %s" % (sid, likes, type(e).__name__))
