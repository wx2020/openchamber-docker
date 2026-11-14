#!/usr/bin/env python3
"""Resolve the newest release inside each bundled toolchain's current family.

The Dockerfile pins a *family baseline* for every tool it downloads (Node 24,
Python 3.13, Go 1.25, Gradle 8, ...). Builds used to run only when upstream
OpenChamber cut a release, and the pins never moved, so the image silently aged:
Node 24.19.0, Go 1.25.14 and gh 2.98.0 shipped long after their successors were
out. This script re-resolves each family member to its newest patch, so the
version really does track "latest in the current family".

CI and Release both run it and pass the result as build args. Resolving inside
the Dockerfile would not work: the RUN instruction text never changes, so the
layer cache keeps replaying the old download forever.

Resolution is fail-open for everything except the OpenCode CLI: if an upstream
endpoint is down the Dockerfile default is kept and a warning is emitted, so a
transient outage cannot block a release. The CLI is fail-fast because falling
back silently would ship a server that no longer matches @opencode/client.
"""

from __future__ import annotations

import argparse
import json
import os
import re
import sys
import urllib.request

USER_AGENT = "openchamber-docker-toolchain-resolver/1.0"
UPSTREAM_REPOSITORY = "https://github.com/openchamber/openchamber.git"
OPENCODE_PACKAGE = "@opencode/cli"
OPENCODE_MINIMUM = "2.0.20"


def fetch(url: str, timeout: int = 25, attempts: int = 3) -> str:
    last: Exception | None = None
    for _ in range(attempts):
        try:
            request = urllib.request.Request(url, headers={"User-Agent": USER_AGENT})
            with urllib.request.urlopen(request, timeout=timeout) as response:
                return response.read().decode("utf-8", "replace")
        except Exception as error:  # noqa: BLE001 - retried, then reported
            last = error
    raise RuntimeError(f"{url}: {last}")


def fetch_json(url: str):
    return json.loads(fetch(url))


def version_key(value: str) -> tuple[int, ...]:
    return tuple(int(part) for part in re.findall(r"\d+", value)[:4])


def newest(candidates, *, family: str) -> str:
    matching = [
        candidate
        for candidate in candidates
        if candidate.startswith(family + ".") and re.fullmatch(r"\d+(?:\.\d+)+", candidate)
    ]
    if not matching:
        raise RuntimeError(f"no release matched family {family}")
    return max(matching, key=version_key)


def read_arg(dockerfile: str, name: str) -> str:
    match = re.search(rf"^ARG {name}=(\S+)$", dockerfile, re.MULTILINE)
    return match.group(1) if match else ""


def read_upstream_dockerfile(upstream_ref: str) -> str:
    if not upstream_ref:
        return ""
    repository = UPSTREAM_REPOSITORY.removesuffix(".git")
    return fetch(f"{repository}/raw/{upstream_ref}/Dockerfile")


def resolve_node(family: str) -> str:
    releases = fetch_json("https://nodejs.org/dist/index.json")
    candidates = [entry["version"].lstrip("v") for entry in releases]
    return newest(candidates, family=family)


def resolve_python(family: str) -> str:
    listing = fetch("https://www.python.org/ftp/python/")
    candidates = re.findall(r'href="(\d+\.\d+\.\d+)/"', listing)
    return newest(candidates, family=family)


def resolve_go(family: str) -> str:
    # mode=json alone lists only the supported majors; include=all reaches the
    # archived ones so an older baseline still resolves to its newest patch.
    releases = fetch_json("https://go.dev/dl/?mode=json&include=all")
    candidates = [entry["version"].removeprefix("go") for entry in releases]
    return newest(candidates, family=family)


def resolve_rust(_: str) -> str:
    manifest = fetch("https://static.rust-lang.org/dist/channel-rust-stable.toml")
    match = re.search(r'\[pkg\.rustc\]\s*\nversion = "([0-9.]+)', manifest)
    if not match:
        raise RuntimeError("no [pkg.rustc] version in the stable manifest")
    return match.group(1)


