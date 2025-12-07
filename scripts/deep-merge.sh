#!/usr/bin/env bash
# Shared jq deep merge function
# Usage: source this file to make DEEP_MERGE available

# Generic deep merge function for jq
# Objects: merge recursively
# Arrays of objects with "name" field: merge by name (override wins)
# Arrays of objects with "key" field (no "name"): merge by key (override wins)
# Arrays of objects without identifying field: concatenate (no merge)
# Arrays of primitives: concatenate + deduplicate
# Primitives: override
read -r -d '' DEEP_MERGE <<'EOF' || true
def deep_merge:
  . as [$base, $override] |
  if ($base | type) == "object" and ($override | type) == "object" then
    ($base + $override) | to_entries | map(
      if $base[.key] and $override[.key] then
        .value = ([$base[.key], $override[.key]] | deep_merge)
      else . end
    ) | from_entries
  elif ($base | type) == "array" and ($override | type) == "array" then
    # Check if this is an array of objects with a common merge key
    if ($base | length > 0) and ($base[0] | type == "object") then
      # Determine merge key: "name" (preferred) or "key" (fallback)
      if ($base[0] | has("name")) then
        # Array of named objects: merge by name
        (
          ($base | map({(.name): .}) | add) as $base_map |
          ($override | map({(.name): .}) | add) as $override_map |
          (($base_map + $override_map) | to_entries | map(
            if $base_map[.key] and $override_map[.key] then
              # Both base and override have this name: deep merge them
              ([$base_map[.key], $override_map[.key]] | deep_merge)
            else
              # Only one side has this name: use as-is
              .value
            end
          ))
        )
      elif ($base[0] | has("key")) then
        # Array of keyed objects: merge by key field
        (
          ($base | map({(.key): .}) | add) as $base_map |
          ($override | map({(.key): .}) | add) as $override_map |
          (($base_map + $override_map) | to_entries | map(
            if $base_map[.key] and $override_map[.key] then
              # Both base and override have this key: deep merge them
              ([$base_map[.key], $override_map[.key]] | deep_merge)
            else
              # Only one side has this key: use as-is
              .value
            end
          ))
        )
      else
        # Objects without identifying field: concatenate (no deduplication possible)
        ($base + $override)
      end
    else
      # Primitive array: concatenate and deduplicate
      ($base + $override | unique)
    end
  else
    $override
  end;
EOF

export DEEP_MERGE
