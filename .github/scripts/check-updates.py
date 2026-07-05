#!/usr/bin/env python3
"""check-updates.py

Detects upstream releases that are newer than what the repository currently
packages and, when any are found, posts a single aggregated notification to a
Discord webhook.

Environment:
  DISCORD_WEBHOOK_URL  Discord webhook URL. If empty/unset, the payload is
                       printed and no request is sent (the run still succeeds).
  GITHUB_TOKEN         Optional. Passed to nvchecker (github source) via its
                       keyfile to avoid anonymous API rate limits.

The script must be run from the repository root.
"""

from __future__ import annotations

import json
import os
import re
import subprocess
import sys
import tempfile
import urllib.error
import urllib.request
from pathlib import Path

import tomllib

REPO_ROOT = Path.cwd()


def log(msg: str) -> None:
    print(msg, flush=True)


def discover_packages() -> dict[str, dict]:
    """Return {package_dir_name: parsed .nvchecker.toml table} for every package."""
    packages: dict[str, dict] = {}
    for cfg in sorted(REPO_ROOT.glob("*/.nvchecker.toml")):
        pkg_dir = cfg.parent.name
        if not (cfg.parent / "PKGBUILD").is_file():
            log(f"::warning::{pkg_dir} has .nvchecker.toml but no PKGBUILD; skipping.")
            continue
        with cfg.open("rb") as fh:
            packages[pkg_dir] = tomllib.load(fh)
    return packages


def read_pkgbuild_var(pkg_dir: str, var: str) -> str:
    """Evaluate a top-level PKGBUILD variable (e.g. pkgver, url) via bash."""
    pkgbuild = REPO_ROOT / pkg_dir / "PKGBUILD"
    result = subprocess.run(
        [
            "bash",
            "-c",
            f'source "{pkgbuild}" >/dev/null 2>&1; printf "%s" "${{{var}}}"',
        ],
        capture_output=True,
        text=True,
    )
    return result.stdout.strip()


def run_nvchecker(config_paths: list[Path]) -> dict[str, dict]:
    """Run nvchecker over the merged configs.

    Returns {section_name: {"version": str, "url": str | None}} for every entry
    nvchecker resolved. Results are parsed from nvchecker's JSON log so that a
    single failing source does not discard the successful ones.
    """
    tmp = Path(tempfile.mkdtemp(prefix="nvchecker-"))
    merged = tmp / "nvchecker.toml"

    lines: list[str] = ["[__config__]"]

    token = os.environ.get("GITHUB_TOKEN", "").strip()
    if token:
        keyfile = tmp / "keys.toml"
        keyfile.write_text(f'[keys]\ngithub = "{token}"\n', encoding="utf-8")
        lines.append(f'keyfile = "{keyfile}"')

    lines.append("")
    for cfg in config_paths:
        lines.append(cfg.read_text(encoding="utf-8").rstrip())
        lines.append("")

    merged.write_text("\n".join(lines), encoding="utf-8")

    log("::group::nvchecker run")
    proc = subprocess.run(
        ["nvchecker", "-c", str(merged), "--logger", "json", "-t", "3"],
        capture_output=True,
        text=True,
    )
    if proc.stderr:
        log(proc.stderr)

    results: dict[str, dict] = {}
    for line in proc.stdout.splitlines():
        line = line.strip()
        if not line:
            continue
        log(line)
        try:
            event = json.loads(line)
        except json.JSONDecodeError:
            continue
        if (
            event.get("event") == "updated"
            and event.get("name")
            and event.get("version")
        ):
            results[event["name"]] = {
                "version": str(event["version"]),
                "url": event.get("url"),
            }
    log("::endgroup::")

    if proc.returncode != 0:
        log(
            f"::warning::nvchecker exited with code {proc.returncode}; using the results it did resolve."
        )
    return results


def _tokenize(version: str) -> list:
    return [int(t) if t.isdigit() else t for t in re.findall(r"\d+|[A-Za-z]+", version)]


def version_gt(new: str, cur: str) -> bool:
    """True if `new` is strictly greater than `cur` (Arch-ish comparison)."""
    a, b = _tokenize(new), _tokenize(cur)
    for x, y in zip(a, b):
        if isinstance(x, int) and isinstance(y, int):
            if x != y:
                return x > y
        elif isinstance(x, str) and isinstance(y, str):
            if x != y:
                return x > y
        else:
            # A numeric component outranks an alphabetic one.
            return isinstance(x, int)
    return len(a) > len(b)


