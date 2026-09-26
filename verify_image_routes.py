"""The key authenticates on the relay, but /images/generations with gpt-image-2 returns
503 "auth_not_found ... providers=codex". Probe the other image model and retry, to see
whether any image route has a live upstream right now.
"""
import base64
import json
import os
import time
import urllib.error
import urllib.request

BASE = "https://fan.chuyang.asia/v1"
key = os.environ["PROBE_KEY"]
OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\planb"


def post(path, payload, timeout=240):
    req = urllib.request.Request(
        BASE + path,
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, json.load(r)
    except urllib.error.HTTPError as e:
        return e.code, e.read(400).decode("utf-8", "replace")
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, str(e)[:200])


os.makedirs(OUT, exist_ok=True)


def save(items, name):
    if not items:
        return
    item = items[0]
    if item.get("b64_json"):
        raw = base64.b64decode(item["b64_json"])
        p = os.path.join(OUT, name)
        with open(p, "wb") as f:
            f.write(raw)
        print("   saved", p, len(raw), "bytes")
    elif item.get("url"):
        print("   url:", item["url"][:180])


print("== retry gpt-image-2 (x2) ==")
for i in (1, 2):
    status, body = post("/images/generations", {"model": "gpt-image-2", "prompt": "a single red apple on plain white background", "size": "1024x1024", "n": 1})
    print("  try %d -> %s | %s" % (i, status, str(body)[:220]))
    if status == 200 and isinstance(body, dict):
        save(body.get("data"), "keycheck-gptimage2.png")
    time.sleep(3)

print("== gemini-3.1-flash-image via /images/generations ==")
status, body = post("/images/generations", {"model": "gemini-3.1-flash-image", "prompt": "a single red apple on plain white background", "size": "1024x1024", "n": 1})
print("  ->", status, "|", str(body)[:260])
if status == 200 and isinstance(body, dict):
    save(body.get("data"), "keycheck-gemini-image.png")

print("== gemini-3.1-flash-image via /chat/completions ==")
status, body = post("/chat/completions", {"model": "gemini-3.1-flash-image",
                                          "messages": [{"role": "user", "content": "Generate an image of a single red apple on a plain white background."}]})
print("  ->", status)
if isinstance(body, dict):
    choice = (body.get("choices") or [{}])[0]
    msg = choice.get("message", {})
    print("   keys:", list(body.keys()), "| message keys:", list(msg.keys()))
    print("   content head:", str(msg.get("content"))[:200])
    imgs = msg.get("images") or []
    if imgs:
        print("   images:", len(imgs))
        for i, im in enumerate(imgs[:1]):
            url = (im.get("image_url") or {}).get("url") if isinstance(im, dict) else None
            if url and url.startswith("data:"):
                b64 = url.split(",", 1)[1]
                raw = base64.b64decode(b64)
                p = os.path.join(OUT, "keycheck-gemini-chat-%d.png" % i)
                with open(p, "wb") as f:
                    f.write(raw)
                print("   saved", p, len(raw), "bytes")
            else:
                print("   url:", str(url)[:180])
else:
    print("   ", str(body)[:260])
