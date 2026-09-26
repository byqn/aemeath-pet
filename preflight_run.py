"""Read-only preflight for the Aemeath hatch-pet run.

Verifies that every job in imagegen-jobs.json has its prompt files, input images and
output directory present on disk, so generation can start the moment a valid key exists.
Writes nothing.
"""
import json
import os

RUN = r"C:\Users\32022\Desktop\000\aemeath-pet\work\aemeath-run"

with open(os.path.join(RUN, "imagegen-jobs.json"), "r", encoding="utf-8") as f:
    manifest = json.load(f)

with open(os.path.join(RUN, "pet_request.json"), "r", encoding="utf-8") as f:
    request = json.load(f)

print("pet_id:", request["pet_id"], "| atlas:", request["atlas"]["width"], "x", request["atlas"]["height"],
      "| chroma:", request["chroma_key"]["hex"])
print("jobs:", len(manifest["jobs"]))
print()

problems = []
for job in manifest["jobs"]:
    jid = job["id"]
    missing = []

    for field in ("prompt_file", "retry_prompt_file"):
        rel = job.get(field)
        if rel and not os.path.exists(os.path.join(RUN, rel)):
            missing.append(field + "=" + rel)

    for img in job.get("input_images", []):
        rel = img["path"]
        if rel == "references/canonical-base.png":
            continue  # produced after the base job completes
        if not os.path.exists(os.path.join(RUN, rel)):
            missing.append("input=" + rel)

    out = job["output_path"]
    outdir = os.path.dirname(os.path.join(RUN, out))
    if not os.path.isdir(outdir):
        missing.append("outdir=" + os.path.dirname(out))

    status = "OK" if not missing else "MISSING -> " + "; ".join(missing)
    print("%-14s %-18s deps=%-40s %s" % (jid, job["kind"], ",".join(job.get("depends_on", [])) or "-", status))
    if missing:
        problems.append(jid)

print()
print("preflight:", "PASS" if not problems else "FAIL for " + ",".join(problems))
print("canonical-base present:", os.path.exists(os.path.join(RUN, "references", "canonical-base.png")))
print("decoded/ contents:", sorted(os.listdir(os.path.join(RUN, "decoded"))) or "(empty)")
