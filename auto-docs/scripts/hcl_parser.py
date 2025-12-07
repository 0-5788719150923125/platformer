"""Shared HCL parsing library for auto-docs generation.

Parses Terraform variable and output blocks into structured documentation.
Replaces the AWK-based parsing from generate-docs.sh and update-readme.sh.
"""

import os
import re


def extract_readme_description(dir_path):
    """Extract description from a module's README.md (first paragraph after title)."""
    readme_path = f"{dir_path}/README.md"
    try:
        with open(readme_path) as f:
            lines = f.readlines()
    except FileNotFoundError:
        return ""

    result_lines = []
    has_content = False

    for line in lines[2:]:  # Skip title and blank line (lines 1-2)
        stripped = line.rstrip("\n")

        if stripped.startswith("##"):
            break

        if stripped.strip() == "":
            if has_content:
                break
            continue

        if result_lines:
            result_lines.append("")  # Blank line between paragraphs

        result_lines.append(stripped.strip())
        has_content = True

    return "\n".join(result_lines)


def _count_braces(line):
    """Count net brace change in a line."""
    return line.count("{") - line.count("}")


def _type_of(line):
    """Classify a type expression line.

    Returns (type_label, is_collection, has_object_children) or None.
    Mirrors the AWK type_of function.
    """
    # Simple types
    if re.search(r'=\s*string', line) or re.search(r'optional\(string', line):
        return ("string", False, False)
    if re.search(r'=\s*number', line) or re.search(r'optional\(number', line):
        return ("number", False, False)
    if re.search(r'=\s*bool', line) or re.search(r'optional\(bool', line):
        return ("bool", False, False)

    # map(object(...)) - collection with children
    if re.search(r'optional\(map\(object', line):
        return ("map", True, True)
    # map(string) - collection without children
    if re.search(r'optional\(map\(string', line):
        return ("map(string)", True, False)
    # map(other) - collection without children
    if re.search(r'optional\(map\(', line):
        return ("map", True, False)

    # list(object(...)) - collection with children
    if re.search(r'=\s*list\(object', line) or re.search(r'optional\(list\(object', line):
        return ("list", True, True)

    # list(simple_type) - collection without children
    m = re.search(r'=\s*list\(([a-z]+)\)', line)
    if m:
        return (f"list({m.group(1)})", True, False)
    m = re.search(r'optional\(list\(([a-z]+)[,)]', line)
    if m:
        return (f"list({m.group(1)})", True, False)

    # list(unknown) - collection without children
    if re.search(r'=\s*list\(', line) or re.search(r'optional\(list\(', line):
        return ("list", True, False)

    # object(...) - collection with children
    if re.search(r'=\s*object\(', line) or re.search(r'optional\(object', line):
        return ("object", True, True)

    return None


def _default_val(line):
    """Extract default value from optional() type expression."""
    # optional(type, "string_value")
    m = re.search(r'optional\([^,]+,\s*"([^"]*)"', line)
    if m:
        return m.group(1)
    # optional(type, number|bool)
    m = re.search(r'optional\([^,]+,\s*([0-9]+|true|false)', line)
    if m:
        return m.group(1)
    # optional(type, {})
    if re.search(r'optional\([^,]+,\s*\{\}', line):
        return "{}"
    # optional(type, [])
    if re.search(r'optional\([^,]+,\s*\[\]', line):
        return "[]"
    return ""


def _comment_of(line):
    """Extract inline comment from a line."""
    m = re.search(r'#\s*(.+)$', line)
    if m:
        return m.group(1).rstrip()
    return ""


def _build_comment(cmt, default):
    """Build comment string combining inline comment and default annotation."""
    if default == "" or default == "{}" or default == "[]" or \
       (cmt != "" and "default" in cmt.lower()):
        return cmt
    if cmt != "":
        return f"{cmt} (default: {default})"
    return f"default: {default}"


