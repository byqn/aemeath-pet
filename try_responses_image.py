"""Try the Codex-style route: /v1/responses with an image_generation tool.
The relay's 503 hinted it proxies gpt-image-2 through a "codex" provider, which is exactly
this plumbing, so test it with the authenticated key.
"""
import base64
import json
import os
import urllib.error
import urllib.request

BASE = "https://fan.chuyang.asia/v1"
key = os.environ["PROBE_KEY"]
OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\planb"
os.makedirs(OUT, exist_ok=True)


def post(path, payload, timeout=300):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read(400)
    except Exception as e:
        return None, ("%s: %s" % (type(e).__name__, str(e)[:180])).encode()


def scan_images(raw, tag):
    try:
        body = json.loads(raw.decode("utf-8", "replace"))
    except Exception:
        return False
    found = False

    def walk(node):
        nonlocal found
        if isinstance(node, dict):
            if node.get("type") in ("image_generation_call", "output_image") and node.get("result"):
                data = node["result"]
                try:
                    raw_img = base64.b64decode(data)
                except Exception:
                    return
                p = os.path.join(OUT, "%s.png" % tag)
                with open(p, "wb") as f:
                    f.write(raw_img)
                print("   saved", p, len(raw_img), "bytes")
                found = True
            for v in node.values():
                walk(v)
        elif isinstance(node, list):
            for v in node:
                walk(v)

    walk(body)
    if not found:
        print("   no image payload; top-level keys:", list(body.keys())[:8])
    return found


for model in ("gpt-5.5", "gpt-6-astra", "gpt-5.6-sol"):
    payload = {
        "model": model,
        "input": "Generate one image: a single small red apple centered on a plain white background.",
        "tools": [{"type": "image_generation", "size": "1024x1024"}],
    }
    status, raw = post("/responses", payload)
    print("%-12s -> %s | %s" % (model, status, raw[:180].decode("utf-8", "replace").replace("\n", " ")))
    if status == 200 and scan_images(raw, "responses-%s" % model):
        print("   ^^^ IMAGE ROUTE WORKS via /responses + image_generation tool")
        break
