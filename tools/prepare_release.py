#!/usr/bin/env python3
import re
import sys
from pathlib import Path


VERSION_RE = re.compile(r"\d+\.\d+\.\d+\Z")
META_VERSION_RE = re.compile(r'(?m)^(\s*version\s*=\s*)"([^"]+)"(,\s*)$')


def prepare_release(version):
    if not VERSION_RE.fullmatch(version):
        raise ValueError("version must be MAJOR.MINOR.PATCH")

    root = Path(__file__).resolve().parents[1]
    changelog_path = root / "CHANGELOG.md"
    metadata_path = root / "_meta.lua"
    with changelog_path.open(encoding="utf-8", newline="") as file:
        changelog = file.read()
    metadata = metadata_path.read_text(encoding="utf-8")

    metadata_matches = list(META_VERSION_RE.finditer(metadata))
    if len(metadata_matches) != 1:
        raise ValueError("expected one version entry in _meta.lua")
    current_version = metadata_matches[0].group(2)
    if not VERSION_RE.fullmatch(current_version):
        raise ValueError("_meta.lua does not contain a MAJOR.MINOR.PATCH version")

    newline = "\r\n" if "\r\n" in changelog else "\n"
    lines = changelog.splitlines(keepends=True)
    unreleased_indices = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == "## Unreleased"]
    release_indices = [i for i, line in enumerate(lines) if line.rstrip("\r\n") == f"## {version}"]
    if len(unreleased_indices) != 1:
        raise ValueError("expected one ## Unreleased section in CHANGELOG.md")
    if len(release_indices) > 1:
        raise ValueError(f"CHANGELOG.md has duplicate ## {version} sections")

    start = unreleased_indices[0]
    end = next((i for i in range(start + 1, len(lines)) if lines[i].startswith("## ")), len(lines))
    notes = "".join(lines[start + 1:end]).strip("\r\n")

    if release_indices:
        if current_version == version and not notes.strip():
            return False
        raise ValueError(f"CHANGELOG.md already has a ## {version} section")
    if current_version != version:
        next_parts = tuple(map(int, version.split(".")))
        current_parts = tuple(map(int, current_version.split(".")))
        if next_parts <= current_parts:
            raise ValueError(f"{version} must be newer than _meta.lua version {current_version}")

    prefix = "".join(lines[:start + 1])
    suffix = "".join(lines[end:]).lstrip("\r\n")
    section = f"## {version}{newline}"
    if notes.strip():
        section += f"{notes}{newline}"
    updated_changelog = f"{prefix}{newline}{section}{newline}{suffix}"
    updated_metadata = META_VERSION_RE.sub(lambda m: f'{m.group(1)}"{version}"{m.group(3)}', metadata, count=1)

    with changelog_path.open("w", encoding="utf-8", newline="") as file:
        file.write(updated_changelog)
    metadata_path.write_text(updated_metadata, encoding="utf-8")
    return True


def main():
    if len(sys.argv) != 2:
        print("Usage: prepare_release.py MAJOR.MINOR.PATCH", file=sys.stderr)
        return 2
    try:
        changed = prepare_release(sys.argv[1])
    except (OSError, ValueError) as error:
        print(f"Release preparation failed: {error}", file=sys.stderr)
        return 1
    print("Release metadata is already prepared." if not changed else "Release metadata prepared.")
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
