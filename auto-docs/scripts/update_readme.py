#!/usr/bin/env python3
"""Auto-update specific sections of README.md.

Updates Architecture and Available Services sections with current module state.
Replaces update-readme.sh (Bash+AWK implementation).
"""

import hashlib
import json
import os
import subprocess
import sys

from hcl_parser import extract_readme_description, PreflightParser


def get_directory_type(dir_path):
    """Determine directory type based on contents."""
    # Check for test files first (highest priority)
    for entry in os.listdir(dir_path):
        if entry.endswith(".tftest.hcl"):
            return "test"
    # Check for service module (has main.tf)
    if os.path.isfile(os.path.join(dir_path, "main.tf")):
        return "service"
    # Everything else is documentation
    return "docs"


def generate_architecture_section(dirs, max_width):
    """Generate Architecture section content."""
    lines = []
    lines.append("### Project Structure")
    lines.append("")
    lines.append("```")

    # .github section with dynamic width
    lines.append(".github/")
    lines.append(f"\u251c\u2500\u2500 {'actions/':<{max_width}} # Reusable compositions")
    lines.append(f"\u2514\u2500\u2500 {'workflows/terraform.yml':<{max_width}} # Unified matrix deployments")
    lines.append("")
    lines.append("platformer/")

    type_labels = {
        "service": "# Service module",
        "test": "# Test automation",
        "docs": "# Documentation",
    }

    for d in dirs:
        dir_type = get_directory_type(d)
        label = type_labels[dir_type]
        dir_display = f"{d}/"
        lines.append(f"\u251c\u2500\u2500 {dir_display:<{max_width}} {label}")

    # Add special entries at the end with same alignment
    lines.append(f"\u251c\u2500\u2500 {'main.tf':<{max_width}} # Service orchestration")
    lines.append(f"\u2514\u2500\u2500 {'top.yaml':<{max_width}} # Multi-account targeting")
    lines.append("```")

    return lines


def generate_services_section(dirs):
    """Generate Available Services section content."""
    lines = []
    for d in dirs:
        if not os.path.isfile(os.path.join(d, "main.tf")):
            continue

        description = extract_readme_description(d)
        if not description:
            description = f"{d} module"

        # Truncate to first line
        description = description.split("\n")[0]

        if os.path.isfile(os.path.join(d, "README.md")):
            link_target = f"{d}/README.md"
        else:
            link_target = d

        lines.append(f"- **{d}**: {description} ([docs](./{link_target}))")

    return lines


def collect_prerequisites(dirs):
    """Scan all modules for required_tools in locals blocks.

    Returns a dict: {tool_name: {"commands": [...], "type": str, "modules": [str]}}
    """
    parser = PreflightParser()
    aggregated = {}

    for d in dirs:
        if not os.path.isdir(d):
            continue
        tools = parser.parse(d)
        for tool in tools:
            name = tool["tool"]
            if name not in aggregated:
                aggregated[name] = {
                    "commands": tool["commands"],
                    "type": tool["type"],
                    "modules": [],
                }
            if d not in aggregated[name]["modules"]:
                aggregated[name]["modules"].append(d)

    return aggregated


def generate_prerequisites_section(prerequisites):
    """Generate Prerequisites section content."""
    if not prerequisites:
        return []

    lines = []
    lines.append("The following tools must be available in `PATH` for full functionality:")
    lines.append("")
    lines.append("| Tool | Type | Modules |")
    lines.append("|------|------|---------|")

    for tool_name in sorted(prerequisites.keys()):
        info = prerequisites[tool_name]
        commands = info["commands"]
        modules = ", ".join(sorted(info["modules"]))
        check_type = info["type"]

        # For 'any' type, show alternatives
        if check_type == "any" and len(commands) > 1:
            display = " or ".join(f"`{c}`" for c in commands)
        else:
            display = f"`{commands[0]}`"

        lines.append(f"| {display} | {check_type} | {modules} |")

    return lines


