#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VALIDATOR="$ROOT/scripts/validate-release.sh"

pass=0
fail=0

run_case() {
    name=$1
    expected_status=$2
    expected_message=$3
    fixture_tag=$4
    artifact_mode=${5:-good}

    fixture=$(mktemp -d "${TMPDIR:-/tmp}/cog-release-validation.XXXXXX")
    mkdir -p "$fixture/artifacts"

    cp "$VALIDATOR" "$fixture/validate-release.sh"
    cat > "$fixture/build.zig.zon" <<'ZON'
.{
    .name = .cog,
    .version = "1.2.3",
}
ZON
    cat > "$fixture/CHANGELOG.md" <<'CHANGELOG'
# Changelog

## [Unreleased]

## [1.2.3] - 2026-08-13

### Added

- Release validation coverage.

## [1.2.2] - 2026-08-01

### Fixed

- Earlier fix.
CHANGELOG

    case "$artifact_mode" in
        good)
            for target in darwin-arm64 linux-arm64 linux-x86_64; do
                payload="$fixture/payload-$target"
                mkdir -p "$payload"
                cat > "$payload/cog" <<'BIN'
#!/bin/sh
if [ "${1:-}" = "--version" ]; then
    printf '%s\n' '1.2.3'
    exit 0
fi
exit 1
BIN
                chmod +x "$payload/cog"
                tar -czf "$fixture/artifacts/cog-$target.tar.gz" -C "$payload" cog
            done
            ;;
        missing)
            artifact="$fixture/artifacts/cog-darwin-arm64.tar.gz"
            payload="$fixture/payload-darwin-arm64"
            mkdir -p "$payload"
            printf '#!/bin/sh\nprintf "%%s\\n" "1.2.3"\n' > "$payload/cog"
            chmod +x "$payload/cog"
            tar -czf "$artifact" -C "$payload" cog
            ;;
        wrong-version)
            for target in darwin-arm64 linux-arm64 linux-x86_64; do
                payload="$fixture/payload-$target"
                mkdir -p "$payload"
                version=1.2.3
                case "$(uname -s)/$(uname -m)" in
                    Darwin/arm64) host_target=darwin-arm64 ;;
                    Linux/aarch64|Linux/arm64) host_target=linux-arm64 ;;
                    Linux/x86_64) host_target=linux-x86_64 ;;
                    *) host_target=linux-x86_64 ;;
                esac
                [ "$target" != "$host_target" ] || version=1.2.2
                printf '#!/bin/sh\nprintf "%%s\\n" "%s"\n' "$version" > "$payload/cog"
                chmod +x "$payload/cog"
                tar -czf "$fixture/artifacts/cog-$target.tar.gz" -C "$payload" cog
            done
            ;;
        none)
            ;;
        *)
            printf 'unknown artifact mode: %s\n' "$artifact_mode" >&2
            exit 2
            ;;
    esac

    set +e
    if [ "$artifact_mode" = none ]; then
        output=$(cd "$fixture" && ./validate-release.sh "$fixture_tag" 2>&1)
    else
        output=$(cd "$fixture" && ./validate-release.sh "$fixture_tag" "$fixture/artifacts" "$fixture/release-notes.md" 2>&1)
    fi
    status=$?
    set -e

    rm -rf "$fixture"

    if [ "$expected_status" = success ]; then
        if [ "$status" -eq 0 ] && printf '%s' "$output" | grep -F "$expected_message" >/dev/null; then
            printf 'ok - %s\n' "$name"
            pass=$((pass + 1))
        else
            printf 'not ok - %s\n%s\n' "$name" "$output"
            fail=$((fail + 1))
        fi
    else
        if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -F "$expected_message" >/dev/null; then
            printf 'ok - %s\n' "$name"
            pass=$((pass + 1))
        else
            printf 'not ok - %s\n%s\n' "$name" "$output"
            fail=$((fail + 1))
        fi
    fi
}

run_case "accepts matching release metadata" success "Release metadata validated for v1.2.3" v1.2.3 none
run_case "rejects a tag without v prefix" failure "release tag must match vMAJOR.MINOR.PATCH" 1.2.3 none
run_case "rejects tag and source version drift" failure "release tag v1.2.4 does not match build.zig.zon version 1.2.3" v1.2.4 none

fixture=$(mktemp -d "${TMPDIR:-/tmp}/cog-release-validation.XXXXXX")
cp "$VALIDATOR" "$fixture/validate-release.sh"
cat > "$fixture/build.zig.zon" <<'ZON'
.{
    .version = "1.2.3",
}
ZON
printf '# Changelog\n\n## [Unreleased]\n\n## [1.2.3] - 2026-08-13\n\n' > "$fixture/CHANGELOG.md"
set +e
output=$(cd "$fixture" && ./validate-release.sh v1.2.3 2>&1)
status=$?
set -e
rm -rf "$fixture"
if [ "$status" -ne 0 ] && printf '%s' "$output" | grep -F "CHANGELOG.md section for 1.2.3 is empty" >/dev/null; then
    printf 'ok - rejects an empty changelog section\n'
    pass=$((pass + 1))
else
    printf 'not ok - rejects an empty changelog section\n%s\n' "$output"
    fail=$((fail + 1))
fi

run_case "accepts versioned release artifacts" success "Release artifacts validated for source version 1.2.3" v1.2.3 good
run_case "rejects missing release artifacts" failure "release artifact set does not match expected targets" v1.2.3 missing
run_case "rejects artifact source version drift" failure "reports version 1.2.2, expected 1.2.3" v1.2.3 wrong-version

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
