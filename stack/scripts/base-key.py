#!/usr/bin/env python3
"""Print the fixturenet base-layer snapshot cache-key input lines.

Usage: base-key.py --root <REPO_ROOT>

Each line is `<kind> <label> <digest>` (or `image <ref> <id>`); the 16-hex cache
key is sha256 of all lines, truncated (see stack/scripts/fixturenet-base-common.sh).
The lines are normalised so that a commit which only reformats, re-comments or
re-whitespaces an input does NOT change the key -- only a change to what the base
chain actually deploys does. Sourced by fixturenet-base-common.sh; also written
verbatim into the auditable `.key` file beside each snapshot.

The key is a pure function of the committed sources: it is independent of the host
python version (c1) and of local build output (local docker image IDs, c2).
The AST lines are serialised to a version-independent canonical form, and the image
lines use the committed source pins and image refs (not local docker image IDs).
YAML lines are parsed with PyYAML, which the verify script pins to the same version
in every interpreter so the canonical form is stable across host python versions.

INCLUDED -- these determine the base chain's state (network + weth, usdc, cctp, aave,
lido, armada):

  snapfmt <n>
    The snapshot format version (SNAPSHOT_FORMAT_VERSION). Bumping it alone
    changes every key, so a snapshot written in an older on-disk format is never
    restored by a newer fixturenet-new that expects a different layout.

  image <ref> <id>
    - the chain images: ethereum/client-go, sigp/lighthouse,
      ethpandaops/ethereum-genesis-generator (from the fixturenet compose).
      The <id> is the committed image ref (tag) from the compose file -- a pure
      function of the committed sources, NOT a local docker image ID (c2).
    - the `toolchain` env-image stage (base toolchain: foundry/node/yarn/just);
      its <id> is sha256 of the committed build files (Dockerfile, build.sh,
      clone-source.sh) -- a pure function of committed sources.
    - one `src-<name>` stage per env/sources.lock.json sources[] entry -- its <id>
      is sha256 of the source pin (repo/ref/commit) from the lock file.
    - the `circuits` stage (Armada's pinned circuit build) -- its <id> is sha256
      of the circuits pin (repo/tag/tarballSha256/sumsFile) from the lock file.
    NOT the whole env image and NOT the `contracts` stage: armada_nitro's own
    contracts are not part of the base chain, so recompiling them must not
    invalidate the base snapshot.

  pyast env/reconciler/**/*.py <sha>
    Hash of the file's AST with docstrings stripped -- the reconciler and every
    module as executed. Comments, formatting and docstrings do not change it. The
    AST is serialised to a version-independent canonical form, so the key does not
    change with the host python version (c1).

  json <path> <sha>   canonical JSON (sorted keys, no whitespace), so reindenting
    or reordering keys does not change it:
    - env/targets/fixturenet-base.json          (the base target);
    - env/lido/steps-fixturenet.json            (the lido deploy step list);
    - env/sources.lock.json:non-sources         (weth9, armada-circuits; the
      sources[] pins are already covered by the src-<name> stage image IDs).

  toml env/lido/deploy-params-fixturenet.toml <sha>
    Parsed (tomllib) then canonical JSON.

  yaml <path> <sha>   parsed with PyYAML then canonical JSON:
    - stack/compose/docker-compose-armada-fixturenet.yml (the chain: image tags
      AND the genesis parameters -- chain id, forks, mnemonic, validators);
    - stack/compose-jobs/docker-compose-env-reconcile... (the job).
    The parser must be the same pinned version in every interpreter -- the verify
    script installs PyYAML (pinned) so both interpreters parse identically.

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
  - env/reconciler/tools/**, env/reconciler/tests/**  operator tooling and test
    fixtures, never imported by a reconcile run;
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
import base64
import tomllib
from pathlib import Path

# Image tags build.sh assigns to the cached stages (keep in sync with build.sh).
TOOLCHAIN_TAG = "cerc/armada-nitro-env-toolchain:local"
CIRCUITS_TAG = "cerc/armada-nitro-env-circuits:local"

# Snapshot format version -- part of the key so a snapshot written by an older
# format is never restored by a newer fixturenet-new (its key won't match).
# v2: execution layer only (geth data + armada_env + the EL genesis) plus the
# recorded EL head block; the consensus genesis is regenerated at restore
# time as a shadow fork on that head.
SNAPSHOT_FORMAT_VERSION = 2


def src_tag(name: str) -> str:
    return f"cerc/armada-nitro-env-src-{name}:local"


def _sha(data: bytes) -> str:
    return hashlib.sha256(data).hexdigest()


def _canon_json(obj: object) -> bytes:
    # default=str so TOML dates/datetimes serialise deterministically.
    return json.dumps(obj, sort_keys=True, separators=(",", ":"), default=str).encode()


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
                and isinstance(body[0].value, str)
            ):
                body.pop(0)


def _canon_ast_value(v: object) -> object:
    # Version-independent canonical value: AST nodes recurse; tuples map element-wise;
    # scalars pass through. This makes the pyast lines a pure function of the
    # source's AST semantics, not the host python version (c1).
    if v is None:
        return None
    if isinstance(v, ast.AST):
        return _canon_ast_node(v)
    if isinstance(v, (tuple, list)):
        return [_canon_ast_value(x) for x in v]
    if isinstance(v, (bytes, bytearray)):
        return base64.b64encode(bytes(v)).decode()
    if v is ...:  # Ellipsis
        return "ellipsis"
    if isinstance(v, (set, frozenset)):
        return sorted((_canon_ast_value(x) for x in v), key=repr)
    if isinstance(v, float):
        return str(v)  # stable float formatting
    return v


def _json_default(o: object) -> str:
    # Fallback for any AST value json does not natively serialise (e.g. exotic
    # scalar types). Deterministic across python versions (c1).
    return str(o)


def _canon_ast_node(node: ast.AST) -> list[object]:
    # (type_name, sorted list of [field_name, canonical_value] for non-None fields).
    # Only the stable fields are included, so 3.12 and 3.14 serialise identically.
    fields: list[list[object]] = []
    for name in node._fields:
        v = getattr(node, name)
        if v is not None:
            fields.append([name, _canon_ast_value(v)])
    return [type(node).__name__, sorted(fields, key=lambda p: str(p[0]))]


def _ast_digest(text: str) -> str:
    tree = ast.parse(text)
    _strip_docstrings(tree)
    return _sha(
        json.dumps(
            _canon_ast_node(tree), sort_keys=True, separators=(",", ":"), default=_json_default
        ).encode()
    )


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
    # c1: parse with PyYAML. The verify script ensures the same pinned PyYAML is
    # installed in every interpreter, so the canonical JSON is identical across
    # python versions. PyYAML is imported lazily; if it is missing the line fails
    # fast (the caller installs the pinned version).
    import yaml  # PyYAML

    docs = list(yaml.safe_load_all(path.read_text()))
    obj: object = docs[0] if len(docs) == 1 else docs
    return _canon_json(obj)


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


def _toolchain_sha(root: Path) -> str:
    # c2: the toolchain stage's image ID is replaced with sha256 of the committed
    # build files (Dockerfile, build.sh, clone-source.sh) -- a pure function of
    # the committed sources, independent of local docker image IDs.
    base = root / "stack/container-build/cerc-armada-nitro-env"
    data = b"\n".join((base / f).read_bytes() for f in ("Dockerfile", "build.sh", "clone-source.sh"))
    return _sha(data)


def key_lines(root: Path) -> list[str]:
    lock = json.loads((root / "env/sources.lock.json").read_text())
    lines: list[str] = []

    # --- snapshot format version ------------------------------------------
    lines.append(f"snapfmt {SNAPSHOT_FORMAT_VERSION}")

    # --- image identities (c2: pure function of committed sources) --------
    # toolchain stage: sha256 of committed build files.
    lines.append(f"image {TOOLCHAIN_TAG} {_toolchain_sha(root)}")

    # source stages: sha256 of each source pin (repo/ref/commit) from the lock.
    for s in lock["sources"]:
        pin = _canon_json({k: s.get(k) for k in ("repo", "ref", "commit") if k in s})
        lines.append(f"image {src_tag(s['name'])} {_sha(pin)}")

    # circuits stage: sha256 of the circuits pin (repo/tag/tarballSha256/sumsFileSha256).
    circuits = lock.get("armada-circuits", {})
    circ_pin = _canon_json(
        {k: circuits.get(k) for k in ("repo", "tag", "tarballSha256", "sumsFileSha256") if k in circuits}
    )
    lines.append(f"image {CIRCUITS_TAG} {_sha(circ_pin)}")

    # chain images: committed image refs (tags) from the compose file.
    for ref in _compose_image_refs(root):
        lines.append(f"image {ref} {ref}")

    # --- reconciler: AST with docstrings stripped -------------------------
    def _reconciler_excluded(p: Path) -> bool:
        rel = p.relative_to(root / "env/reconciler")
        return "__pycache__" in p.parts or (rel.parts[0] in ("tools", "tests"))

    for py in sorted((root / "env/reconciler").rglob("*.py")):
        if _reconciler_excluded(py):
            continue
        lines.append(f"pyast {py.relative_to(root)} {_ast_digest(py.read_text())}")
    # any non-.py file inside env/reconciler -> raw bytes (fail-safe)
    for f in sorted((root / "env/reconciler").rglob("*")):
        if not f.is_file() or f.suffix == ".py" or _reconciler_excluded(f):
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

    # --- YAML compose: parsed with PyYAML then canonical JSON -------------
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
        if rel_path.parts[0] == "tools":
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


def run_main() -> None:
    main()


if __name__ == "__main__":
    main()
