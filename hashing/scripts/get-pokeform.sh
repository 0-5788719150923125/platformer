#!/usr/bin/env bash
set -euo pipefail

# Pokeform Name Generator using Markov Chains
# Generates novel Pokemon-style names from the corpus

# Associative arrays for Markov chain transitions
declare -A transitions_initial  # First letters of names
declare -A transitions          # Position-specific transitions: "pos_letter" -> "next letters"

# Get the directory where the script lives
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
POKEMON_JSON="${SCRIPT_DIR}/../static/pokemon.json"

# Parse JSON and load Pokemon names into array
load_corpus() {
    if [[ ! -f "$POKEMON_JSON" ]]; then
        echo "Error: pokemon.json not found at $POKEMON_JSON" >&2
        exit 1
    fi

    # Extract all string values from the JSON array
    # This works because pokemon.json is a simple string array
    mapfile -t CORPUS < <(grep -o '"[^"]*"' "$POKEMON_JSON" | tr -d '"')

    if [[ ${#CORPUS[@]} -eq 0 ]]; then
        echo "Error: No names loaded from corpus" >&2
        exit 1
    fi
}

# Seeded PRNG: Convert a seed string to a deterministic float between 0 and 1
# Uses md5sum to hash the seed, then converts to a decimal value
seed_random() {
    local seed="$1"

    # Try md5sum first (most common), fallback to shasum
    local hash
    if command -v md5sum >/dev/null 2>&1; then
        hash=$(echo -n "$seed" | md5sum | cut -d' ' -f1)
    elif command -v shasum >/dev/null 2>&1; then
        hash=$(echo -n "$seed" | shasum -a 256 | cut -d' ' -f1)
    else
        echo "Error: No hash function available (md5sum or shasum required)" >&2
        exit 1
    fi

    # Take first 8 hex chars and convert to decimal, then normalize to 0-1
    # Using first 8 chars gives us 32 bits of randomness (0 to 4294967295)
    local hex_part="${hash:0:8}"
    local decimal=$((16#$hex_part))

    # Use awk to convert to float between 0 and 1
    awk -v d="$decimal" 'BEGIN { printf "%.10f\n", d / 4294967296 }'
}

# Build Markov chain transition tables from corpus
build_transitions() {
    for name in "${CORPUS[@]}"; do
        # Convert to lowercase for consistency
        name="${name,,}"
        local len=${#name}

        # Skip empty names
        [[ $len -eq 0 ]] && continue

        # Record first letter
        local first_char="${name:0:1}"
        transitions_initial["$first_char"]=1

        # Build position-specific transitions
        for ((i=1; i<len; i++)); do
            local last_char="${name:$((i-1)):1}"
            local curr_char="${name:$i:1}"
            local key="${i}_${last_char}"

            # Append current char to the space-separated list
            if [[ -n "${transitions[$key]:-}" ]]; then
                transitions["$key"]="${transitions[$key]} $curr_char"
            else
                transitions["$key"]="$curr_char"
            fi
        done

        # Add END marker at the position after last character
        local last_char="${name:$((len-1)):1}"
        local key="${len}_${last_char}"
        if [[ -n "${transitions[$key]:-}" ]]; then
            transitions["$key"]="${transitions[$key]} END"
        else
            transitions["$key"]="END"
        fi
    done
}

# Select one element from a space-separated string using a seed value (0-1 float)
select_one() {
    local options_str="$1"
    local seed_value="$2"  # Float between 0 and 1
    read -ra options <<< "$options_str"
    local count=${#options[@]}

    if [[ $count -eq 0 ]]; then
        echo ""
        return
    fi

    # Convert seed_value (0-1) to an index (0 to count-1)
    local idx=$(awk -v seed="$seed_value" -v count="$count" 'BEGIN { print int(seed * count) }')
    echo "${options[$idx]}"
}

# Generate one name using Markov chain with a seed string
generate_one() {
    local seed_string="$1"
    local result=""
    local pos=0

    # Get all initial letters and pick one using seeded random
    local initials="${!transitions_initial[*]}"
    local seed_value=$(seed_random "$seed_string")
    result=$(select_one "$initials" "$seed_value")

    if [[ -z "$result" ]]; then
        echo "Error: Could not generate name - no initial letters" >&2
        exit 1
    fi

    # Generate remaining letters by walking the chain
    while true; do
        pos=$((pos + 1))

        # Mutate seed string by appending 'a' (matching daemon.ts behavior)
        seed_string="${seed_string}a"
        seed_value=$(seed_random "$seed_string")

        local last_char="${result: -1}"
        local key="${pos}_${last_char}"

        # Get possible next characters at this position after last_char
        local options="${transitions[$key]:-}"

        # If no transitions found, end the name
        if [[ -z "$options" ]]; then
            break
        fi

        local next_char=$(select_one "$options" "$seed_value")

        # Check for END marker
        if [[ "$next_char" == "END" ]]; then
            break
        fi

        result="${result}${next_char}"

        # Safety limit to prevent infinite loops
        if [[ ${#result} -gt 50 ]]; then
            break
        fi
    done

    echo "$result"
}

# Main execution
main() {
    local seed="${1:-}"

    # If no seed provided, use current timestamp + PID for uniqueness
    if [[ -z "$seed" ]]; then
        seed="$(date +%s%N)$$"
    fi

    load_corpus
    build_transitions
    generate_one "$seed"
}

main "$@"
