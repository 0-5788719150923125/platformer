#!/usr/bin/env python3
"""
md2pdf.py - Convert Markdown files to styled PDFs via WeasyPrint.

Usage:
    python md2pdf.py input.md                  # outputs input.pdf
    python md2pdf.py input.md -o output.pdf    # custom output name
    python md2pdf.py input.md --portrait       # portrait orientation (default: landscape)
    python md2pdf.py input.md --html           # also save the intermediate HTML

Requirements:
    pip install weasyprint markdown
"""

import argparse
import os
import sys
import markdown
from weasyprint import HTML

CSS_TEMPLATE = """
  @page {{
    size: {orientation};
    margin: 0.5in 0.65in;
  }}

  *, *::before, *::after {{
    box-sizing: border-box;
  }}

  body {{
    font-family: 'DejaVu Sans', 'Helvetica Neue', Helvetica, Arial, sans-serif;
    font-size: 8.5pt;
    line-height: 1.45;
    color: #1a1a1a;
    max-width: 100%;
  }}

  h1 {{
    font-size: 20pt;
    font-weight: 700;
    margin-bottom: 0.15in;
    color: #111;
    border-bottom: 2px solid #333;
    padding-bottom: 0.08in;
  }}

  h2 {{
    font-size: 13pt;
    font-weight: 700;
    margin-top: 0.3in;
    margin-bottom: 0.12in;
    color: #222;
  }}

  h1 + p {{
    font-style: italic;
    color: #555;
    font-size: 9.5pt;
    margin-bottom: 0.15in;
  }}

  p {{
    margin: 0.08in 0;
    text-align: left;
    orphans: 3;
    widows: 3;
  }}

  em {{ color: #333; }}

  hr {{
    border: none;
    border-top: 1px solid #ccc;
    margin: 0.2in 0;
  }}

  /* === TABLE STYLING === */
  table {{
    width: 100%;
    border-collapse: collapse;
    table-layout: fixed;
    margin: 0.15in 0;
    font-size: 7.8pt;
    line-height: 1.4;
    page-break-inside: auto;
    box-sizing: border-box;
  }}

  thead {{
    display: table-header-group;
  }}

  tr {{
    page-break-inside: avoid;
  }}

  th {{
    background-color: #1a1a2e;
    color: #fff;
    font-weight: 600;
    font-size: 8pt;
    text-align: left;
    padding: 6px 8px;
    border: 1px solid #1a1a2e;
    vertical-align: middle;
  }}

  td {{
    padding: 6px 8px;
    border: 1px solid #d0d0d0;
    vertical-align: top;
    word-wrap: break-word;
    overflow-wrap: break-word;
    hyphens: auto;
  }}

  /* Column widths — adjust these for your table structure */
  th:nth-child(1), td:nth-child(1) {{ width: 12%; font-weight: 600; hyphens: none; overflow-wrap: normal; word-break: normal; }}
  th:nth-child(2), td:nth-child(2) {{ width: 26%; }}
  th:nth-child(3), td:nth-child(3) {{ width: 26%; }}
  th:nth-child(4), td:nth-child(4) {{ width: 36%; }}

  /* Alternating row colors */
  tbody tr:nth-child(even) {{
    background-color: #f7f7fa;
  }}
  tbody tr:nth-child(odd) {{
    background-color: #ffffff;
  }}

  td strong {{
    color: #111;
    font-size: 8pt;
  }}

  td:first-child strong {{
    font-size: 8.2pt;
    color: #1a1a2e;
  }}

  ins {{
    text-decoration: none;
    font-weight: 700;
    color: #2a5a8a;
  }}

  ol, ul {{
    padding-left: 0.2in;
    margin: 0.06in 0;
  }}

  li {{
    margin-bottom: 0.04in;
  }}

  blockquote {{
    border-left: 3px solid #2a5a8a;
    padding-left: 0.12in;
    margin: 0.1in 0;
    color: #444;
    font-style: italic;
  }}
"""

HTML_TEMPLATE = """<!DOCTYPE html>
<html>
<head>
<meta charset="utf-8">
<style>{css}</style>
</head>
<body>
{body}
</body>
</html>
"""


def convert(input_path, output_path=None, orientation="landscape", save_html=False):
    if not os.path.isfile(input_path):
        print(f"Error: {input_path} not found.", file=sys.stderr)
        sys.exit(1)

    if output_path is None:
        output_path = os.path.splitext(input_path)[0] + ".pdf"

    with open(input_path, "r", encoding="utf-8") as f:
        md_content = f.read()

    html_body = markdown.markdown(md_content, extensions=["tables", "extra"])
    css = CSS_TEMPLATE.format(orientation=orientation)
    html_doc = HTML_TEMPLATE.format(css=css, body=html_body)

    if save_html:
        html_path = os.path.splitext(output_path)[0] + ".html"
        with open(html_path, "w", encoding="utf-8") as f:
            f.write(html_doc)
        print(f"HTML saved: {html_path}")

    HTML(string=html_doc).write_pdf(output_path)
    print(f"PDF saved:  {output_path}")


def main():
    parser = argparse.ArgumentParser(description="Convert Markdown to a styled PDF.")
    parser.add_argument("input", help="Path to the Markdown file")
    parser.add_argument("-o", "--output", help="Output PDF path (default: same name as input)")
    parser.add_argument("--portrait", action="store_true", help="Use portrait orientation (default: landscape)")
    parser.add_argument("--html", action="store_true", help="Also save the intermediate HTML file")
    args = parser.parse_args()

    orientation = "portrait" if args.portrait else "landscape"
    convert(args.input, args.output, orientation, args.html)


if __name__ == "__main__":
    main()