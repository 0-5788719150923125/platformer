#!/usr/bin/env python3
"""Regenerate the marked sections of README.md.

Each generated section sits between a pair of comments, and nothing outside
them is touched:

    <!-- AUTODOC:MODULES:BEGIN -->        every top-level module (has main.tf)
    <!-- AUTODOC:LAYOUT:BEGIN -->         everything else at the top level
    <!-- AUTODOC:PREREQUISITES:BEGIN -->  tools modules check for (required_tools)

A section whose markers are missing is skipped.
"""

import hashlib
import json
import os
import re
import sys

from hcl_parser import extract_readme_description, PreflightParser

# Top-level directories without a README of their own
LAYOUT_FALLBACKS = {
    "learn": "Walkthroughs: getting started, going live, and composing modules.",
    "next": "Essays on the design: why Platformer is shaped the way it is, and where it goes next.",
    "present": "A slide deck: the problem, the solution, and the patterns in between.",
    "scripts": "Helper scripts. `build-providers.sh` builds the cloud providers; the rest record applies and generate CI matrices.",
    "static": "Images used in the README.",
}

# Root files worth knowing, in display order
ROOT_FILES = [
    ("main.tf", "Wires every module together: config in, requests routed between modules."),
    ("providers.tf", "The clouds, each with an `enabled` switch that follows the workspace's profiles."),
    ("top.yaml", "Multi-account targeting: account patterns mapped to state fragments."),
    ("terraform.tfvars", "Local configuration: profiles, region, and the state fragments to load. `terraform.tfvars.<workspace>` overrides it per workspace."),
    ("SCHEMA.md", "Every option a state fragment can set, generated from the modules' variables."),
]

SKIP_DIRS = {".terraform", ".git", "terraform.tfstate.d"}


def first_sentence(text):
    """The first sentence of a README's opening paragraph."""
    text = " ".join(text.split())
    match = re.search(r"[.!?](?=\s+[A-Z(`*])", text)
    sentence = text[: match.end()] if match else text
    return sentence.rstrip(":")


def describe(d, fallback=""):
    description = extract_readme_description(d)
    return first_sentence(description) if description else fallback


def link(d):
    return f"{d}/README.md" if os.path.isfile(os.path.join(d, "README.md")) else f"{d}/"


def modules_section(dirs):
    lines = []
    for d in dirs:
        if os.path.isfile(os.path.join(d, "main.tf")):
            lines.append(f"- **[`{d}/`]({link(d)})** - {describe(d, f'The {d} module.')}")
    return lines


def layout_section(dirs):
    lines = []
    for d in dirs:
        if not os.path.isfile(os.path.join(d, "main.tf")):
            description = describe(d, LAYOUT_FALLBACKS.get(d, ""))
            lines.append(f"- **[`{d}/`]({link(d)})**" + (f" - {description}" if description else ""))
    for name, description in ROOT_FILES:
        if os.path.isfile(name):
            lines.append(f"- **[`{name}`]({name})** - {description}")
    return lines


def prerequisites_section(dirs):
    """Tools that modules check for at plan time (preflight required_tools)."""
    parser = PreflightParser()
    tools = {}
    for d in dirs:
        for tool in parser.parse(d):
            entry = tools.setdefault(tool["tool"], {"commands": tool["commands"], "type": tool["type"], "modules": []})
            if d not in entry["modules"]:
                entry["modules"].append(d)

    lines = []
    for name in sorted(tools):
        info = tools[name]
        commands = info["commands"]
        if info["type"] == "any" and len(commands) > 1:
            display = " or ".join(f"`{c}`" for c in commands)
        else:
            display = f"`{commands[0]}`"
        lines.append(f"- {display} ({', '.join(sorted(info['modules']))})")
    return lines


def replace_section(content, name, lines):
    begin = f"<!-- AUTODOC:{name}:BEGIN -->"
    end = f"<!-- AUTODOC:{name}:END -->"
    pattern = re.compile(re.escape(begin) + r".*?" + re.escape(end), re.DOTALL)
    if not pattern.search(content):
        return content
    body = "\n".join(lines)
    return pattern.sub(lambda _: f"{begin}\n\n{body}\n\n{end}", content, count=1)


def main():
    query = json.load(sys.stdin)
    project_root = query["project_root"]
    readme_file = query["readme_file"]

    # Resolve paths relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(os.path.join(script_dir, "..", project_root))

    if not os.path.isfile(readme_file):
        print(f"Error: README file not found: {readme_file}", file=sys.stderr)
        sys.exit(1)

    dirs = sorted(
        d for d in os.listdir(".")
        if os.path.isdir(d) and d not in SKIP_DIRS and not d.startswith(".")
    )

    with open(readme_file) as f:
        content = f.read()

    updated = replace_section(content, "MODULES", modules_section(dirs))
    updated = replace_section(updated, "LAYOUT", layout_section(dirs))
    updated = replace_section(updated, "PREREQUISITES", prerequisites_section(dirs))

    if updated != content:
        with open(readme_file, "w") as f:
            f.write(updated)

    content_hash = hashlib.md5(updated.encode()).hexdigest()
    json.dump({"content_hash": content_hash, "status": "updated"}, sys.stdout)


if __name__ == "__main__":
    main()
