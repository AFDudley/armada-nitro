#!/usr/bin/env bash
# clone-source.sh <repo> <commit> <name>
#
# Generic per-source clone step shared by every `src-<name>` build stage: clone
# github.com/<repo> into /src/<name>, check out <commit>, and initialise its
# submodules. The per-project install/build commands live inline in the
# Dockerfile stage that calls this, next to the ARGs that pin the source, so a
# change to one source's pin (its build args) rebuilds only that stage.
#
# All three arguments are required; an empty repo or commit fails the build
# (the Dockerfile also asserts the ARGs are set before calling this).
set -e

repo="$1"
commit="$2"
name="$3"
[ -n "$repo" ] && [ -n "$commit" ] && [ -n "$name" ] || {
  echo "clone-source.sh: repo, commit and name are all required (got repo='$repo' commit='$commit' name='$name')" >&2
  exit 1
}

url="https://github.com/${repo}"
git clone --depth 1 "$url" "/src/${name}"
git -C "/src/${name}" fetch --depth 1 origin "$commit"
git -C "/src/${name}" checkout "$commit"
git -C "/src/${name}" submodule update --init --recursive
