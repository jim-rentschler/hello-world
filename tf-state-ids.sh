#!/usr/bin/env bash
#
# tf-state-ids.sh - Print the import IDs for a list of Terraform resources,
# read from `terraform state show`.
#
# Run it from the OLD repo's directory, after `terraform init` has connected
# to the right environment's backend. It only reads state; it never changes it.
#
# Usage:
#   ./tf-state-ids.sh [options] ADDRESS [ADDRESS ...]
#   ./tf-state-ids.sh [options] -f addresses.txt
#
# Options:
#   -f FILE     Read addresses from FILE, one per line (blank lines and
#               lines starting with # are ignored)
#   -o FORMAT   Output format: "table" (default), "import" (import blocks
#               with hardcoded IDs) or "tfvars" (an import_ids map for a
#               generic imports.tf)
#   -s PREFIX   Import/tfvars modes: strip PREFIX from each address, e.g.
#               -s module.database.  when the resources sit at the root
#               of the new repo
#   -h          Show this help
#
# Examples:
#   ./tf-state-ids.sh aws_db_instance.main aws_db_subnet_group.main
#   ./tf-state-ids.sh -f db-resources.txt -o import > imports.tf
#   ./tf-state-ids.sh -f db-resources.txt -o import -s module.database.
#   ./tf-state-ids.sh -f db-resources.txt -o tfvars > devtest.imports.tfvars
#
# Warnings go to stderr, so redirecting stdout to a file stays clean.

set -uo pipefail

format="table"
strip_prefix=""
addr_file=""
addresses=()

usage() { sed -n '2,/^$/p' "$0" | sed 's/^# \{0,1\}//'; }

while getopts ":f:o:s:h" opt; do
  case "$opt" in
    f) addr_file="$OPTARG" ;;
    o) format="$OPTARG" ;;
    s) strip_prefix="$OPTARG" ;;
    h) usage; exit 0 ;;
    :) echo "Option -$OPTARG needs a value" >&2; exit 1 ;;
    *) echo "Unknown option -$OPTARG" >&2; usage >&2; exit 1 ;;
  esac
done
shift $((OPTIND - 1))

if [[ "$format" != "table" && "$format" != "import" && "$format" != "tfvars" ]]; then
  echo "Format must be 'table', 'import' or 'tfvars'" >&2
  exit 1
fi

if [[ -n "$addr_file" ]]; then
  if [[ ! -f "$addr_file" ]]; then
    echo "File not found: $addr_file" >&2
    exit 1
  fi
  while IFS= read -r line || [[ -n "$line" ]]; do
    line="${line%%#*}"                                  # drop comments
    line="$(echo "$line" | sed 's/^[[:space:]]*//;s/[[:space:]]*$//')"
    [[ -n "$line" ]] && addresses+=("$line")
  done < "$addr_file"
fi
addresses+=("$@")

if [[ ${#addresses[@]} -eq 0 ]]; then
  echo "No resource addresses given." >&2
  usage >&2
  exit 1
fi

if ! command -v terraform > /dev/null 2>&1; then
  echo "terraform not found on PATH" >&2
  exit 1
fi

# Reads `terraform state show` output and prints three lines:
# the resource type, the top-level "id", and the top-level "identifier".
# Top-level attributes are indented exactly 4 spaces; nested blocks are
# indented further, so their id fields are ignored.
parse_state_show() {
  awk '
    function val(line) {
      sub(/^[^=]*=[[:space:]]*/, "", line)
      sub(/^"/, "", line); sub(/"$/, "", line)
      return line
    }
    /^resource "/ && type == "" {
      split($0, parts, "\""); type = parts[2]
    }
    /^    id[[:space:]]+=/         && id == ""    { id = val($0) }
    /^    identifier[[:space:]]+=/ && ident == "" { ident = val($0) }
    END { print type; print id; print ident }
  '
}

failures=0
found=0

[[ "$format" == "tfvars" ]] && printf 'import_ids = {\n'

for addr in "${addresses[@]}"; do
  if [[ "$addr" == data.* || "$addr" == *.data.* ]]; then
    echo "SKIP  $addr: data sources are not imported" >&2
    continue
  fi

  if ! output="$(terraform state show -no-color "$addr" 2>&1)"; then
    echo "ERROR $addr: $(echo "$output" | head -n 3 | tr '\n' ' ')" >&2
    failures=$((failures + 1))
    continue
  fi

  parsed="$(echo "$output" | parse_state_show)"
  type="$(sed -n 1p <<< "$parsed")"
  id="$(sed -n 2p <<< "$parsed")"
  ident="$(sed -n 3p <<< "$parsed")"

  import_id="$id"
  case "$type" in
    aws_db_instance)
      # AWS provider v5+ stores the DBI resource ID (db-XXXX) in "id",
      # but import needs the instance identifier.
      [[ -n "$ident" ]] && import_id="$ident"
      ;;
    aws_security_group_rule)
      echo "WARN  $addr: the import ID is a composite string" \
           "(sg_type_protocol_from_to_source), not \"$id\". Build it by hand." >&2
      ;;
    random_password|random_string)
      echo "WARN  $addr: imported using the secret value itself." \
           "Not printed here; handle it separately." >&2
      continue
      ;;
  esac

  if [[ -z "$import_id" ]]; then
    echo "WARN  $addr: no top-level id found; check the state show output" >&2
    failures=$((failures + 1))
    continue
  fi

  found=$((found + 1))
  if [[ "$format" == "table" ]]; then
    printf '%s\t%s\n' "$addr" "$import_id"
  elif [[ "$format" == "import" ]]; then
    to="${addr#"$strip_prefix"}"
    printf 'import {\n  to = %s\n  id = "%s"\n}\n\n' "$to" "$import_id"
  else
    to="${addr#"$strip_prefix"}"
    key="${to//\"/\\\"}"            # escape quotes inside ["key"] indexes
    printf '  "%s" = "%s"\n' "$key" "$import_id"
  fi
done

[[ "$format" == "tfvars" ]] && printf '}\n'

echo "Done: $found found, $failures failed." >&2
[[ $failures -eq 0 ]]
