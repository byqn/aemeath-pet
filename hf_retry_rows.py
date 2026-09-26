"""Retry the grounded row generation with gradio_client's handle_file() upload helper,
which is required for local image inputs in gradio_client 2.x.
"""
import os
import shutil
import time

from gradio_client import Client, handle_file

OUT = r"C:\Users\32022\Desktop\000\aemeath-pet\hfrun"
BASE = os.path.join(OUT, "base-a1.webp")

ROW_PROMPT = ("Keep this exact same character: same face, same hair, same outfit, same colors, same art style, "
              "same flat magenta background. Show the character in 6 different frames of a calm idle animation, "
              "arranged left to right in one single horizontal row. Each frame shows the complete full-body character, "
              "evenly spaced, complete poses that do not touch or overlap, identical size and identical baseline. "
              "No text, no numbers, no borders, no shadows, no extra props.")


def save(result, name):
    path = result[0] if isinstance(result, (list, tuple)) else result
    if isinstance(path, dict):
        path = path.get("path") or path.get("url")
    if path and os.path.exists(str(path)):
        dst = os.path.join(OUT, name)
        shutil.copy(str(path), dst)
        print("   saved", dst, os.path.getsize(dst), "bytes")
        return dst
    print("   unexpected result:", str(result)[:250])
    return None


print("== FLUX.1-Kontext-Dev with handle_file ==")
try:
    t0 = time.time()
    kontext = Client("black-forest-labs/FLUX.1-Kontext-Dev")
    res = kontext.predict(input_image=handle_file(BASE), prompt=ROW_PROMPT, seed=1, randomize_seed=False,
                          guidance_scale=2.5, steps=28, api_name="/infer")
    print("   ok in %.1fs" % (time.time() - t0))
    save(res, "row-idle-kontext.webp")
except Exception as e:
    print("   FAIL", type(e).__name__, str(e)[:300])

print("== Qwen/Qwen-Image-Edit with handle_file ==")
try:
    t0 = time.time()
    qwen = Client("Qwen/Qwen-Image-Edit")
    res = qwen.predict(image=handle_file(BASE), prompt=ROW_PROMPT, seed=1, randomize_seed=False,
                       true_guidance_scale=4, num_inference_steps=20, rewrite_prompt=False, api_name="/infer")
    print("   ok in %.1fs" % (time.time() - t0))
    save(res, "row-idle-qwen.webp")
except Exception as e:
    print("   FAIL", type(e).__name__, str(e)[:300])

print("== quota check: one more schnell call ==")
try:
    flux = Client("black-forest-labs/FLUX.1-schnell")
    t0 = time.time()
    res = flux.predict(prompt="a single small red apple on a white background", seed=5, randomize_seed=False,
                       width=512, height=512, num_inference_steps=4, api_name="/infer")
    print("   schnell ok in %.1fs" % (time.time() - t0))
    save(res, "quota-check.webp")
except Exception as e:
    print("   schnell FAIL", type(e).__name__, str(e)[:200])