class ConfigParser:
    """Parses variable "config" blocks into YAML example lines."""

    def parse(self, filepath):
        """Parse a variables.tf file and return YAML lines for the config variable."""
        try:
            with open(filepath) as f:
                lines = f.readlines()
        except FileNotFoundError:
            return []

        output = []
        cfg = False
        typ = False
        dep = 0
        nxt = -1
        markers = set()

        for raw_line in lines:
            line = raw_line.rstrip("\n")

            if re.match(r'^variable "config"', line):
                cfg = True
                continue

            # Handle both 'type = object({' and 'type = map(object({'
            if cfg and re.search(r'type.*=.*map\(object\(\{', line):
                # map(object({ - add <key> wrapper for map structure
                typ = True
                dep = 2  # Start at depth 2 (inside map and object)
                markers = set()
                output.append("    <key>:")  # Add map key placeholder
                markers.add(0)  # Mark depth 0 as having a map wrapper
                continue

            if cfg and re.search(r'type.*=.*object\(\{', line):
                typ = True
                dep = 1
                markers = set()
                continue

            if cfg and typ:
                d0 = dep
                # Count braces character by character
                for ch in line:
                    if ch == "{":
                        dep += 1
                    elif ch == "}":
                        dep -= 1

                # Clean up markers for depths we've exited
                if dep < d0:
                    for d in range(dep, d0):
                        markers.discard(d)

                # Check for field definition
                m = re.match(r'^\s+([a-z_][a-z0-9_]*)\s*=', line)
                if m:
                    fld = m.group(1)
                    type_info = _type_of(line)
                    if type_info is None:
                        continue

                    type_label, is_collection, has_children = type_info
                    cmt = _build_comment(_comment_of(line), _default_val(line))
                    ind = self._indent_for(d0, markers)
                    lst = (d0 == nxt)
                    pre = "- " if lst else ""
                    if lst:
                        # Remove 2 chars from indent when using list prefix
                        if len(ind) >= 2:
                            ind = ind[:-2]
                        nxt = -1

                    if is_collection and has_children:
                        # Collection with object children
                        cmt_part = f" - {cmt}" if cmt != "" else ""
                        output.append(f"{ind}{pre}{fld}:  # {type_label}{cmt_part}")
                        if type_label == "map":
                            output.append(f"{ind}  <key>:")
                            markers.add(d0)
                        elif type_label == "list":
                            nxt = dep
                            markers.add(d0)
                    elif is_collection:
                        # Collection without children (leaf collection)
                        sfx = "[]" if type_label.startswith("list") else "{}"
                        type_comment = type_label
                        if cmt != "":
                            type_comment += f" - {cmt}"
                        output.append(f"{ind}{pre}{fld}: {sfx}  # {type_comment}")
                    else:
                        # Simple scalar type
                        cmt_part = f"  # {cmt}" if cmt != "" else ""
                        output.append(f"{ind}{pre}{fld}: {type_label}{cmt_part}")

                if dep == 0:
                    typ = False
                    cfg = False

        return output

    def _indent_for(self, depth, markers):
        """Calculate indentation string for a given depth."""
        ind = "  "
        for i in range(depth):
            ind += "  "
            if (i + 1) in markers:
                ind += "  "
        return ind


class InterfaceParser:
    """Parses all variables into markdown Arguments table rows."""

    def parse(self, filepath):
        """Parse a variables.tf file and return markdown table lines."""
        try:
            with open(filepath) as f:
                lines = f.readlines()
        except FileNotFoundError:
            return []

        output = []
        first = True
        v = False
        nm = ""
        dsc = ""
        vt = ""
        has_default = False
        br = 0
        varline = 0

        for idx, raw_line in enumerate(lines, 1):
            line = raw_line.rstrip("\n")

            if re.match(r'^variable ', line):
                m = re.search(r'variable "([^"]+)"', line)
                if m:
                    nm = m.group(1)
                dsc = ""
                vt = ""
                has_default = False
                v = True
                br = 0
                varline = idx
                for ch in line:
                    if ch == "{":
                        br += 1
                    elif ch == "}":
                        br -= 1
                continue

            if v:
                prev_br = br
                for ch in line:
                    if ch == "{":
                        br += 1
                    elif ch == "}":
                        br -= 1

                # Only extract description and type at top level (prev_br==1)
                if prev_br == 1:
                    m = re.search(r'description\s*=\s*"([^"]*)"', line)
                    if m:
                        dsc = m.group(1)
                    m = re.match(r'^\s*type\s*=\s*(.+)$', line)
                    if m:
                        ln = m.group(1)
                        if re.match(r'^object\(', ln):
                            vt = "object"
                        elif re.match(r'^list\(object\(', ln):
                            vt = "list(object)"
                        elif re.match(r'^list\(', ln):
                            vt = "list"
                        elif re.match(r'^map\(object\(', ln):
                            vt = "map(object)"
                        elif re.match(r'^map\(', ln):
                            vt = "map"
                        else:
                            vt = ln

                if re.search(r'default\s*=', line) or re.search(r'optional\(', line):
                    has_default = True

                if br == 0 and v:
                    v = False
                    if first:
                        output.append("| Variable | Type | Required | Description | Ref |")
                        output.append("|----------|------|----------|-------------|-----|")
                        first = False

                    vt = vt.lstrip()

                    # Remove inline type comments
                    m = re.match(r'^([^#]+)#', vt)
                    if m:
                        vt = m.group(1).rstrip()

                    # Escape pipes in type and description
                    vt = vt.replace("|", "\\|")
                    dsc = dsc.replace("|", "\\|")

                    ref = f"[{filepath}:{varline}]({filepath}#L{varline})"
                    req = "No" if has_default else "**Yes**"
                    output.append(f"| `{nm}` | `{vt}` | {req} | {dsc} | {ref} |")

        return output