def resolve_gradle(family: str) -> str:
    releases = fetch_json("https://services.gradle.org/versions/all")
    candidates = []
    for entry in releases:
        if any(entry.get(flag) for flag in ("snapshot", "nightly", "rcFor", "milestoneFor", "broken")):
            continue
        version = entry.get("version", "")
        if re.fullmatch(r"\d+(?:\.\d+)+", version):
            candidates.append(version)
    return newest(candidates, family=family)


def resolve_gh(_: str) -> str:
    return fetch_json("https://api.github.com/repos/cli/cli/releases/latest")["tag_name"].lstrip("v")


def resolve_tea(_: str) -> str:
    return fetch_json("https://dl.gitea.com/tea/version.json")["latest"]["version"]


def resolve_bun(upstream_ref: str, fallback: str) -> str:
    dockerfile = read_upstream_dockerfile(upstream_ref)
    matches = re.findall(r"oven/bun:(\d+\.\d+\.\d+)", dockerfile)
    if not matches:
        raise RuntimeError("the upstream Dockerfile has no oven/bun:<version> tag")
    return max(matches, key=version_key)


def resolve_opencode(package: str, minimum: str, upstream_ref: str) -> str:
    try:
        tags = fetch_json(f"https://registry.npmjs.org/{package}")["dist-tags"]
        version = tags.get("latest", "")
    except Exception as error:  # noqa: BLE001
        raise RuntimeError(f"npm registry lookup for {package} failed: {error}") from error
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise RuntimeError(f"npm latest for {package} is {version or 'empty'}, expected a plain version")
    major = version.split(".")[0]
    expected_major = minimum.split(".")[0]
    if major != expected_major:
        raise RuntimeError(f"npm latest {package}@{version} is not on the {expected_major}.x line")
    if version_key(version) < version_key(minimum):
        raise RuntimeError(f"npm latest {package}@{version} is below the {minimum} floor")
    return version


def upstream_opencode_pin(upstream_ref: str) -> str:
    try:
        dockerfile = read_upstream_dockerfile(upstream_ref)
    except Exception:  # noqa: BLE001 - only used to annotate the warning
        return ""
    match = re.search(r"@opencode/cli@(\d+\.\d+\.\d+)", dockerfile)
    return match.group(1) if match else ""


