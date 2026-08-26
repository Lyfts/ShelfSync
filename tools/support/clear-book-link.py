#!/usr/bin/env python3
"""Removes a book's linked-provider entry from its KOReader sidecar file
(<book>.sdr/metadata.<ext>.lua) so "Link book" / auto-link can be re-tested
from scratch.

That sidecar also holds real user data for the book (reading position,
annotations, per-book reader settings), so this deliberately never does a
full parse+reserialize of the file -- a hand-rolled Lua table serializer
could subtly corrupt any of that. Instead it removes only the exact
top-level ["<provider>"] = { ... } block via line-range surgery (tracking
brace depth to find the matching close), leaving every other line
byte-for-byte untouched. This is only safe because those specific blocks
are entirely plugin-generated (book_id/pages/title/etc, never raw book
text), so they can't contain a stray brace to throw off the count.
"""
import argparse
import os
import re
import sys

ALLOWED_PROVIDERS = ("goodreads", "storygraph", "hardcover")


def default_koreader_dir():
    return os.environ.get("KOREADER_DIR", os.path.expanduser("~/.config/koreader"))


def lua_unescape(s):
    return s.replace('\\"', '"').replace("\\\\", "\\")


def most_recent_book(koreader_dir):
    history_path = os.path.join(koreader_dir, "history.lua")
    if not os.path.isfile(history_path):
        return None
    with open(history_path, "r", encoding="utf-8") as f:
        content = f.read()
    m = re.search(r'\["file"\]\s*=\s*"((?:[^"\\]|\\.)*)"', content)
    return lua_unescape(m.group(1)) if m else None


def resolve_metadata_path(book_path):
    if book_path.endswith(".lua"):
        return book_path
    if book_path.endswith(".sdr") and os.path.isdir(book_path):
        sdr_dir = book_path
    else:
        base, _ext = os.path.splitext(book_path)
        sdr_dir = base + ".sdr"

    if not os.path.isdir(sdr_dir):
        return None
    for name in os.listdir(sdr_dir):
        if name.startswith("metadata.") and name.endswith(".lua"):
            return os.path.join(sdr_dir, name)
    return None


def strip_provider_blocks(lines, providers):
    out = []
    removed = []
    i = 0
    n = len(lines)
    prefixes = tuple('["%s"] = ' % p for p in providers)

    while i < n:
        stripped = lines[i].strip()
        match = next((p for p, prefix in zip(providers, prefixes) if stripped.startswith(prefix)), None)

        if match is None:
            out.append(lines[i])
            i += 1
            continue

        rest = stripped[len('["%s"] = ' % match):]
        if rest.startswith("{") and not rest.rstrip().startswith("{}"):
            depth = 0
            j = i
            while j < n:
                depth += lines[j].count("{") - lines[j].count("}")
                j += 1
                if depth <= 0:
                    break
            removed.append(match)
            i = j
        else:
            # Scalar or inline-empty-table value on a single line.
            removed.append(match)
            i += 1

    return out, removed


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "book", nargs="?", default=None,
        help="Book file, .sdr directory, or metadata.lua path. "
             "Defaults to the most recently opened book in KOReader's history.lua.",
    )
    parser.add_argument(
        "-p", "--provider", default="all",
        help="Comma-separated providers to unlink (goodreads, storygraph, hardcover) or 'all'. "
             "Default: all.",
    )
    parser.add_argument(
        "--dry-run", action="store_true",
        help="Show what would be removed without writing anything.",
    )
    args = parser.parse_args()

    if args.provider == "all":
        providers = list(ALLOWED_PROVIDERS)
    else:
        providers = [p.strip() for p in args.provider.split(",") if p.strip()]
    for p in providers:
        if p not in ALLOWED_PROVIDERS:
            parser.error(f"unknown provider '{p}' (expected one of {', '.join(ALLOWED_PROVIDERS)}, or 'all')")

    koreader_dir = default_koreader_dir()
    book_path = args.book
    if not book_path:
        book_path = most_recent_book(koreader_dir)
        if not book_path:
            print(f"error: no book given and couldn't read {koreader_dir}/history.lua", file=sys.stderr)
            return 1
        print(f"No book given, using most recently opened: {book_path}")

    metadata_path = resolve_metadata_path(book_path)
    if not metadata_path or not os.path.isfile(metadata_path):
        print(f"error: no sidecar metadata.lua found for '{book_path}'", file=sys.stderr)
        return 1

    with open(metadata_path, "r", encoding="utf-8") as f:
        lines = f.readlines()

    new_lines, removed = strip_provider_blocks(lines, providers)

    if not removed:
        print(f"No linked provider(s) found in {metadata_path} for: {', '.join(providers)}")
        return 0

    print(f"{'Would remove' if args.dry_run else 'Removing'} from {metadata_path}: {', '.join(removed)}")
    if args.dry_run:
        return 0

    tmp_path = metadata_path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.writelines(new_lines)
    os.replace(tmp_path, metadata_path)
    print("Done.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
