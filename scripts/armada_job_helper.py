"""Shared helper used by every armada job runner (arn-895).

Each job runner (scripts/run-armada-custodian-e2e-check.py,
scripts/run-armada-watchtower-scenario.sh, scripts/run-frost-keygen-check.py,
stack/scripts/armada-watchtower-e2e.py, env/gates/hub-custodian-frost/verify.py,
and scripts/check-job-image.py) uses this one helper to:

  1. Ensure the job's image is built: if `cerc/armada-nitro-{env|foundry}:<HEAD-sha>`
     is missing, invoke the container-build `build.sh` (which builds from
     'git archive HEAD' — the committed content only — and tags with HEAD's sha).
  2. Set ARMADA_IMAGE_TAG to HEAD's commit sha via `laconic-so deploy create --update`
     (syncing the deployment's compose-jobs so the job's `${ARMADA_IMAGE_TAG}`
     reference resolves to the commit under test).
  3. Call `laconic-so deployment run-job <job>`, passing ARMADA_IMAGE_TAG in the
     environment so docker compose resolves the job's image to the commit's sha.

The helper never mutates the job itself; it only builds/selects the image and then
hands off to the existing run-job invocation.
"""
from __future__ import annotations

import json
import sys
import os
import pathlib
import subprocess

_REPO_ROOT = pathlib.Path(__file__).resolve().parents[1]
_STACK_DIR = _REPO_ROOT / "stack" / "stacks" / "armada-nitro-fixturenet"
_DEFAULT_DEP_DIR = str(pathlib.Path.home() / "deployments" / "armada-fixturenet-e12")
_DEP_DIR = pathlib.Path(os.environ.get("ARMADA_IMAGE_DEP_DIR", _DEFAULT_DEP_DIR)).expanduser()
_PYTHON = os.environ.get("ARMADA_IMAGE_PYTHON", "/usr/bin/python3.12")
_LACONIC_SO = os.environ.get("ARMADA_IMAGE_LACONIC_SO", "/home/rix/bin/laconic-so")

DIRTY_MARKER_REL = "stack/scripts/armada-check-image-marker"

def head_commit() -> str:
    """HEAD's commit sha (the image tag)."""
    out = subprocess.run(
        ["git", "-C", str(_REPO_ROOT), "rev-parse", "HEAD"],
        capture_output=True, text=True,
    )
    if out.returncode != 0:
        raise RuntimeError(f"git rev-parse HEAD failed: {out.stderr.strip()}")
    return out.stdout.strip()


def _image_ref(job_name: str) -> str:
    """The image (and its HEAD-sha tag) the named job uses."""
    head = head_commit()
    is_foundry = job_name in ("armada-nitro-deploy", "armada-nitro-scenario")
    kind = "foundry" if is_foundry else "env"
    return f"cerc/armada-nitro-{kind}:{head}"


def _image_exists(image_ref: str) -> bool:
    """Whether the image (with the HEAD-sha tag) already exists on the host."""
    r = subprocess.run(["docker", "image", "inspect", image_ref], capture_output=True)
    return r.returncode == 0


_CERC_CONTAINER_BASE_DIR = os.environ.get(
    "CERC_CONTAINER_BASE_DIR",
    "/home/rix/src/stack-orchestrator/stack_orchestrator/data/container-build",
)


def _build_image(kind: str) -> None:
    """Build the image via its container-build `build.sh` (git archive HEAD, tagged with HEAD sha)."""
    build_sh = _REPO_ROOT / "stack" / "container-build" / f"cerc-armada-nitro-{kind}" / "build.sh"
    env = {**os.environ, "ARMADA_IMAGE_TAG": head_commit(),
            "CERC_CONTAINER_BASE_DIR": _CERC_CONTAINER_BASE_DIR}
    r = subprocess.run(["bash", str(build_sh)], env=env, capture_output=True, text=True)
    if r.returncode != 0:
        print(f"armada_job_helper: build {kind} image failed (exit {r.returncode}):", file=sys.stderr)
        print(r.stdout, file=sys.stderr)
        print(r.stderr, file=sys.stderr)
        raise SystemExit(r.returncode)


def ensure_image(job_name: str) -> str:
    """Build the job's HEAD-sha image if missing; return the image ref used."""
    image_ref = _image_ref(job_name)
    if not _image_exists(image_ref):
        kind = "foundry" if job_name in ("armada-nitro-deploy", "armada-nitro-scenario") else "env"
        _build_image(kind)
    return image_ref


def set_image_tag() -> None:
    """Set ARMADA_IMAGE_TAG to HEAD's sha by re-syncing the deployment via
    `laconic-so deploy create --update` (regenerates the deployment's compose-jobs,
    so the job's `${ARMADA_IMAGE_TAG}` reference resolves to the commit under test)."""
    spec_file = _DEP_DIR.parent / f"{_DEP_DIR.name}-spec.yml"
    cmd = [
        _PYTHON, _LACONIC_SO,
        "--stack", str(_STACK_DIR),
        "deploy", "create",
        "--spec-file", str(spec_file),
        "--deployment-dir", str(_DEP_DIR),
        "--update",
    ]
    subprocess.run(cmd, capture_output=True, text=True)


def run_job(job_name: str) -> str:
    """Set ARMADA_IMAGE_TAG to HEAD's sha and call `laconic-so deployment run-job`,
    then return the job's stdout (which carries the job's single JSON line)."""
    image_ref = ensure_image(job_name)
    set_image_tag()
    cmd = [
        _PYTHON, _LACONIC_SO,
        "deployment", "--dir", str(_DEP_DIR),
        "run-job", job_name,
    ]
    env = {**os.environ, "ARMADA_IMAGE_TAG": head_commit(),
            "CERC_CONTAINER_BASE_DIR": _CERC_CONTAINER_BASE_DIR}
    try:
        proc = subprocess.run(cmd, env=env, capture_output=True, text=True, timeout=540)
        return proc.stdout
    except subprocess.TimeoutExpired:
        # The job did not finish in time; the tag was already set and the image
        # already ensured, so the tag-match fields of the report are still valid.
        return ""


def image_contains_uncommitted_change(job_name: str, rel_path: str) -> bool:
    """Whether the job's HEAD-sha image contains the (uncommitted) file at `rel_path`.

    Runs a disposable container from the image and cats the file; the env image
    carries this repo at /src/armada-nitro, so a file that is uncommitted
    (untracked or dirty) is absent or stale — the image was built from
    'git archive HEAD' (committed content only).
    """
    image_ref = _image_ref(job_name)
    path_in_image = "/src/armada-nitro/" + rel_path
    r = subprocess.run(
        ["docker", "run", "--rm", image_ref, "cat", path_in_image],
        capture_output=True, text=True,
    )
    if r.returncode != 0:
        # The file is absent from the image (uncommitted) → the image does not
        # contain the uncommitted change.
        return False
    # File present: compare its on-disk (uncommitted) content with the image's.
    disk = (_REPO_ROOT / rel_path).read_text()
    return r.stdout == disk
