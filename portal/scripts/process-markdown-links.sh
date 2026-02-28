#!/bin/bash
# Process markdown content to replace relative links with Port entity URLs or GitHub URLs
# Images are base64-encoded for inline display in Port
# Input (stdin): JSON object with:
#   - content: the markdown content to process
#   - namespace: the Port namespace
#   - file_map: object mapping file paths to their identifiers (uploaded docs)
#   - repo_url: GitHub repository base URL
#   - branch: Git branch name
# Output (stdout): JSON object with processed_content

set -euo pipefail

# Read input JSON
input=$(cat)

# Extract inputs
content=$(echo "$input" | jq -r '.content')
namespace=$(echo "$input" | jq -r '.namespace')
file_map_json=$(echo "$input" | jq -r '.file_map')
repo_url=$(echo "$input" | jq -r '.repo_url')
branch=$(echo "$input" | jq -r '.branch')
source_file=$(echo "$input" | jq -r '.source_file // ""')

# Function to convert a file path to a Port identifier
# Matches the logic in documentation.tf line 233
path_to_identifier() {
  local path="$1"
  # Remove .md extension
  local no_ext="${path%.md}"
  # Remove non-alphanumeric/dot/hyphen/underscore characters
  local sanitized=$(echo "$no_ext" | sed 's/[^a-zA-Z0-9._-]//g')
  # Lowercase
  local lower=$(echo "$sanitized" | tr '[:upper:]' '[:lower:]')
  # Add namespace suffix
  echo "${lower}-${namespace}"
}

# Get all file paths from the file_map JSON
file_paths=$(echo "$file_map_json" | jq -r 'keys[]')

# Process content: replace all markdown links
processed_content="$content"

