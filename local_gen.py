"""Local sprite-frame generator (deviation from hatch-pet's $imagegen contract, chosen because
every API route is down and the user asked for the pet by any means).

Method: img2img from the canonical base sprite with tiny-sd on CPU, one image per animation frame.
Output: aemeath-pet/hfrun/local-raw/<state>-<NN>.png
"""
import argparse
import os
import time

import torch
from PIL import Image
from diffusers import AutoPipelineForImage2Image

ROOT = r"C:\Users\32022\Desktop\000\aemeath-pet"
MODEL = os.path.join(ROOT, "models", "tiny-sd")
BASE = os.path.join(ROOT, "hfrun", "base-a1.webp")
OUT = os.path.join(ROOT, "hfrun", "local-raw")

W, H = 512, 768

IDENTITY = ("chibi 3d toy mascot of a heroic anime girl, silver lilac hair, navy and white outfit with "
            "glowing cyan accents, big blue eyes, full body, centered, flat solid magenta background")

STATES = {
    "idle": (6, "standing calmly in a relaxed idle pose, {var}"),
    "running-right": (8, "running to the right, side view, legs mid stride, arms swinging, {var}"),
    "waving": (4, "waving one hand raised in greeting, smiling, {var}"),
    "jumping": (5, "jumping in the air, both feet off the ground, arms lifted, {var}"),
    "failed": (8, "sad and disappointed, shoulders drooping, looking down, {var}"),
    "waiting": (6, "waiting expectantly with hands together, looking at the viewer, {var}"),
    "running": (6, "focused on work, leaning forward, hands typing in front of her, {var}"),
    "review": (6, "reviewing something closely, one hand on her chin, focused eyes, {var}"),
}

VARS = [
    "frame 1 of the loop", "frame 2 of the loop, slight head bob", "frame 3 of the loop, tiny blink",
    "frame 4 of the loop, body slightly lower", "frame 5 of the loop, hair moving a little",
    "frame 6 of the loop, nearly back to start", "frame 7 of the loop, small weight shift",
    "frame 8 of the loop, returning to start",
]

LOOKS = {
    "look-000": "head tilted up, eyes looking up at the sky",
    "look-022": "head tilted up and slightly to the right, eyes looking up right",
    "look-045": "head turned up and to the right, eyes looking up right",
    "look-067": "head turned mostly to the right with a slight upward tilt, eyes looking right",
    "look-090": "head turned to the right, eyes looking straight to the right side",
    "look-112": "head turned to the right and slightly down, eyes looking down right",
    "look-135": "head turned down and to the right, eyes looking down right",
    "look-157": "head tilted down and slightly right, eyes looking down right",
    "look-180": "head tilted down, eyes looking down at the ground",
    "look-202": "head tilted down and slightly left, eyes looking down left",
    "look-225": "head turned down and to the left, eyes looking down left",
    "look-247": "head turned mostly to the left with a slight downward tilt, eyes looking left",
    "look-270": "head turned to the left, eyes looking straight to the left side",
    "look-292": "head turned to the left and slightly up, eyes looking up left",
    "look-315": "head turned up and to the left, eyes looking up left",
    "look-337": "head tilted up and slightly left, eyes looking up left",
}

NEG = "watermark, text, signature, logo, multiple characters, cropped, extra limbs, shadow, scenery"


def build_jobs(only=None):
    jobs = []
    for state, (count, template) in STATES.items():
        for i in range(count):
            jobs.append({
                "name": "%s-%02d" % (state, i),
                "state": state,
                "prompt": "%s, %s" % (IDENTITY, template.format(var=VARS[i % len(VARS)])),
                "seed": 1000 + i * 7 + abs(hash(state)) % 997,
            })
    for key, look in LOOKS.items():
        jobs.append({
            "name": key,
            "state": key,
            "prompt": "%s, %s" % (IDENTITY, look),
            "seed": 5000 + abs(hash(key)) % 997,
        })
    if only:
        keep = set(only.split(","))
        jobs = [j for j in jobs if j["state"] in keep or j["name"] in keep]
    return jobs


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--only", default=None)
    ap.add_argument("--strength", type=float, default=0.42)
    ap.add_argument("--steps", type=int, default=2)
    ap.add_argument("--guidance", type=float, default=0.0)
    args = ap.parse_args()

    os.makedirs(OUT, exist_ok=True)
    print("loading pipeline from", MODEL)
    pipe = AutoPipelineForImage2Image.from_pretrained(MODEL, torch_dtype=torch.float32, safety_checker=None)
    pipe.set_progress_bar_config(disable=True)
    pipe.to("cpu")

    init = Image.open(BASE).convert("RGB").resize((W, H), Image.LANCZOS)
    init_path = os.path.join(OUT, "_init.png")
    init.save(init_path)

    jobs = build_jobs(args.only)
    print("jobs:", len(jobs))
    t_all = time.time()
    for i, job in enumerate(jobs, 1):
        dst = os.path.join(OUT, job["name"] + ".png")
        if os.path.exists(dst):
            print("  [%d/%d] %s exists, skip" % (i, len(jobs), job["name"]))
            continue
        t0 = time.time()
        gen = torch.Generator(device="cpu").manual_seed(job["seed"])
        image = pipe(prompt=job["prompt"], negative_prompt=NEG, image=init, strength=args.strength,
                     num_inference_steps=args.steps, guidance_scale=args.guidance, generator=gen).images[0]
        image.save(dst)
        print("  [%d/%d] %-16s %.1fs" % (i, len(jobs), job["name"], time.time() - t0), flush=True)
    print("total %.1f min" % ((time.time() - t_all) / 60))


if __name__ == "__main__":
    main()
