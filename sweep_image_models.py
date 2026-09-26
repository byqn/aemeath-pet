"""Sweep image-model aliases on the relay: some gateways accept model ids that are not
listed in /v1/models and route them to a working upstream.
"""
import json
import os
import time
import urllib.error
import urllib.request

BASE = "https://fan.chuyang.asia/v1"
key = os.environ["PROBE_KEY"]

CANDIDATES = [
    "gpt-image-1", "gpt-image-1.5", "gpt-image-1-mini", "dall-e-3", "dall-e-2",
    "flux", "flux-pro", "flux-schnell", "flux-kontext-pro",
    "seedream-3.0", "seedream-4.0", "qwen-image", "imagen-3.0", "imagen-4.0",
    "sora-image", "gpt-4o-image", "nano-banana", "gemini-2.5-flash-image",
]


def post(payload, timeout=120):
    req = urllib.request.Request(
        BASE + "/images/generations",
        data=json.dumps(payload).encode(),
        headers={"Content-Type": "application/json", "Authorization": "Bearer " + key},
        method="POST",
    )
    try:
        with urllib.request.urlopen(req, timeout=timeout) as r:
            return r.status, r.read(200).decode("utf-8", "replace")
    except urllib.error.HTTPError as e:
        return e.code, e.read(220).decode("utf-8", "replace")
    except Exception as e:
        return None, "%s: %s" % (type(e).__name__, str(e)[:120])


for model in CANDIDATES:
    status, detail = post({"model": model, "prompt": "a red apple on white", "size": "1024x1024", "n": 1})
    detail = detail.replace("\n", " ")[:150]
    print("%-24s %-6s %s" % (model, status, detail))
    if status == 200:
        print("   ^^^ WORKING IMAGE ROUTE:", model)
        break
    time.sleep(1)
