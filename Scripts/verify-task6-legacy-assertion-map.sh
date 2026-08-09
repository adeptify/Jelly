#!/bin/sh
set -eu

inventory_file="docs/validation/workspace-v3/task-6-legacy-test-inventory.txt"
map_file="docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
calendar_store_tests="Tests/CalendarAppTests/CalendarStoreTests.swift"
calendar_repository_tests="Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift"

case "${1:---inventory}" in
    --inventory|--complete) mode=${1:---inventory} ;;
    *)
        echo "usage: $0 [--inventory|--complete]" >&2
        exit 64
        ;;
esac

if [ ! -f "$inventory_file" ]; then
    echo "missing legacy assertion inventory: $inventory_file" >&2
    exit 1
fi
if [ ! -f "$map_file" ]; then
    echo "missing legacy assertion map: $map_file" >&2
    exit 1
fi

inventory_names=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-inventory.XXXXXX")
inventory_sorted=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-inventory-sorted.XXXXXX")
legacy_names=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-legacy.XXXXXX")
map_rows=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-map.XXXXXX")
map_names=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-map-names.XXXXXX")
map_targets=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-map-targets.XXXXXX")
trap 'rm -f "$inventory_names" "$inventory_sorted" "$legacy_names" "$map_rows" "$map_names" "$map_targets"' EXIT

if ! awk '
    NF != 2 || $1 != "UNMAPPED" || $2 !~ /^Tests\/.+\.swift::[A-Za-z0-9_]+$/ { exit 1 }
    {
        split($2, pair, "::")
        count = split(pair[1], path, "/")
        file = path[count]
        sub(/\.swift$/, "", file)
        print file "::" pair[2]
    }
' "$inventory_file" > "$inventory_names"; then
    echo "legacy assertion inventory contains malformed entries" >&2
    exit 1
fi

inventory_count=$(wc -l < "$inventory_names" | tr -d ' ')
store_count=$(awk -F'::' '$1 == "CalendarStoreTests" { count += 1 } END { print count + 0 }' "$inventory_names")
repository_count=$(awk -F'::' '$1 == "JSONCalendarRepositoryTests" { count += 1 } END { print count + 0 }' "$inventory_names")
if [ "$inventory_count" -ne 39 ] || [ "$store_count" -ne 14 ] || [ "$repository_count" -ne 25 ]; then
    echo "expected exact legacy inventory counts 14 + 25, found $store_count + $repository_count" >&2
    exit 1
fi
LC_ALL=C sort "$inventory_names" > "$inventory_sorted"
if [ "$(LC_ALL=C uniq "$inventory_sorted" | wc -l | tr -d ' ')" -ne 39 ]; then
    echo "legacy assertion inventory contains duplicate entries" >&2
    exit 1
fi

awk -F'|' '
    NR <= 4 { next }
    /^\|/ {
        legacy = $2
        target = $3
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", legacy)
        gsub(/^[[:space:]]+|[[:space:]]+$/, "", target)
        print legacy "\t" target
    }
' "$map_file" > "$map_rows"

map_count=$(wc -l < "$map_rows" | tr -d ' ')
if [ "$map_count" -ne 39 ]; then
    echo "expected exactly 39 mapping rows, found $map_count" >&2
    exit 1
fi
cut -f1 "$map_rows" | LC_ALL=C sort > "$map_names"
if [ "$(LC_ALL=C uniq "$map_names" | wc -l | tr -d ' ')" -ne 39 ]; then
    echo "legacy assertion map contains duplicate legacy rows" >&2
    exit 1
fi
if ! cmp -s "$inventory_sorted" "$map_names"; then
    echo "legacy assertion map has missing or extra inventory rows" >&2
    exit 1
fi

if [ -e "$calendar_store_tests" ] || [ -e "$calendar_repository_tests" ]; then
    if [ ! -f "$calendar_store_tests" ] || [ ! -f "$calendar_repository_tests" ]; then
        echo "legacy assertion source deletion is partial" >&2
        exit 1
    fi
    {
        sed -n 's/^[[:space:]]*@Test func \([A-Za-z0-9_]*\).*/CalendarStoreTests::\1/p' "$calendar_store_tests"
        sed -n 's/^[[:space:]]*@Test func \([A-Za-z0-9_]*\).*/JSONCalendarRepositoryTests::\1/p' "$calendar_repository_tests"
    } | LC_ALL=C sort > "$legacy_names"
    extracted_count=$(wc -l < "$legacy_names" | tr -d ' ')
    if [ "$extracted_count" -ne 39 ] || ! cmp -s "$inventory_sorted" "$legacy_names"; then
        echo "legacy assertion inventory does not exactly match the current 14 + 25 declarations" >&2
        exit 1
    fi
fi

if [ "$mode" = "--inventory" ]; then
    echo "legacy assertion inventory: exact 14 + 25 declarations and one map row per assertion"
    exit 0
fi

if awk -F'\t' 'NF < 2 || $2 == "" || $2 == "UNMAPPED" { found = 1 } END { exit found ? 0 : 1 }' "$map_rows"; then
    echo "legacy assertion migration incomplete: blank or UNMAPPED targets remain" >&2
    exit 1
fi
cut -f2 "$map_rows" | LC_ALL=C sort > "$map_targets"
if [ "$(LC_ALL=C uniq "$map_targets" | wc -l | tr -d ' ')" -ne 39 ]; then
    echo "legacy assertion map contains duplicate targets" >&2
    exit 1
fi

while IFS="$(printf '\t')" read -r legacy target; do
    case "$target" in
        Tests/*.swift::* ) ;;
        *)
            echo "invalid mapped target for $legacy: $target" >&2
            exit 1
            ;;
    esac
    target_file=${target%::*}
    target_name=${target##*::}
    if [ ! -f "$target_file" ]; then
        echo "mapped target file does not exist for $legacy: $target_file" >&2
        exit 1
    fi
    target_matches=$(sed -n 's/^[[:space:]]*@Test func \([A-Za-z0-9_]*\).*/\1/p' "$target_file" \
        | awk -v expected="$target_name" '$0 == expected { count += 1 } END { print count + 0 }')
    if [ "$target_matches" -ne 1 ]; then
        echo "mapped target test does not exist exactly once for $legacy: $target" >&2
        exit 1
    fi
done < "$map_rows"

echo "legacy assertion migration complete: 39 unique mapped tests verified"
