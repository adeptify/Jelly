#!/bin/sh
set -eu

repo_root=$(CDPATH= cd -- "$(dirname "$0")/.." && pwd)
verifier="$repo_root/Scripts/verify-task6-legacy-assertion-map.sh"
fixture_root=$(mktemp -d "${TMPDIR:-/tmp}/jelly-task6-map-tests.XXXXXX")
trap 'rm -rf "$fixture_root"' EXIT

make_fixture() {
    case_name=$1
    root="$fixture_root/$case_name"
    mkdir -p "$root/docs/validation/workspace-v3" \
        "$root/Tests/CalendarAppTests" \
        "$root/Tests/CalendarPersistenceTests"
    cp "$repo_root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt" \
        "$root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt"
    awk '
        BEGIN {
            print "# Task 6 Legacy Assertion Map"
            print ""
            print "| Legacy assertion | Task 6 target |"
            print "| --- | --- |"
        }
        {
            split($2, parts, "::")
            count = split(parts[1], path, "/")
            legacy = path[count] "::" parts[2]
            sub(/\.swift::/, "::", legacy)
            printf "| %s | Tests/CalendarPersistenceTests/Task6MappedTargets.swift::mapped_%02d |\n", legacy, NR
        }
    ' "$root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt" \
        > "$root/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
    awk '{ printf "    @Test func mapped_%02d() {}\n", NR }' \
        "$root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt" \
        > "$root/Tests/CalendarPersistenceTests/Task6MappedTargets.swift"
    awk '$2 ~ /CalendarStoreTests\.swift::/ { split($2, p, "::"); print "    @Test func " p[2] "() {}" }' \
        "$root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt" \
        > "$root/Tests/CalendarAppTests/CalendarStoreTests.swift"
    awk '$2 ~ /JSONCalendarRepositoryTests\.swift::/ { split($2, p, "::"); print "    @Test func " p[2] "() {}" }' \
        "$root/docs/validation/workspace-v3/task-6-legacy-test-inventory.txt" \
        > "$root/Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift"
    printf '%s\n' "$root"
}

run_verifier() {
    root=$1
    mode=$2
    (cd "$root" && "$verifier" "$mode") >/dev/null 2>&1
}

expect_failure() {
    root=$1
    mode=$2
    label=$3
    if run_verifier "$root" "$mode"; then
        echo "expected failure: $label" >&2
        exit 1
    fi
}

valid=$(make_fixture valid)
run_verifier "$valid" --inventory
run_verifier "$valid" --complete
rm "$valid/Tests/CalendarAppTests/CalendarStoreTests.swift" \
    "$valid/Tests/CalendarPersistenceTests/JSONCalendarRepositoryTests.swift"
run_verifier "$valid" --complete

fake=$(make_fixture fake)
sed -i '' '5s/Task6MappedTargets\.swift::mapped_01/Task6MappedTargets.swift::does_not_exist/' \
    "$fake/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$fake" --complete "nonexistent target"

duplicate_target=$(make_fixture duplicate-target)
sed -i '' 's/Task6MappedTargets\.swift::mapped_02/Task6MappedTargets.swift::mapped_01/' \
    "$duplicate_target/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$duplicate_target" --complete "duplicate target"

missing=$(make_fixture missing)
sed -i '' '$d' "$missing/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$missing" --inventory "missing map row"

extra=$(make_fixture extra)
printf '%s\n' '| UnknownTests::extra | Tests/CalendarPersistenceTests/Task6MappedTargets.swift::mapped_01 |' \
    >> "$extra/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$extra" --inventory "extra map row"

duplicate_row=$(make_fixture duplicate-row)
sed -n '5p' "$duplicate_row/docs/validation/workspace-v3/task-6-legacy-assertion-map.md" \
    >> "$duplicate_row/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$duplicate_row" --inventory "duplicate legacy row"

unmapped=$(make_fixture unmapped)
sed -i '' '5s/Tests\/CalendarPersistenceTests\/Task6MappedTargets\.swift::mapped_01/UNMAPPED/' \
    "$unmapped/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
run_verifier "$unmapped" --inventory
expect_failure "$unmapped" --complete "unmapped target"

blank=$(make_fixture blank)
sed -i '' '5s/| Tests\/CalendarPersistenceTests\/Task6MappedTargets\.swift::mapped_01 |/| |/' \
    "$blank/docs/validation/workspace-v3/task-6-legacy-assertion-map.md"
expect_failure "$blank" --complete "blank target"

extraction=$(make_fixture extraction)
sed -i '' '1s/@Test func /@Test func renamed_/' \
    "$extraction/Tests/CalendarAppTests/CalendarStoreTests.swift"
expect_failure "$extraction" --inventory "legacy extraction mismatch"

echo "task 6 legacy assertion map verifier self-tests passed"
