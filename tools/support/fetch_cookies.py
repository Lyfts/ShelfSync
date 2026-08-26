#!/usr/bin/env python3
# /// script
# requires-python = ">=3.8"
# dependencies = ["browser_cookie3"]
# ///
"""Fetches StoryGraph and/or Goodreads session cookies from a browser already
logged in on this PC, and writes them into shelfsync_config.lua -- an
automated alternative to manually copying cookie values out of devtools.

This only reads cookies that already exist locally (it never logs in on your
behalf), and never uploads anything anywhere; it just moves values from your
browser's cookie storage into a local file. Requires the third-party
`browser_cookie3` package -- if you have uv (https://docs.astral.sh/uv/)
installed, `uv run` picks it up automatically from the metadata above with
no separate install step; otherwise: pip install browser_cookie3
"""
import argparse
import http.cookiejar
import os
import re
import sys

BROWSERS = (
    "auto", "chrome", "firefox", "zen", "edge", "brave", "opera", "opera_gx",
    "chromium", "vivaldi", "librewolf", "safari",
)

DEFAULT_TEMPLATE = """return {
  -- Both sections are optional and independent -- fill in only the
  -- service(s) you want to use.
  storygraph = {
    session_cookie = '',
    remember_user_token = '',
  },
  hardcover = {
    token = '',
  },
  goodreads = {
    cookie = '',
  },
}
"""


def default_config_path():
    return os.path.join(os.getcwd(), "shelfsync_config.lua")


def _zen_browser_fn(browser_cookie3):
    # Zen is a Firefox fork; browser_cookie3 doesn't know about it yet, so
    # build a loader for it the same way the library defines firefox()/
    # librewolf() -- by pointing FirefoxBased at Zen's profile directories.
    class Zen(browser_cookie3.FirefoxBased):
        def __init__(self, cookie_file=None, domain_name="", key_file=None):
            args = {
                "linux_data_dirs": [
                    "~/.config/zen",
                    "~/snap/zen-browser/common/.zen",
                    "~/.var/app/app.zen_browser.zen/.zen",
                    "~/.zen",
                ],
                "windows_data_dirs": [
                    {"env": "APPDATA", "path": "zen"},
                    {"env": "LOCALAPPDATA", "path": "zen"},
                ],
                "osx_data_dirs": ["~/Library/Application Support/zen"],
            }
            super().__init__("Zen", cookie_file, domain_name, key_file, **args)

    def zen(cookie_file=None, domain_name="", key_file=None):
        return Zen(cookie_file, domain_name, key_file).load()

    return zen


def get_browser_fn(browser_cookie3, name):
    if name == "zen":
        return _zen_browser_fn(browser_cookie3)
    return getattr(browser_cookie3, name, None)


def load_cookiejar(browser, domain):
    try:
        import browser_cookie3
    except ImportError:
        print("error: this tool needs the 'browser_cookie3' package.\n"
              "Install it with: pip install browser_cookie3\n"
              "(or run this script with `uv run` instead of `python3` -- "
              "uv installs it automatically, see https://docs.astral.sh/uv/)", file=sys.stderr)
        sys.exit(1)

    if browser == "auto":
        # Don't use browser_cookie3.load(): it only catches its own
        # BrowserCookieError, but on some platforms a not-installed browser's
        # path lookup returns None instead of raising that, which blows up
        # the whole scan with a bare TypeError. Try each browser ourselves
        # and just skip whichever ones don't work.
        cj = http.cookiejar.CookieJar()
        for name in BROWSERS[1:]:
            fn = get_browser_fn(browser_cookie3, name)
            if fn is None:
                continue
            try:
                for cookie in fn(domain_name=domain):
                    cj.set_cookie(cookie)
            except Exception:
                continue
        return cj

    fn = get_browser_fn(browser_cookie3, browser)
    if fn is None:
        print(f"error: unsupported browser '{browser}'", file=sys.stderr)
        sys.exit(1)
    try:
        return fn(domain_name=domain)
    except Exception as e:
        print(f"error: couldn't read cookies from '{browser}': {e}", file=sys.stderr)
        print("Tip: try a different browser with --browser, e.g. --browser firefox "
              "(Firefox stores cookies in plain sqlite, so it doesn't need OS keychain access).",
              file=sys.stderr)
        sys.exit(1)


def fetch_storygraph(browser):
    cookies = {c.name: c.value for c in load_cookiejar(browser, "thestorygraph.com")}
    return cookies.get("_storygraph_session"), cookies.get("remember_user_token")


