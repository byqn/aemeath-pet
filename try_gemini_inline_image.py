"""Can any Gemini chat model on the relay return an inline image? (image-capable upstreams
sometimes answer through /chat/completions with base64 image parts.)
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

MODELS = ["gemini-3-flash", "gemini-3.6-flash-high", "gemini-3.8-flash-high", "gemini-3.1-pro-low", "gemini-pro-agent"]


def post(payload, timeout=240):
    req = urllib.request.Request(
        BASE + "/chat/completions",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read()
    except urllib.error.HTTPError as e:
        return e.code, e.read(300)
    except Exception as e:
        return None, ("%s: %s" % (type(e).__name__, str(e)[:160])).encode()


for model in MODELS:
    prompt = "Generate an image of a single red apple on a plain white background and return it."
    status, raw = post({"model": model, "messages": [{"role": "user", "content": prompt}]})
    text = raw.decode("utf-8", "replace")
    print("%-24s -> %-5s %s" % (model, status, text[:150].replace("\n", " ")))

    saved = False
    if status == 200:
        try:
            body = json.loads(text)
            msg = ((body.get("choices") or [{}])[0]).get("message", {})
            parts = msg.get("images") or []
            for i, part in enumerate(parts):
                url = (part.get("image_url") or {}).get("url") if isinstance(part, dict) else None
                if url and url.startswith("data:"):
                    raw_img = base64.b64decode(url.split(",", 1)[1])
                    p = os.path.join(OUT, "gemini-chat-%s-%d.png" % (model, i))
                    with open(p, "wb") as f:
                        f.write(raw_img)
                    print("   saved", p, len(raw_img), "bytes")
                    saved = True
            if not saved and "data:image" in text:
                print("   note: base64 image marker present in content")
        except Exception as e:
            print("   parse note:", type(e).__name__, str(e)[:80])
    if saved:
        print("   ^^^ inline image route works via", model)
        break
