"""Try an anonymous call to a public Hugging Face Space (FLUX.1-schnell) and save the result.

If anonymous access is refused, print the exact reason so we know whether a token is required.
"""
import os
import shutil
import traceback

from gradio_client import Client

OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\sweep"
os.makedirs(OUT, exist_ok=True)

PROMPT = ("chibi full body desktop pet sprite of a heroic anime heroine inspired by Wuthering Waves Aemeath: "
          "compact small figure, silver-lilac layered hair with a long side sweep, porcelain skin, "
          "navy and white outfit with cyan luminous accents, small geometric energy ornament at the shoulder, "
          "calm determined face, big expressive eyes, stylized 3d-toy soft clay mascot rendering, smooth rounded forms, "
          "crisp edges, one centered standing pose, feet on the ground, arms relaxed, no weapon, no text, no logo, "
          "no shadow, entire background is one perfectly flat solid magenta #FF00FF color, no scenery, no props, no glow")

SPACES = ["black-forest-labs/FLUX.1-schnell", "Qwen/Qwen-Image", "multimodalart/FLUX.1-merged"]

for space in SPACES:
    print("== %s ==" % space)
    try:
        client = Client(space)
        if space == "Qwen/Qwen-Image":
            result = client.predict(prompt=PROMPT, seed=42, randomize_seed=False, aspect_ratio="2:3",
                                    guidance_scale=4, num_inference_steps=20, prompt_enhance=False, api_name="/infer")
        else:
            result = client.predict(prompt=PROMPT, seed=42, randomize_seed=False, width=1024, height=1536,
                                    num_inference_steps=4, api_name="/infer")
        print("   raw result:", result)
        path = result[0] if isinstance(result, (list, tuple)) else result
        if isinstance(path, dict):
            path = path.get("path") or path.get("url")
        if path and os.path.exists(str(path)):
            dst = os.path.join(OUT, "hf-%s.png" % space.replace("/", "-").replace(".", "-").lower())
            shutil.copy(str(path), dst)
            print("   SAVED", dst, os.path.getsize(dst), "bytes")
            break
        print("   no local file in result")
    except Exception as e:
        print("   FAIL", type(e).__name__, str(e)[:400])
        traceback.print_exc(limit=1)
