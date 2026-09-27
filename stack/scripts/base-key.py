#!/usr/bin/env python3
"""Print the fixturenet base-layer snapshot cache-key input lines.

Usage: base-key.py --root <REPO_ROOT>

Each line is `<kind> <label> <digest>` (or `image <ref> <id>`); the 16-hex cache
key is sha256 of all lines, truncated (see stack/scripts/fixturenet-base-common.sh).
The lines are normalised so that a commit which only reformats, re-comments or
re-whitespaces an input does NOT change the key -- only a change to what the base
chain actually deploys does. Sourced by fixturenet-base-common.sh; also written
verbatim into the auditable `.key` file beside each snapshot.

INCLUDED -- these determine the base chain's state (network + weth, usdc, cctp,
aave, lido, armada):

  image <ref> <id>
    - the chain images: ethereum/client-go, sigp/lighthouse,
      ethpandaops/ethereum-genesis-generator (from the fixturenet compose);
    - the `toolchain` env-image stage (base toolchain: foundry/node/yarn/just);
    - one `src-<name>` stage per env/sources.lock.json sources[] entry -- its
      image ID encodes that source's pin AND its build output, so the sources[]
      pins need no separate line here;
    - the `circuits` stage (Armada's pinned circuit build).
    NOT the whole env image and NOT the `contracts` stage: armada_nitro's own
    contracts are not part of the base chain, so recompiling them must not
    invalidate the base snapshot.

  pyast env/reconciler/**/*.py <sha>
    Hash of the file's AST with docstrings stripped -- the reconciler and every
    module as executed. Comments, formatting and docstrings do not change it.

  json <path> <sha>   canonical JSON (sorted keys, no whitespace), so reindenting
    or reordering keys does not change it:
    - env/targets/fixturenet-base.json          (the base target);
    - env/lido/steps-fixturenet.json            (the lido deploy step list);
    - env/sources.lock.json:non-sources         (weth9, armada-circuits; the
      sources[] pins are already covered by the src-<name> stage image IDs).

  toml env/lido/deploy-params-fixturenet.toml <sha>
    Parsed (tomllib) then canonical JSON.

  yaml <path> <sha>   parsed then canonical JSON:
    - stack/compose/docker-compose-armada-fixturenet.yml (the chain: image tags
      AND the genesis parameters -- chain id, forks, mnemonic, validators);
    - stack/compose-jobs/docker-compose-armada-env-reconcile.yml (the job).

  ts env/lido/0140-plug-staking-modules-via-vote.ts <sha>
    Prettier-normalised text (the repo's own node_modules prettier) -- the custom
    step lido runs during the deploy.

  raw <path> <sha>   any other (unknown-type) file inside an included directory,
    hashed by raw bytes as a fail-safe so a newly added input is never silently
    ignored.

EXCLUDED -- present but not part of the base chain's state:
  - env/reconciler modules for armada_nitro / funding still count above because the
    reconciler package is executed as a unit; but the FULL target
    (env/targets/fixturenet.json), which adds armada_nitro + funding, is excluded --
    only the base target determines the base chain.
  - env/lido/tools/**                          capture/dev tooling, not run by the deploy;
  - env/lido/reference-staking-modules.json    read by verify() only, not the deploy.
"""

from __future__ import annotations

import ast
import hashlib
import json
import re
import subprocess
import sys
import tomllib
from pathlib import Path

# Image tags build.sh assigns to the cached stages (keep in sync with build.sh).
TOOLCHAIN_TAG = "cerc/armada-nitro-env-toolchain:local"
CIRCUITS_TAG = "cerc/armada-nitro-env-circuits:local"


def src_tag(name: str) -> str:
    return f"cerc/armada-nitro-env-src-{name}:local"


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canon_json(obj: object) -> bytes:
    # default=str so TOML dates/datetimes serialise deterministically.
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode()


def _image_id(ref: str) -> str:
    try:
        out = subprocess.run(
            ["docker", "image", "inspect", "-f", "{{.Id}}", ref],
            capture_output=True,
            text=True,
            check=False,
        )
    except FileNotFoundError:
        return "MISSING"
    if out.returncode == 0 and out.stdout.strip():
        return out.stdout.strip()
    return "MISSING"


def _strip_docstrings(tree: ast.AST) -> None:
    for node in ast.walk(tree):
        if isinstance(
            node,
            (ast.Module, ast.FunctionDef, ast.AsyncFunctionDef, ast.ClassDef),
        ):
            body = node.body
            if (
                body
                and isinstance(body[0], ast.Expr)
                and isinstance(body[0].value, ast.Constant)
                and isinstance(body[0].value.value, str)
            ):
                body.pop(0)


def _ast_digest(text: str) -> str:
    tree = ast.parse(text)
    _strip_docstrings(tree)
    # ast.dump omits line/column numbers by default, so formatting is invisible.
    return _sha(ast.dump(tree).encode())


