"""Offline structural preflight for the Aemeath hatch-pet run.

This never calls imagegen or prints credentials. Exit 0 means the 13-job plan is coherent;
`ready_to_generate` separately reports whether OPENAI_API_KEY is present in this process.
"""
from __future__ import annotations

import argparse
import json
import os
import re
import sys
from pathlib import Path

ROOT = Path(__file__).resolve().parent
RUN = ROOT / "work" / "aemeath-run"
EXPECTED_JOBS = [
    "base", "idle", "running-right", "running-left", "waving", "jumping",
    "failed", "waiting", "running", "review", "look-cardinals",
    "look-row-9", "look-row-10",
]
STANDARD_ROWS = EXPECTED_JOBS[1:10]
EXPECTED_DIRECTIONS = [
    "000", "022.5", "045", "067.5", "090", "112.5", "135", "157.5",
    "180", "202.5", "225", "247.5", "270", "292.5", "315", "337.5",
]
SECRET_PATTERN = re.compile(r"\bsk-[A-Za-z0-9]{20,}\b")


def within(root: Path, relative: str) -> Path:
    candidate = (root / relative).resolve()
    candidate.relative_to(root.resolve())
    return candidate


def check() -> dict[str, object]:
    errors: list[str] = []
    warnings: list[str] = []
    manifest_path = RUN / "imagegen-jobs.json"
    request_path = RUN / "pet_request.json"
    if not manifest_path.is_file() or not request_path.is_file():
        return {
            "ok": False,
            "ready_to_generate": False,
            "errors": ["missing imagegen-jobs.json or pet_request.json"],
            "warnings": [],
        }

    try:
        manifest = json.loads(manifest_path.read_text(encoding="utf-8"))
        request = json.loads(request_path.read_text(encoding="utf-8"))
    except (OSError, json.JSONDecodeError) as exc:
        return {"ok": False, "ready_to_generate": False, "errors": [str(exc)], "warnings": []}

    jobs_list = manifest.get("jobs", [])
    jobs = {job.get("id"): job for job in jobs_list if isinstance(job, dict)}
    ids = [job.get("id") for job in jobs_list if isinstance(job, dict)]
    if len(jobs_list) != 13 or ids != EXPECTED_JOBS:
        errors.append("imagegen-jobs.json must contain the 13 expected jobs in canonical order")
    if len(ids) != len(set(ids)):
        errors.append("duplicate job ids found")

    try:
        recorded_run = Path(manifest.get("run_dir", "")).resolve()
        if recorded_run != RUN.resolve():
            errors.append("manifest run_dir does not match this workspace run directory")
    except (OSError, RuntimeError):
        errors.append("manifest run_dir cannot be resolved")

    producers: dict[str, str] = {}
    for job_id, job in jobs.items():
        output = job.get("output_path")
        if not isinstance(output, str):
            errors.append(f"{job_id}: output_path is missing")
            continue
        try:
            within(RUN, output)
        except (ValueError, OSError):
            errors.append(f"{job_id}: output_path escapes run directory")
        if output in producers:
            errors.append(f"duplicate output path: {output}")
        producers[output] = job_id

        prompt = job.get("prompt_file")
        if not isinstance(prompt, str):
            errors.append(f"{job_id}: prompt_file is missing")
        else:
            try:
                prompt_path = within(RUN, prompt)
                if not prompt_path.is_file():
                    errors.append(f"{job_id}: prompt file not found ({prompt})")
            except (ValueError, OSError):
                errors.append(f"{job_id}: prompt path escapes run directory")

        retry = job.get("retry_prompt_file")
        if retry:
            try:
                if not within(RUN, retry).is_file():
                    errors.append(f"{job_id}: retry prompt file not found ({retry})")
            except (ValueError, OSError):
                errors.append(f"{job_id}: retry prompt path escapes run directory")

        for repair in (job.get("repair_prompt_files") or {}).values():
            try:
                if not within(RUN, repair).is_file():
                    errors.append(f"{job_id}: repair prompt file not found ({repair})")
            except (ValueError, OSError):
                errors.append(f"{job_id}: repair prompt path escapes run directory")

        for dependency in job.get("depends_on", []):
            if dependency not in jobs:
                errors.append(f"{job_id}: unknown dependency {dependency}")

        for image in job.get("input_images", []):
            rel = image.get("path") if isinstance(image, dict) else None
            if not isinstance(rel, str):
                errors.append(f"{job_id}: malformed input_images entry")
                continue
            try:
                image_path = within(RUN, rel)
            except (ValueError, OSError):
                errors.append(f"{job_id}: input path escapes run directory ({rel})")
                continue
            if image_path.is_file():
                continue
            if rel in producers:
                continue
            if rel == "references/canonical-base.png":
                continue  # created only after base receives visual approval
            if rel == "decoded/look-anchors-approved.png":
                continue  # cardinal approval gate
            if rel == "qa/contact-sheet.png":
                continue  # produced by assemble_standard_pet.ps1 after all standard rows
            errors.append(f"{job_id}: unresolved input has no known producer ({rel})")

    # Detect dependency cycles without relying on a third-party graph package.
    visiting: set[str] = set()
    visited: set[str] = set()

    def visit(job_id: str) -> None:
        if job_id in visiting:
            errors.append(f"dependency cycle includes {job_id}")
            return
        if job_id in visited or job_id not in jobs:
            return
        visiting.add(job_id)
        for dependency in jobs[job_id].get("depends_on", []):
            visit(dependency)
        visiting.remove(job_id)
        visited.add(job_id)

    for job_id in jobs:
        visit(job_id)

    request_rows = {row.get("state"): row for row in request.get("rows", []) if isinstance(row, dict)}
    for state in STANDARD_ROWS:
        if state not in request_rows:
            errors.append(f"pet_request.json has no row metadata for {state}")
    look9 = request_rows.get("look-row-9", {}).get("directions", [])
    look10 = request_rows.get("look-row-10", {}).get("directions", [])
    if look9 + look10 != EXPECTED_DIRECTIONS:
        errors.append("look direction labels/order do not match the required 16 clockwise directions")
    chroma = (request.get("chroma_key") or {}).get("hex")
    if chroma != "#FF00FF":
        errors.append(f"expected #FF00FF chroma key, found {chroma!r}")

    for job_id, job in jobs.items():
        prompt = job.get("prompt_file")
        if not prompt:
            continue
        try:
            prompt_text = within(RUN, prompt).read_text(encoding="utf-8")
        except (OSError, ValueError):
            continue
        if chroma and chroma.lower() not in prompt_text.lower():
            errors.append(f"{job_id}: prompt does not mention the selected chroma key")

    secret_files: list[str] = []
    to_scan = [manifest_path, request_path]
    to_scan.extend(path for path in ROOT.glob("*.ps1"))
    to_scan.extend(path for path in ROOT.glob("*.py"))
    to_scan.extend(path for path in (RUN / "prompts").rglob("*.md"))
    for path in to_scan:
        try:
            if SECRET_PATTERN.search(path.read_text(encoding="utf-8", errors="ignore")):
                secret_files.append(str(path.relative_to(ROOT)))
        except OSError:
            continue
    if secret_files:
        errors.append("secret-like literal detected in workflow config, code, or prompt files: " + ", ".join(secret_files))

    key_present = bool(os.environ.get("OPENAI_API_KEY"))
    if not key_present:
        warnings.append("OPENAI_API_KEY is absent; CLI dry-runs work, image generation cannot start")

    completed = [job_id for job_id, job in jobs.items() if job.get("status") == "complete"]
    return {
        "ok": not errors,
        "ready_to_generate": not errors and key_present,
        "workspace": str(ROOT),
        "run_dir": str(RUN),
        "expected_job_order": EXPECTED_JOBS,
        "job_count": len(jobs_list),
        "completed_job_ids": completed,
        "chroma_key": chroma,
        "api_key_present": key_present,
        "secret_literal_files": secret_files,
        "errors": errors,
        "warnings": warnings,
    }


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--json-out", default=str(RUN / "qa" / "project-preflight.json"))
    args = parser.parse_args()
    result = check()
    output = Path(args.json_out).expanduser().resolve()
    output.parent.mkdir(parents=True, exist_ok=True)
    output.write_text(json.dumps(result, indent=2, ensure_ascii=False) + "\n", encoding="utf-8")
    print(json.dumps(result, indent=2, ensure_ascii=False))
    return 0 if result["ok"] else 1


if __name__ == "__main__":
    sys.exit(main())