# PASS 1: Replace documentation files with Port URLs
# For each known documentation file, replace it if found
for file_path in $file_paths; do
  identifier=$(path_to_identifier "$file_path")
  port_url="https://app.us.getport.io/documentationEntity?identifier=${identifier}"

  # Replace markdown links: [text](file_path) → [text](port_url)
  # Need to escape special characters for sed
  escaped_file=$(printf '%s\n' "$file_path" | sed 's/[[\.*^$/]/\\&/g')
  escaped_url=$(printf '%s\n' "$port_url" | sed 's/[&/\]/\\&/g')

  # Replace exact file path
  processed_content=$(echo "$processed_content" | sed "s|]($escaped_file)|]($escaped_url)|g")

  # Replace with ./ prefix (relative path)
  processed_content=$(echo "$processed_content" | sed "s|](./$escaped_file)|]($escaped_url)|g")

  # Replace with ../ prefix (parent directory - try to handle)
  # This is a simplification - we only strip one level of ../
  if [[ "$file_path" == */* ]]; then
    # For paths like "compute/README.md", also match "../compute/README.md"
    processed_content=$(echo "$processed_content" | sed "s|](../$escaped_file)|]($escaped_url)|g")
  fi

  # Also try without .md extension (in case links omit it)
  if [[ "$file_path" == *.md ]]; then
    file_no_ext="${file_path%.md}"
    escaped_no_ext=$(printf '%s\n' "$file_no_ext" | sed 's/[[\.*^$/]/\\&/g')
    processed_content=$(echo "$processed_content" | sed "s|]($escaped_no_ext)|]($escaped_url)|g")
    processed_content=$(echo "$processed_content" | sed "s|](./$escaped_no_ext)|]($escaped_url)|g")
    processed_content=$(echo "$processed_content" | sed "s|](../$escaped_no_ext)|]($escaped_url)|g")
  fi
done

# PASS 2: Process images - convert to base64 data URIs
# Working directory for resolving relative paths (platformer directory)
# Script is at platformer/portal/scripts/process-markdown-links.sh
# So we need to go up 2 levels: scripts -> portal -> platformer
WORK_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

# Determine the directory of the source markdown file for resolving relative paths
if [[ -n "$source_file" ]]; then
  # Extract directory from source file path (e.g., "next/file.md" -> "next")
  source_dir=$(dirname "$source_file")
else
  source_dir=""
fi

# Use Python to handle image encoding
processed_content=$(python3 - "$processed_content" "$WORK_DIR" "$repo_url" "$branch" "$source_dir" <<'PYTHON_SCRIPT'
import sys
import re
import base64
import os

def get_mime_type(filename):
    """Detect MIME type from file extension"""
    ext = filename.lower().split('.')[-1]
    mime_types = {
        'png': 'image/png',
        'jpg': 'image/jpeg',
        'jpeg': 'image/jpeg',
        'gif': 'image/gif',
        'svg': 'image/svg+xml',
        'webp': 'image/webp',
        'bmp': 'image/bmp',
        'ico': 'image/x-icon'
    }
    return mime_types.get(ext, 'application/octet-stream')

def encode_image(image_path, work_dir, repo_url, branch, source_dir):
    """Encode image to base64 data URI or return GitHub URL as fallback"""
    # Clean up relative path prefixes
    clean_path = image_path.lstrip('./')
    clean_path = re.sub(r'^\.\.\/', '', clean_path)

    # Resolve full path relative to source file's directory
    if source_dir:
        full_path = os.path.join(work_dir, source_dir, clean_path)
        fallback_path = f"{source_dir}/{clean_path}"
    else:
        full_path = os.path.join(work_dir, clean_path)
        fallback_path = clean_path

    # Try to read and encode the file
    if os.path.isfile(full_path):
        try:
            with open(full_path, 'rb') as f:
                img_data = f.read()
            mime_type = get_mime_type(clean_path)
            encoded = base64.b64encode(img_data).decode('ascii')
            return f"data:{mime_type};base64,{encoded}"
        except Exception as e:
            print(f"Warning: Failed to encode {full_path}: {e}", file=sys.stderr)

    # Fallback: return GitHub raw URL
    return f"{repo_url}/raw/{branch}/platformer/{fallback_path}"

def process_images(content, work_dir, repo_url, branch, source_dir):
    """Process all image links in markdown content"""
    def replace_image(match):
        alt_text = match.group(1)
        image_path = match.group(2)

        # Skip if already a full URL or data URI
        if image_path.startswith(('http://', 'https://', 'data:', 'mailto:')):
            return match.group(0)

        # Skip if already a Port URL
        if 'getport.io' in image_path:
            return match.group(0)

        # Encode the image
        data_uri = encode_image(image_path, work_dir, repo_url, branch, source_dir)
        return f"![{alt_text}]({data_uri})"

    # Replace all image links
    return re.sub(r'!\[([^\]]*)\]\(([^)]+)\)', replace_image, content)

# Get arguments
content = sys.argv[1]
work_dir = sys.argv[2]
repo_url = sys.argv[3]
branch = sys.argv[4]
source_dir = sys.argv[5] if len(sys.argv) > 5 else ""

# Process images
result = process_images(content, work_dir, repo_url, branch, source_dir)

# Output result
print(result, end='')
PYTHON_SCRIPT
)

# PASS 3: Convert remaining relative paths to GitHub URLs
# Construct the base GitHub URL
github_base="${repo_url}/tree/${branch}/platformer"

# Use perl with exported variables for cleaner syntax
export GITHUB_BASE="$github_base"
processed_content=$(echo "$processed_content" | perl -pe '
  s{\]\(([^)]+)\)}{
    my $path = $1;
    my $result;

    # Check if already a full URL, fragment, or data URI
    if ($path =~ m{^https?://} || $path =~ m{^#} || $path =~ m{^mailto:} || $path =~ m{^data:}) {
      $result = "](${path})";
    }
    # Check if already converted to Port URL
    elsif ($path =~ m{getport\.io}) {
      $result = "](${path})";
    }
    # Otherwise, convert to GitHub URL
    else {
      # Clean up relative path prefixes
      $path =~ s{^\./}{};
      $path =~ s{^\.\./}{};
      # Construct GitHub URL
      my $github_url = $ENV{GITHUB_BASE} . "/" . $path;
      $result = "](${github_url})";
    }
    $result;
  }gex
')

# PASS 4: Replace unsupported HTML tags with Port-supported equivalents
# Port's markdown renderer allowlists specific HTML tags. Tags not on the list
# are stripped silently, breaking formatting. Map to closest supported tag:
#   <ins>  → <u>    (underline  -  semantic insert marker → visual underline)
#   <del>  → <s>    (strikethrough  -  semantic delete marker → visual strikethrough)
processed_content=$(echo "$processed_content" | sed \
  -e 's/<ins>/<u>/g' -e 's/<\/ins>/<\/u>/g' \
  -e 's/<del>/<s>/g' -e 's/<\/del>/<\/s>/g')

# Return processed content as JSON
# Use stdin to avoid "Argument list too long" for large files (e.g., SCHEMA.md)
printf '%s' "$processed_content" | jq -Rs '{"processed_content": .}'
