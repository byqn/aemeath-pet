"""Plan-B prototype: render an Aemeath base sprite through the keyless public backend so the
user can judge quality. This is NOT the hatch-pet deliverable and is written to planb/ only.
"""
import json
import os
import urllib.error
import urllib.parse
import urllib.request

OUT_DIR = r"C:\Users\32022\Desktop\000\aemeath-pet\planb"
os.makedirs(OUT_DIR, exist_ok=True)

try:
    with urllib.request.urlopen("https://image.pollinations.ai/models", timeout=45) as r:
        print("models:", r.read(400).decode("utf-8", "replace").replace("\n", " ")[:350])
except Exception as e:
    print("models list failed:", type(e).__name__, str(e)[:120])

PROMPT = (
    "chibi full-body desktop pet sprite of a heroic anime heroine inspired by Wuthering Waves Aemeath: "
    "compact small figure, silver-lilac layered hair with a long side sweep, porcelain skin, navy and white outfit "
    "with cyan luminous accents, a small geometric energy ornament at the shoulder, calm determined face, big expressive eyes, "
    "stylized 3d-toy soft clay mascot rendering, smooth rounded forms, crisp edges, centered single standing pose, "
    "feet on ground, arms relaxed, no weapon, no text, no logo, no shadow, perfectly flat solid pure magenta #FF00FF background, "
    "no scenery, no props, no glow"
)

query = {
    "width": 1024,
    "height": 1536,
    "nologo": "true",
    "seed": 42,
    "model": "flux",
    "enhance": "false",
}
url = "https://image.pollinations.ai/prompt/%s?%s" % (urllib.parse.quote(PROMPT), urllib.parse.urlencode(query))

out = os.path.join(OUT_DIR, "base-prototype.png")
try:
    with urllib.request.urlopen(url, timeout=240) as r:
        data = r.read()
        with open(out, "wb") as f:
            f.write(data)
        print("generated: HTTP %s | %s | %d bytes -> %s" % (r.status, r.headers.get("Content-Type"), len(data), out))
except urllib.error.HTTPError as e:
    print("generate failed: HTTP %s | %s" % (e.code, e.read(200).decode("utf-8", "replace")[:180]))
except Exception as e:
    print("generate failed:", type(e).__name__, str(e)[:150])