def _prettier(root: Path, rel: str) -> bytes:
    prettier = root / "node_modules" / ".bin" / "prettier"
    if not prettier.exists():
        sys.exit(
            f"base-key: {prettier} not found; run `npm ci` in {root} so the "
            "prettier used to normalise env/lido TypeScript is available."
        )
    out = subprocess.run(
        [str(prettier), rel],
        cwd=root,
        capture_output=True,
        text=True,
        check=False,
    )
    if out.returncode != 0:
        sys.exit(f"base-key: prettier failed on {rel}:\n{out.stderr}")
    return out.stdout.encode()


def _yaml_canon(path: Path) -> bytes:
    try:
        import yaml  # PyYAML

        docs = list(yaml.safe_load_all(path.read_text()))
        obj: object = docs[0] if len(docs) == 1 else docs
        return _canon_json(obj)
    except ImportError:
        out = subprocess.run(
            ["docker", "compose", "-f", str(path), "config", "--format", "json"],
            capture_output=True,
            text=True,
            check=False,
        )
        if out.returncode != 0:
            sys.exit(f"base-key: no PyYAML and `docker compose config` failed on {path}:\n{out.stderr}")
        return _canon_json(json.loads(out.stdout))


def _compose_image_refs(root: Path) -> list[str]:
    text = (root / "stack/compose/docker-compose-armada-fixturenet.yml").read_text()
    refs = []
    for repo in (
        "ethereum/client-go",
        "sigp/lighthouse",
        "ethpandaops/ethereum-genesis-generator",
    ):
        m = re.search(rf"{re.escape(repo)}:\S+", text)
        if m:
            refs.append(m.group(0))
    return refs


def key_lines(root: Path) -> list[str]:
    lock = json.loads((root / "env/sources.lock.json").read_text())
    lines: list[str] = []

    # --- image identities -------------------------------------------------
    image_refs = [TOOLCHAIN_TAG, CIRCUITS_TAG]
    image_refs += [src_tag(s["name"]) for s in lock["sources"]]
    image_refs += _compose_image_refs(root)
    for ref in image_refs:
        lines.append(f"image {ref} {_image_id(ref)}")

    # --- reconciler: AST with docstrings stripped -------------------------
    for py in sorted((root / "env/reconciler").rglob("*.py")):
        if "__pycache__" in py.parts:
            continue
        lines.append(f"pyast {py.relative_to(root)} {_ast_digest(py.read_text())}")
    # any non-.py file inside env/reconciler -> raw bytes (fail-safe)
    for f in sorted((root / "env/reconciler").rglob("*")):
        if not f.is_file() or f.suffix == ".py" or "__pycache__" in f.parts:
            continue
        lines.append(f"raw {f.relative_to(root)} {_sha(f.read_bytes())}")

    # --- JSON: canonical form ---------------------------------------------
    base_target = json.loads((root / "env/targets/fixturenet-base.json").read_text())
    lines.append(f"json env/targets/fixturenet-base.json {_sha(_canon_json(base_target))}")
    steps = json.loads((root / "env/lido/steps-fixturenet.json").read_text())
    lines.append(f"json env/lido/steps-fixturenet.json {_sha(_canon_json(steps))}")
    non_sources = {k: v for k, v in lock.items() if k != "sources"}
    lines.append(f"json env/sources.lock.json:non-sources {_sha(_canon_json(non_sources))}")

    # --- TOML: parsed then canonical JSON ---------------------------------
    params = tomllib.loads((root / "env/lido/deploy-params-fixturenet.toml").read_text())
    lines.append(f"toml env/lido/deploy-params-fixturenet.toml {_sha(_canon_json(params))}")

    # --- YAML compose: parsed then canonical JSON -------------------------
    for rel in (
        "stack/compose/docker-compose-armada-fixturenet.yml",
        "stack/compose-jobs/docker-compose-armada-env-reconcile.yml",
    ):
        lines.append(f"yaml {rel} {_sha(_yaml_canon(root / rel))}")

    # --- TypeScript the deploy runs: prettier-normalised ------------------
    ts_rel = "env/lido/0140-plug-staking-modules-via-vote.ts"
    lines.append(f"ts {ts_rel} {_sha(_prettier(root, ts_rel))}")

    # --- any other unknown-type file in env/lido -> raw bytes (fail-safe) -
    handled_lido = {
        "0140-plug-staking-modules-via-vote.ts",
        "steps-fixturenet.json",
        "deploy-params-fixturenet.toml",
    }
    excluded_lido = {"reference-staking-modules.json"}  # verify() only
    lido = root / "env/lido"
    for f in sorted(lido.rglob("*")):
        if not f.is_file():
            continue
        rel_path = f.relative_to(lido)
        if rel_path.parts[0] == "tools":  # capture/dev tooling, not the deploy
            continue
        rel_str = str(rel_path)
        if rel_str in handled_lido or rel_str in excluded_lido:
            continue
        lines.append(f"raw env/lido/{rel_str} {_sha(f.read_bytes())}")

    return lines


def main() -> None:
    argv = sys.argv[1:]
    if "--root" not in argv:
        sys.exit("usage: base-key.py --root <REPO_ROOT>")
    root = Path(argv[argv.index("--root") + 1]).resolve()
    print("\n".join(key_lines(root)))


if __name__ == "__main__":
    main()
