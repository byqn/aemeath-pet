"""Build the real base sprite on FLUX.1-schnell, then test grounded row generation on
FLUX.1-Kontext-Dev and Qwen-Image-Edit-2511.

Everything lands in aemeath-pet/hfrun/ for visual review.
"""
import os
import shutil
import time

from gradio_client import Client

OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\hfrun"
os.makedirs(OUT, exist_ok=True)

IDENTITY = ("chibi full body desktop pet sprite of a heroic anime heroine: compact small figure, "
            "silver-lilac layered hair with a long side sweep, porcelain skin, big expressive blue eyes, "
            "navy and white armored outfit with glowing cyan gem accents, small geometric cyan ornament at the shoulder, "
            "calm determined face, stylized 3d-toy soft clay mascot rendering, smooth rounded forms, crisp edges, "
            "one centered standing pose facing the viewer, arms relaxed at the sides, feet together")

BASE_PROMPT_A = (IDENTITY + ", no weapon, no text, no logo, no watermark, "
                 "absolutely no shadow on the ground and no shadow under the feet, no floating parts, "
                 "the entire background is one flat single-color magenta pink (#DB3383) with no gradient, "
                 "no scenery, no props")

BASE_PROMPT_B = (IDENTITY + ", no weapon, no text, no logo, no watermark, standing on nothing, "
                 "no ground shadow, no contact shadow, no floating parts, "
                 "background is flat solid magenta #FF00FF chroma key color, uniform, no gradient")


def save_result(result, name):
    path = result[0] if isinstance(result, (list, tuple)) else result
    if isinstance(path, dict):
        path = path.get("path") or path.get("url")
    if path and os.path.exists(str(path)):
        dst = os.path.join(OUT, name)
        shutil.copy(str(path), dst)
        print("   saved", dst, os.path.getsize(dst), "bytes")
        return dst
    print("   no file:", str(result)[:200])
    return None


print("== base candidates (FLUX.1-schnell) ==")
flux = Client("black-forest-labs/FLUX.1-schnell")
bases = []
for tag, prompt, seed in (("a1", BASE_PROMPT_A, 42), ("a2", BASE_PROMPT_A, 777), ("b1", BASE_PROMPT_B, 42)):
    try:
        t0 = time.time()
        res = flux.predict(prompt=prompt, seed=seed, randomize_seed=False, width=1024, height=1536,
                           num_inference_steps=4, api_name="/infer")
        print("  base %s (%.1fs)" % (tag, time.time() - t0))
        p = save_result(res, "base-%s.webp" % tag)
        if p:
            bases.append(p)
    except Exception as e:
        print("  base %s FAIL %s %s" % (tag, type(e).__name__, str(e)[:160]))

ROW_PROMPT = ("Keep this exact same character, same face, same hair, same outfit, same colors, same art style, "
              "same flat magenta background. Show the character in 6 different frames of a calm idle animation "
              "arranged left to right in one horizontal row: subtle breathing, tiny blink, small head bob. "
              "Each frame is a complete full-body character, evenly spaced, not touching, not overlapping, "
              "same size and same baseline in every frame. No text, no numbers, no borders, no shadows.")

if bases:
    src = bases[0]
    print("== grounded row test on FLUX.1-Kontext-Dev (input %s) ==" % os.path.basename(src))
    try:
        kontext = Client("black-forest-labs/FLUX.1-Kontext-Dev")
        res = kontext.predict(input_image=src, prompt=ROW_PROMPT, seed=1, randomize_seed=False,
                              guidance_scale=2.5, steps=28, api_name="/infer")
        save_result(res, "row-idle-kontext.webp")
    except Exception as e:
        print("   kontext FAIL", type(e).__name__, str(e)[:200])

    print("== grounded row test on Qwen-Image-Edit-2511 (2048x768) ==")
    try:
        qwen = Client("Qwen/Qwen-Image-Edit-2511")
        res = qwen.predict(images=[src], prompt=ROW_PROMPT, seed=1, randomize_seed=False,
                           true_guidance_scale=4, num_inference_steps=20, height=768, width=2048,
                           rewrite_prompt=False, api_name="/infer")
        save_result(res, "row-idle-qwen.webp")
    except Exception as e:
        print("   qwen FAIL", type(e).__name__, str(e)[:200])