def fetch_goodreads(browser):
    cj = load_cookiejar(browser, "goodreads.com")
    by_name = {c.name: c.value for c in cj}
    if not by_name:
        return None
    # Rebuild the same 'Cookie' request header a browser would send to
    # www.goodreads.com, which is what the goodreads.cookie field expects.
    return "; ".join(f"{name}={value}" for name, value in by_name.items())


def set_field(text, section, field, value):
    escaped = value.replace("\\", "\\\\").replace("'", "\\'")
    section_re = re.compile(r"(" + re.escape(section) + r"\s*=\s*\{)(.*?)(\n[ \t]*\})", re.S)
    m = section_re.search(text)
    if not m:
        raise ValueError(f"couldn't find a '{section}' section in the config file")

    block = m.group(2)
    field_re = re.compile(r"(^[ \t]*" + re.escape(field) + r"[ \t]*=[ \t]*)'(?:[^'\\]|\\.)*'", re.M)
    if field_re.search(block):
        new_block = field_re.sub(lambda mm: mm.group(1) + "'" + escaped + "'", block, count=1)
    else:
        new_block = block + f"    {field} = '{escaped}',\n"
    return text[:m.start(2)] + new_block + text[m.end(2):]


def write_config(path, found):
    if os.path.isfile(path):
        with open(path, "r", encoding="utf-8") as f:
            text = f.read()
    else:
        repo_root = os.path.dirname(os.path.dirname(os.path.dirname(os.path.abspath(__file__))))
        example = os.path.join(repo_root, "shelfsync_config.example.lua")
        if os.path.isfile(example):
            with open(example, "r", encoding="utf-8") as f:
                text = f.read()
        else:
            text = DEFAULT_TEMPLATE

    for section, fields in found.items():
        for field, value in fields.items():
            text = set_field(text, section, field, value)

    tmp_path = path + ".tmp"
    with open(tmp_path, "w", encoding="utf-8") as f:
        f.write(text)
    os.replace(tmp_path, path)


def mask(value):
    if len(value) <= 10:
        return "*" * len(value)
    return f"{value[:4]}...{value[-4:]} ({len(value)} chars)"


def main():
    parser = argparse.ArgumentParser(description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    parser.add_argument(
        "--browser", choices=BROWSERS, default="auto",
        help="Locally installed browser to read cookies from (default: auto, tries all supported browsers).",
    )
    parser.add_argument(
        "--service", choices=("storygraph", "goodreads", "both"), default="both",
        help="Which service's cookies to fetch (default: both).",
    )
    parser.add_argument(
        "--config", default=None,
        help="Path to shelfsync_config.lua to write (default: shelfsync_config.lua in the current directory).",
    )
    parser.add_argument("--yes", "-y", action="store_true", help="Write without a confirmation prompt.")
    args = parser.parse_args()

    config_path = args.config or default_config_path()
    services = ("storygraph", "goodreads") if args.service == "both" else (args.service,)

    found = {}
    if "storygraph" in services:
        session, remember = fetch_storygraph(args.browser)
        if session and remember:
            found["storygraph"] = {"session_cookie": session, "remember_user_token": remember}
        else:
            missing = [n for n, v in (("_storygraph_session", session), ("remember_user_token", remember)) if not v]
            print(f"warning: couldn't find StoryGraph cookie(s) {', '.join(missing)} -- "
                  "make sure you're logged in to thestorygraph.com in this browser.", file=sys.stderr)

    if "goodreads" in services:
        cookie = fetch_goodreads(args.browser)
        if cookie:
            found["goodreads"] = {"cookie": cookie}
        else:
            print("warning: couldn't find any Goodreads cookies -- "
                  "make sure you're logged in to goodreads.com in this browser.", file=sys.stderr)

    if not found:
        print("Nothing found, nothing written.", file=sys.stderr)
        return 1

    print("Found:")
    for section, fields in found.items():
        for field, value in fields.items():
            print(f"  {section}.{field} = {mask(value)}")

    if not args.yes:
        reply = input(f"\nWrite these into {config_path}? [Y/n] ").strip().lower()
        if reply not in ("", "y", "yes"):
            print("Aborted, nothing written.")
            return 0

    write_config(config_path, found)
    print(f"Wrote {config_path}")
    return 0


if __name__ == "__main__":
    sys.exit(main())