def release_url(
    pkg_dir: str, cfg: dict, version: str, nvchecker_url: str | None
) -> str:
    """Pick the best link for the update.

    Preference order: the release URL nvchecker itself reported, then a
    reconstructed GitHub release/tag page, then the PKGBUILD `url` homepage.
    """
    if nvchecker_url:
        return nvchecker_url
    table = cfg.get(pkg_dir, {})
    repo = table.get("github")
    if repo:
        prefix = table.get("prefix", "")
        return f"https://github.com/{repo}/releases/tag/{prefix}{version}"
    homepage = read_pkgbuild_var(pkg_dir, "url")
    return homepage or f"https://github.com/{os.environ.get('GITHUB_REPOSITORY', '')}"


def build_payload(outdated: list[dict]) -> dict:
    embeds = [
        {
            "title": item["package"],
            "url": item["url"],
            "color": 0x5865F2,
            "fields": [
                {"name": "New version", "value": item["new_version"], "inline": True},
                {"name": "Packaged", "value": item["current_version"], "inline": True},
            ],
        }
        for item in outdated
    ]
    return {
        "content": "@everyone \U0001f4e6 Upstream package update(s) available:",
        "embeds": embeds,
        "allowed_mentions": {"parse": ["everyone"]},
    }


def send_discord(payload: dict) -> None:
    webhook = os.environ.get("DISCORD_WEBHOOK_URL", "").strip()
    pretty = json.dumps(payload, indent=2, ensure_ascii=False)
    if not webhook:
        log("DISCORD_WEBHOOK_URL is not set; skipping notification. Payload would be:")
        log(pretty)
        return

    log("Sending Discord notification with payload:")
    log(pretty)
    request = urllib.request.Request(
        webhook,
        data=json.dumps(payload).encode("utf-8"),
        headers={
            "Content-Type": "application/json",
            # Discord sits behind Cloudflare, which rejects the default
            # "Python-urllib/x.y" User-Agent with HTTP 403 (error code 1010).
            "User-Agent": "lumbung-nvchecker (https://github.com/ngoding-id/lumbung, 1.0)",
        },
        method="POST",
    )
    try:
        with urllib.request.urlopen(request) as response:
            log(f"Discord responded with HTTP {response.status}.")
    except urllib.error.HTTPError as exc:
        body = exc.read().decode("utf-8", "replace")
        log(f"::error::Discord webhook failed: HTTP {exc.code} {body}")
        sys.exit(1)
    except urllib.error.URLError as exc:
        log(f"::error::Discord webhook failed: {exc.reason}")
        sys.exit(1)


def main() -> int:
    packages = discover_packages()
    if not packages:
        log("No packages with a .nvchecker.toml were found; nothing to check.")
        return 0

    log(f"Checking {len(packages)} package(s): {', '.join(sorted(packages))}")
    config_paths = [REPO_ROOT / name / ".nvchecker.toml" for name in packages]
    upstream = run_nvchecker(config_paths)

    outdated: list[dict] = []
    for pkg_dir, cfg in packages.items():
        # nvchecker keys the result by the config section name.
        section = next(iter(cfg.keys()), pkg_dir)
        result = upstream.get(section) or upstream.get(pkg_dir)
        current = read_pkgbuild_var(pkg_dir, "pkgver")

        if not result:
            log(
                f"::warning::{pkg_dir}: could not determine upstream version; skipping."
            )
            continue
        if not current:
            log(f"::warning::{pkg_dir}: could not read pkgver from PKGBUILD; skipping.")
            continue

        new_version = result["version"]
        if version_gt(new_version, current):
            log(f"OUTDATED {pkg_dir}: {current} -> {new_version}")
            outdated.append(
                {
                    "package": pkg_dir,
                    "current_version": current,
                    "new_version": new_version,
                    "url": release_url(pkg_dir, cfg, new_version, result.get("url")),
                }
            )
        else:
            log(f"up to date {pkg_dir}: {current} (upstream {new_version})")

    if not outdated:
        log("All packages are up to date; no notification sent.")
        return 0

    send_discord(build_payload(outdated))
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
