#!/usr/bin/env python3
"""Auto-documentation generator for Platformer modules.

Parses variables.tf files and generates SCHEMA.md.
Replaces generate-docs.sh (Bash+AWK implementation).
"""

import hashlib
import json
import os
import sys

from hcl_parser import ConfigParser, InterfaceParser, OutputParser, extract_readme_description


def discover_modules(project_root):
    """Find all modules with variables.tf, excluding auto-docs and .terraform."""
    modules = []
    for dirpath, dirnames, filenames in os.walk(project_root):
        # Prune excluded directories
        dirnames[:] = [d for d in dirnames if d not in (".terraform",)]
        rel = os.path.relpath(dirpath, project_root)
        if "auto-docs" in rel.split(os.sep):
            continue
        if "variables.tf" in filenames:
            if rel == ".":
                mod_name = "root"
            else:
                mod_name = os.path.basename(dirpath)
            dir_display = f"./{rel}" if rel != "." else "."
            vf_path = os.path.join(dir_display, "variables.tf")
            modules.append((mod_name, dir_display, vf_path))

    modules.sort(key=lambda x: x[0])
    return modules


def has_config_variable(filepath):
    """Check if a file contains a variable "config" block."""
    try:
        with open(filepath) as f:
            for line in f:
                if line.startswith('variable "config"'):
                    return True
    except FileNotFoundError:
        pass
    return False


def main():
    query = json.load(sys.stdin)
    project_root = query["project_root"]
    output_file = query["output_file"]

    # Resolve paths relative to script location
    script_dir = os.path.dirname(os.path.abspath(__file__))
    os.chdir(os.path.join(script_dir, "..", project_root))

    config_parser = ConfigParser()
    interface_parser = InterfaceParser()
    output_parser = OutputParser()

    modules = discover_modules(".")

    # Build TOC
    toc_lines = []
    for mod_name, _, _ in modules:
        toc_lines.append(f"- [{mod_name}](#module-{mod_name})")

    # Build module sections
    section_lines = []
    for mod_name, dir_display, vf_path in modules:
        section_lines.append("")
        section_lines.append(f"## Module: {mod_name}")
        section_lines.append("")
        section_lines.append(f"Path: [`{dir_display}`]({dir_display})")
        section_lines.append("")

        # Add description from README if available
        description = extract_readme_description(dir_display)
        if description:
            section_lines.append(description)
            section_lines.append("")

        # Config YAML structure
        if has_config_variable(vf_path):
            yaml_lines = config_parser.parse(vf_path)
            if yaml_lines:
                section_lines.append("### State Fragment Structure")
                section_lines.append("")
                section_lines.append("```yaml")
                section_lines.append("services:")
                section_lines.append(f"  {mod_name}:")
                section_lines.extend(yaml_lines)
                section_lines.append("```")
                section_lines.append("")

        # Arguments table
        args_lines = interface_parser.parse(vf_path)
        has_args = False
        if args_lines:
            section_lines.append("### Arguments")
            section_lines.append("")
            section_lines.append("This module supports the following arguments:")
            section_lines.append("")
            section_lines.extend(args_lines)
            has_args = True

        # Attributes table
        outfile = os.path.join(dir_display, "outputs.tf")
        if os.path.isfile(outfile):
            attrs_lines = output_parser.parse(outfile)
            if attrs_lines:
                if has_args:
                    section_lines.append("")
                section_lines.append("### Attributes")
                section_lines.append("")
                section_lines.append("This module exports the following attributes:")
                section_lines.append("")
                section_lines.extend(attrs_lines)

    # Assemble the document
    header = [
        "# Platformer Module Schema",
        "",
        "Auto-generated from variables.tf and outputs.tf files. Do not edit manually.",
        "",
        "This document shows the YAML structure for state fragments in `states/` directory.",
        "",
        "## Supported Modules",
        "",
    ]

    all_lines = header + toc_lines + [""] + section_lines

    # Remove trailing blank line (match bash behavior: head -n -1)
    while all_lines and all_lines[-1] == "":
        all_lines.pop()

    content = "\n".join(all_lines) + "\n"

    with open(output_file, "w") as f:
        f.write(content)

    content_hash = hashlib.md5(content.encode()).hexdigest()
    json.dump({"content_hash": content_hash, "module_count": str(len(modules))}, sys.stdout)


if __name__ == "__main__":
    main()
