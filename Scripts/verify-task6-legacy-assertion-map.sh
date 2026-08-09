#!/bin/sh
set -eu

map_file="docs/validation/workspace-v3/task-6-legacy-test-inventory.txt"
calendar_store_tests="Tests/CalendarAppTests/CalendarStoreTests.swift"
calendar_repository_tests="Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift"

if [ ! -f "$map_file" ]; then
    echo "missing legacy assertion map: $map_file" >&2
    exit 1
fi

line_count=$(wc -l < "$map_file" | tr -d ' ')
if [ "$line_count" -ne 39 ]; then
    echo "expected 39 legacy assertions, found $line_count" >&2
    exit 1
fi

if ! awk 'NF != 2 || $1 != "UNMAPPED" || $2 !~ /\.swift::[A-Za-z0-9_]+$/ { exit 1 }' "$map_file"; then
    echo "inventory must contain 39 well-formed UNMAPPED legacy assertion entries" >&2
    exit 1
fi

inventory_names=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-inventory.XXXXXX")
legacy_names=$(mktemp "${TMPDIR:-/tmp}/jelly-task6-legacy.XXXXXX")
trap 'rm -f "$inventory_names" "$legacy_names"' EXIT

awk '{ print $2 }' "$map_file" | LC_ALL=C sort > "$inventory_names"
if [ "$(LC_ALL=C uniq "$inventory_names" | wc -l | tr -d ' ')" -ne 39 ]; then
    echo "legacy assertion inventory contains duplicate entries" >&2
    exit 1
fi

if [ -f "$calendar_store_tests" ] && [ -f "$calendar_repository_tests" ]; then
    {
        sed -n 's/^[[:space:]]*@Test func \([A-Za-z0-9_]*\).*/Tests\/CalendarAppTests\/CalendarStoreTests.swift::\1/p' "$calendar_store_tests"
        sed -n 's/^[[:space:]]*@Test func \([A-Za-z0-9_]*\).*/Tests\/CalendarPersistenceTests\/JSONCalendarRepositoryTests.swift::\1/p' "$calendar_repository_tests"
    } | LC_ALL=C sort > "$legacy_names"
    extracted_count=$(wc -l < "$legacy_names" | tr -d ' ')
    if [ "$extracted_count" -ne 39 ] || ! cmp -s "$inventory_names" "$legacy_names"; then
        echo "legacy assertion inventory does not exactly match the current 25 + 14 test declarations" >&2
        exit 1
    fi
fi

case "${1:---inventory}" in
    --inventory)
        echo "legacy assertion inventory: exact 25 + 14 declarations, all intentionally UNMAPPED for Task 6A"
        ;;
    --complete)
        echo "legacy assertion migration incomplete: UNMAPPED entries remain" >&2
        exit 1
        ;;
    *)
        echo "usage: $0 [--inventory|--complete]" >&2
        exit 64
        ;;
esac
