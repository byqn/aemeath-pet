"""Broad sweep for ANY reachable image generator that can produce a flat-background sprite:
 - Pollinations model variants (flux / turbo / kontext / sana) with a magenta-background prompt
 - Hugging Face Space availability probes (public gradio API surface)
Saves whatever comes back so quality can be judged from real files.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\sweep"
os.makedirs(OUT, exist_ok=True)

PROMPT = ("solid flat pure magenta background #FF00FF filling the entire background, no gradient, no shadow, "
          "chibi full-body anime heroine mascot, silver lilac hair with long side sweep, navy and white outfit "
          "with cyan glowing accents, stylized 3d toy soft clay render, centered single standing pose, "
          "no text, no watermark, no scenery")

results = []

for model in ("flux", "turbo", "kontext", "sana", "gptimage"):
    q = {"width": 1024, "height": 1536, "nologo": "true", "seed": 11, "model": model}
    url = "https://image.pollinations.ai/prompt/%s?%s" % (urllib.parse.quote(PROMPT), urllib.parse.urlencode(q))
    try:
        with urllib.request.urlopen(url, timeout=180) as r:
            data = r.read()
            ctype = r.headers.get("Content-Type", "")
            path = os.path.join(OUT, "pollinations-%s.jpg" % model)
            with open(path, "wb") as f:
                f.write(data)
            results.append((model, r.status, ctype, len(data), path))
            print("%-10s HTTP %s | %-12s | %7d bytes -> %s" % (model, r.status, ctype, len(data), os.path.basename(path)))
    except urllib.error.HTTPError as e:
        print("%-10s HTTP %s | %s" % (model, e.code, e.read(160).decode("utf-8", "replace").replace("\n", " ")[:130]))
    except Exception as e:
        print("%-10s FAIL %s %s" % (model, type(e).__name__, str(e)[:120]))

print()
SPACES = [
    "black-forest-labs/FLUX.1-schnell",
    "multimodalart/FLUX.1-merged",
    "stabilityai/stable-diffusion-3.5-large-turbo",
    "Qwen/Qwen-Image",
]
for space in SPACES:
    sub = space.replace("/", "-").replace(".", "-").lower()
    for path in ("/gradio_api/info", "/config"):
        url = "https://%s.hf.space%s" % (sub, path)
        try:
            with urllib.request.urlopen(url, timeout=25) as r:
                body = r.read(200).decode("utf-8", "replace")
                print("%-45s %-18s HTTP %s | %s" % (space, path, r.status, body[:90].replace("\n", " ")))
                break
        except urllib.error.HTTPError as e:
            print("%-45s %-18s HTTP %s" % (space, path, e.code))
        except Exception as e:
            print("%-45s %-18s FAIL %s" % (space, path, type(e).__name__))