def main() -> int:
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--dockerfile", default="Dockerfile")
    parser.add_argument(
        "--upstream-ref",
        default=os.environ.get("UPSTREAM_REF", ""),
        help="OpenChamber tag whose Dockerfile pins the Bun image and OpenCode CLI",
    )
    parser.add_argument(
        "--openchamber-version",
        default=os.environ.get("OPENCHAMBER_VERSION", ""),
        help="Version being built; picks the OpenCode CLI package (2.x vs 1.x)",
    )
    arguments = parser.parse_args()

    with open(arguments.dockerfile, encoding="utf-8") as handle:
        dockerfile = handle.read()

    defaults = {
        name: read_arg(dockerfile, name)
        for name in (
            "BUN_VERSION",
            "NODE_VERSION",
            "PYTHON_VERSION",
            "GO_VERSION",
            "RUST_VERSION",
            "GRADLE_VERSION",
            "GH_VERSION",
            "TEA_VERSION",
            "ANDROID_CMDLINE_VERSION",
            "ANDROID_BUILD_TOOLS_VERSION",
            "ANDROID_PLATFORM_VERSION",
            "OPENCODE_VERSION",
        )
    }
    for name, value in defaults.items():
        if not value:
            print(f"::error title=missing ARG::{name} has no default in {arguments.dockerfile}")
            return 1

    def family(version: str, parts: int) -> str:
        return ".".join(version.split(".")[:parts])

    tasks = [
        ("NODE_VERSION", f"node {family(defaults['NODE_VERSION'], 1)}.x", lambda: resolve_node(family(defaults["NODE_VERSION"], 1))),
        ("PYTHON_VERSION", f"python {family(defaults['PYTHON_VERSION'], 2)}.x", lambda: resolve_python(family(defaults["PYTHON_VERSION"], 2))),
        ("GO_VERSION", f"go {family(defaults['GO_VERSION'], 2)}.x", lambda: resolve_go(family(defaults["GO_VERSION"], 2))),
        ("RUST_VERSION", "rust stable", lambda: resolve_rust("")),
        ("GRADLE_VERSION", f"gradle {family(defaults['GRADLE_VERSION'], 1)}.x", lambda: resolve_gradle(family(defaults["GRADLE_VERSION"], 1))),
        ("GH_VERSION", "gh latest", lambda: resolve_gh("")),
        ("TEA_VERSION", "tea latest", lambda: resolve_tea("")),
        ("BUN_VERSION", "oven/bun from the upstream Dockerfile", lambda: resolve_bun(arguments.upstream_ref, defaults["BUN_VERSION"])),
    ]

    resolved: dict[str, str] = {}
    warnings: list[str] = []
    for name, label, resolver in tasks:
        try:
            resolved[name] = resolver()
        except Exception as error:  # noqa: BLE001 - fail-open by design
            resolved[name] = defaults[name]
            warnings.append(f"{name}: kept the Dockerfile default {defaults[name]} ({label}: {error})")

    # Android SDK versions are deliberately not resolved: platform/build-tools
    # upgrades are cross-family steps (API 35 -> 36 changes the compile target)
    # and stay a reviewed Dockerfile change.
    for name in ("ANDROID_CMDLINE_VERSION", "ANDROID_BUILD_TOOLS_VERSION", "ANDROID_PLATFORM_VERSION"):
        resolved[name] = defaults[name]

    try:
        major = arguments.openchamber_version.split(".")[0] or "2"
        if major == "1":
            package = "opencode-ai"
            minimum = "1.0.0"
        else:
            package = OPENCODE_PACKAGE
            minimum = OPENCODE_MINIMUM
        resolved["OPENCODE_VERSION"] = resolve_opencode(package, minimum, arguments.upstream_ref)
        resolved["OPENCODE_PACKAGE"] = package
    except Exception as error:  # noqa: BLE001 - fail-fast, see the module docstring
        print(f"::error title=OpenCode CLI resolution failed::{error}")
        return 1

    pin = upstream_opencode_pin(arguments.upstream_ref)
    if pin:
        pin_minor = version_key(pin)[:2]
        latest_minor = version_key(resolved["OPENCODE_VERSION"])[:2]
        if latest_minor[0] != pin_minor[0] or abs(latest_minor[1] - pin_minor[1]) >= 2:
            warnings.append(
                f"OpenCode CLI {resolved['OPENCODE_VERSION']} is far from the upstream pin {pin}; "
                "verify that the bundled @opencode/client still matches"
            )

    for warning in warnings:
        print(f"::warning title=Toolchain fallback::{warning}")

    output_path = os.environ.get("GITHUB_OUTPUT")
    if output_path:
        with open(output_path, "a", encoding="utf-8") as handle:
            for name, value in resolved.items():
                # Step outputs are conventionally lower case; the build args
                # that consume them stay upper case in the Dockerfile.
                handle.write(f"{name.lower()}={value}\n")

    print("Resolved bundled toolchain:")
    for name, value in resolved.items():
        print(f"  {name}={value}")

    summary_path = os.environ.get("GITHUB_STEP_SUMMARY")
    if summary_path:
        with open(summary_path, "a", encoding="utf-8") as handle:
            handle.write("### Bundled toolchain\n\n| Component | Version |\n| --- | --- |\n")
            for name, value in resolved.items():
                handle.write(f"| `{name}` | {value} |\n")
            if warnings:
                handle.write("\n**Fallbacks used:**\n\n")
                for warning in warnings:
                    handle.write(f"- {warning}\n")

    return 0


if __name__ == "__main__":
    sys.exit(main())