def calculate_max_width(dirs):
    """Calculate maximum width for column alignment."""
    max_width = 0

    # Check directory entries (with trailing slash)
    for d in dirs:
        length = len(d) + 1  # +1 for trailing slash
        if length > max_width:
            max_width = length

    # Check special entries
    for entry in ("main.tf", "top.yaml", "actions/", "workflows/terraform.yml"):
        if len(entry) > max_width:
            max_width = len(entry)

    # Add buffer
    return max_width + 2


def update_readme(readme_path, arch_lines, services_lines, prerequisites_lines):
    """Update README with new Architecture, Services, and Prerequisites content."""
    with open(readme_path) as f:
        original_lines = f.readlines()

    arch_content = "\n".join(arch_lines)
    services_content = "\n".join(services_lines)
    prerequisites_content = "\n".join(prerequisites_lines)

    output = []
    state = "NORMAL"
    fence_count = 0

    for raw_line in original_lines:
        line = raw_line.rstrip("\n")

        # Architecture section start - preserve intro and design principles
        if line == "## Architecture":
            output.append(line)
            state = "ARCH_PRESERVE"
            fence_count = 0
            continue

        # When we hit Project Structure heading or code fence, insert generated content
        if state == "ARCH_PRESERVE" and (line == "### Project Structure" or line == "```"):
            output.append(arch_content)
            state = "ARCH_REPLACE"
            fence_count = 0
            continue

        # Count fences in architecture section to know when done replacing
        if state == "ARCH_REPLACE" and line == "```":
            fence_count += 1
            if fence_count >= 2:
                state = "NORMAL"
                fence_count = 0
            continue

        # Available Services section start
        if line == "## Available Services":
            output.append(line)
            output.append("")
            output.append(services_content)
            state = "SERVICES_SKIP"
            continue

        # Prerequisites section start
        if line == "## Prerequisites":
            output.append(line)
            output.append("")
            output.append(prerequisites_content)
            output.append("")
            state = "PREREQ_SKIP"
            continue

        # Any other section heading resets all modes
        if line.startswith("## ") and state in (
            "ARCH_PRESERVE", "ARCH_REPLACE", "SERVICES_SKIP", "PREREQ_SKIP"
        ):
            state = "NORMAL"
            fence_count = 0
            output.append(line)
            continue

        # Preserve mode: print everything (intro text and design principles)
        if state == "ARCH_PRESERVE":
            output.append(line)
            continue

        # Skip old content while in replacement mode
        if state == "ARCH_REPLACE":
            continue

        # In services section, skip until we find the auto-enabling paragraph
        if state == "SERVICES_SKIP":
            if line.startswith("**Auto-enabling services**:"):
                output.append("")  # Blank line before auto-enabling paragraph
                state = "NORMAL"
                output.append(line)
            continue

        # In prerequisites section, skip all content until next heading
        if state == "PREREQ_SKIP":
            continue

        # Print everything else
        output.append(line)

    content = "\n".join(output) + "\n"

    with open(readme_path, "w") as f:
        f.write(content)

    return content


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

    # Discover directories
    dirs = sorted(
        d for d in os.listdir(".")
        if os.path.isdir(d) and d not in (".", ".terraform", ".git", "terraform.tfstate.d")
        and not d.startswith(".")
    )

    max_width = calculate_max_width(dirs)

    arch_lines = generate_architecture_section(dirs, max_width)
    services_lines = generate_services_section(dirs)
    prerequisites = collect_prerequisites(dirs)
    prerequisites_lines = generate_prerequisites_section(prerequisites)

    content = update_readme(readme_file, arch_lines, services_lines, prerequisites_lines)

    content_hash = hashlib.md5(content.encode()).hexdigest()
    json.dump({"content_hash": content_hash, "status": "updated"}, sys.stdout)


if __name__ == "__main__":
    main()
