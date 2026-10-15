#!/usr/bin/env bash
# release.sh — tag the current version and start the next development cycle.
#
#   ./release.sh [patch|minor|major] [--no-test]
#
# Steps:
#   1. refuse to run with uncommitted changes (or on a non-master branch,
#      unless confirmed);
#   2. run `zig build test` and the corpus check over Zig's lib/ (skip with
#      --no-test);
#   3. read the version from build.zig.zon, promote the Unreleased section
#      of CHANGELOG.md to it, and create the annotated tag <version> on HEAD;
#   4. bump the version in build.zig.zon (patch by default) and commit it.
#
# Nothing is pushed; the script prints the push commands at the end. CI
# builds the release when the tag is pushed.

set -euo pipefail
cd "$(dirname "$0")"

bump="patch"
run_tests=1
for arg in "$@"; do
    case "$arg" in
        patch|minor|major) bump="$arg" ;;
        --no-test) run_tests=0 ;;
        *) echo "usage: $0 [patch|minor|major] [--no-test]" >&2; exit 2 ;;
    esac
done

# 1. Clean tree, sensible branch.
if [ -n "$(git status --porcelain)" ]; then
    echo "error: uncommitted changes — commit or stash first" >&2
    exit 1
fi
branch=$(git rev-parse --abbrev-ref HEAD)
if [ "$branch" = "HEAD" ]; then
    echo "error: HEAD is detached — check out a branch first" >&2
    exit 1
fi
if [ "$branch" != "master" ] && [ "$branch" != "main" ]; then
    if [ ! -t 0 ]; then
        echo "error: on branch '$branch' and no terminal to confirm" >&2
        exit 1
    fi
    read -r -p "warning: releasing from branch '$branch', continue? [y/N] " a
    [ "$a" = "y" ] || exit 1
fi

# 2. Release gate.
if [ "$run_tests" = 1 ]; then
    echo "==> zig build test"
    zig build test
    lib_dir=$(zig env | sed -n 's/^ *\.lib_dir = "\(.*\)",$/\1/p')
    echo "==> zig build corpus -- $lib_dir"
    zig build corpus -Doptimize=ReleaseSafe -- "$lib_dir"
fi

# 3. Version from build.zig.zon -> tag.
version=$(sed -n 's/^ *\.version = "\([0-9][^"]*\)",.*/\1/p' build.zig.zon)
if ! [[ "$version" =~ ^[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
    echo "error: could not read a .version of the form X.Y.Z from build.zig.zon" >&2
    exit 1
fi
if git rev-parse -q --verify "refs/tags/$version" >/dev/null; then
    echo "error: tag '$version' already exists" >&2
    exit 1
fi
# Promote the Unreleased changelog section to this version.
if grep -q '^## \[Unreleased\]' CHANGELOG.md; then
    sed -i "s/^## \[Unreleased\]/## [Unreleased]\n\n## [$version] - $(date +%Y-%m-%d)/" CHANGELOG.md
    git add CHANGELOG.md
    git commit -q -m "changelog: release $version"
fi

git tag -a "$version" -m "zigfmt $version"
echo "==> tagged $version"

# 4. Bump for the next cycle.
IFS=. read -r major minor patch <<< "$version"
case "$bump" in
    major) next="$((major + 1)).0.0" ;;
    minor) next="$major.$((minor + 1)).0" ;;
    patch) next="$major.$minor.$((patch + 1))" ;;
esac
sed -i "s/^\( *\.version = \)\"$version\",/\1\"$next\",/" build.zig.zon
if [ -z "$(git diff --name-only build.zig.zon)" ]; then
    echo "error: version bump did not modify build.zig.zon" >&2
    exit 1
fi
git add build.zig.zon
git commit -q -m "start $next development"
echo "==> bumped to $next and committed"

echo
echo "To publish (tag push triggers the release CI):"
echo "  git push origin $branch"
echo "  git push origin $version"