class PreflightParser:
    """Extracts required_tools from locals blocks for prerequisites documentation."""

    def parse(self, directory):
        """Scan all .tf files in a directory for locals { required_tools = { ... } }.

        Returns a list of dicts: [{"tool": name, "type": type, "commands": [cmds]}]
        """
        tools = []
        for filename in sorted(os.listdir(directory)):
            if not filename.endswith(".tf"):
                continue
            filepath = os.path.join(directory, filename)
            try:
                with open(filepath) as f:
                    lines = f.readlines()
            except (FileNotFoundError, IsADirectoryError):
                continue

            tools.extend(self._extract_tools(lines))
        return tools

    def _extract_tools(self, lines):
        """Extract tool definitions from required_tools in locals blocks."""
        tools = []
        in_locals = False
        in_required_tools = False
        in_tool = False
        brace_depth = 0
        rt_depth = 0
        tool_name = ""
        tool_type = ""
        tool_commands = []

        for raw_line in lines:
            line = raw_line.rstrip("\n").strip()

            # Track locals block entry
            if re.match(r'^locals\s*\{', raw_line.rstrip("\n")):
                in_locals = True
                brace_depth = 1
                continue

            if not in_locals:
                continue

            # Count braces
            for ch in raw_line:
                if ch == "{":
                    brace_depth += 1
                elif ch == "}":
                    brace_depth -= 1

            # Exited locals block
            if brace_depth <= 0:
                in_locals = False
                in_required_tools = False
                in_tool = False
                continue

            # Detect required_tools assignment
            if not in_required_tools and re.match(r'^\s*required_tools\s*=\s*\{', raw_line):
                in_required_tools = True
                rt_depth = brace_depth
                continue

            if not in_required_tools:
                continue

            # Exited required_tools block
            if brace_depth < rt_depth:
                in_required_tools = False
                continue

            # Detect tool entry: `tool_name = {`
            m = re.match(r'^\s*([a-zA-Z0-9_-]+)\s*=\s*\{', raw_line)
            if m and not in_tool:
                in_tool = True
                tool_name = m.group(1)
                tool_type = ""
                tool_commands = []
                continue

            if in_tool:
                # Extract type
                m = re.search(r'type\s*=\s*"([^"]+)"', line)
                if m:
                    tool_type = m.group(1)

                # Extract commands list
                m = re.search(r'commands\s*=\s*\[([^\]]+)\]', line)
                if m:
                    tool_commands = [
                        c.strip().strip('"')
                        for c in m.group(1).split(",")
                        if c.strip().strip('"')
                    ]

                # Tool block closed (line contains closing brace that isn't opening a new tool)
                if "}" in raw_line and not re.match(r'^\s*[a-zA-Z0-9_-]+\s*=\s*\{', raw_line):
                    if tool_name and tool_commands:
                        tools.append({
                            "tool": tool_name,
                            "type": tool_type,
                            "commands": tool_commands,
                        })
                    in_tool = False

        return tools


class OutputParser:
    """Parses output blocks into markdown Attributes table rows."""

    def parse(self, filepath):
        """Parse an outputs.tf file and return markdown table lines."""
        try:
            with open(filepath) as f:
                lines = f.readlines()
        except FileNotFoundError:
            return []

        output = []
        first = True
        v = False
        nm = ""
        dsc = ""
        br = 0
        outline = 0

        for idx, raw_line in enumerate(lines, 1):
            line = raw_line.rstrip("\n")

            if re.match(r'^output ', line):
                m = re.search(r'output "([^"]+)"', line)
                if m:
                    nm = m.group(1)
                dsc = ""
                v = True
                br = 0
                outline = idx
                for ch in line:
                    if ch == "{":
                        br += 1
                    elif ch == "}":
                        br -= 1
                continue

            if v:
                for ch in line:
                    if ch == "{":
                        br += 1
                    elif ch == "}":
                        br -= 1

                m = re.search(r'description\s*=\s*"([^"]*)"', line)
                if m:
                    dsc = m.group(1)

                if br == 0 and v:
                    v = False
                    if first:
                        output.append("| Output | Description | Ref |")
                        output.append("|--------|-------------|-----|")
                        first = False

                    ref = f"[{filepath}:{outline}]({filepath}#L{outline})"
                    dsc_escaped = dsc.replace("|", "\\|")
                    output.append(f"| `{nm}` | {dsc_escaped} | {ref} |")

        return output
