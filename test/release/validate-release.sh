#!/bin/sh
set -eu

ROOT=$(CDPATH= cd -- "$(dirname -- "$0")/../.." && pwd)
VALIDATOR="$ROOT/scripts/validate-release.sh"

pass=0
fail=0

host_target() {
    case "$(uname -s)/$(uname -m)" in
        Darwin/arm64) printf darwin-arm64 ;;
        Linux/aarch64|Linux/arm64) printf linux-arm64 ;;
        Linux/x86_64) printf linux-x86_64 ;;
        *) printf unsupported ;;
    esac
}

write_synthetic_binary() {
    synthetic_path=$1
    synthetic_target=$2
    python3 -c 'import pathlib, struct, sys
path = pathlib.Path(sys.argv[1])
target = sys.argv[2]
if target == "darwin-arm64":
    data = struct.pack("<8I", 0xfeedfacf, 0x0100000c, 0, 2, 0, 0, 0, 0)
elif target == "linux-arm64":
    data = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack("<HHI", 2, 183, 1) + bytes(40)
elif target == "linux-x86_64":
    data = b"\x7fELF" + bytes([2, 1, 1, 0]) + bytes(8) + struct.pack("<HHI", 2, 62, 1) + bytes(40)
else:
    raise SystemExit(f"unknown target: {target}")
path.write_bytes(data)
' "$synthetic_path" "$synthetic_target"
}

write_native_binary() {
    native_path=$1
    native_version=$2
    source_path="$native_path.c"
    cat > "$source_path" <<SOURCE
#include <stdio.h>
#include <string.h>
int main(int argc, char **argv) {
    if (argc == 2 && strcmp(argv[1], "--version") == 0) {
        puts("$native_version");
        return 0;
    }
    return 1;
}
SOURCE
    cc "$source_path" -o "$native_path"
}

create_artifacts() {
    fixture=$1
    mode=$2
    native_target=$(host_target)
    [ "$native_target" != unsupported ] || return 1

    case "$native_target" in
        darwin-arm64) foreign_target=linux-arm64 ;;
        linux-arm64|linux-x86_64) foreign_target=darwin-arm64 ;;
    esac

    for target in darwin-arm64 linux-arm64 linux-x86_64; do
        payload="$fixture/payload-$target"
        mkdir -p "$payload"
        artifact_version=1.2.3
        if [ "$mode" = wrong-version ] && [ "$target" = "$native_target" ]; then
            artifact_version=1.2.2
        fi

        if [ "$target" = "$native_target" ]; then
            write_native_binary "$payload/cog" "$artifact_version"
        else
            binary_target=$target
            if [ "$mode" = wrong-format ] && [ "$target" = "$foreign_target" ]; then
                case "$target" in
                    darwin-arm64) binary_target=linux-x86_64 ;;
                    linux-arm64) binary_target=linux-x86_64 ;;
                    linux-x86_64) binary_target=linux-arm64 ;;
                esac
            fi
            write_synthetic_binary "$payload/cog" "$binary_target"
        fi

        chmod +x "$payload/cog"
        tar -czf "$fixture/artifacts/cog-$target.tar.gz" -C "$payload" cog
    done

    if [ "$mode" = extra ]; then
        cp "$fixture/artifacts/cog-linux-x86_64.tar.gz" "$fixture/artifacts/cog-windows-x86_64.tar.gz"
    fi
}

run_case() {
    name=$1
    expected_status=$2
    expected_message=$3
    fixture_tag=$4
    artifact_mode=${5:-good}
    space_tmpdir=${6:-false}

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
        good|wrong-version|wrong-format|extra)
            create_artifacts "$fixture" "$artifact_mode"
            ;;
        missing)
            payload="$fixture/payload-darwin-arm64"
            mkdir -p "$payload"
            write_synthetic_binary "$payload/cog" darwin-arm64
            chmod +x "$payload/cog"
            tar -czf "$fixture/artifacts/cog-darwin-arm64.tar.gz" -C "$payload" cog
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
    elif [ "$space_tmpdir" = true ]; then
        validation_tmpdir="$fixture/tmp with spaces"
        mkdir -p "$validation_tmpdir"
        output=$(cd "$fixture" && TMPDIR="$validation_tmpdir" ./validate-release.sh "$fixture_tag" "$fixture/artifacts" "$fixture/release-notes.md" 2>&1)
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
run_case "handles temporary paths containing spaces" success "Release artifacts validated for source version 1.2.3" v1.2.3 good true
run_case "rejects missing release artifacts" failure "release artifact set does not match expected targets" v1.2.3 missing
run_case "rejects extra release artifacts" failure "release artifact set does not match expected targets" v1.2.3 extra
run_case "rejects artifact source version drift" failure "reports version 1.2.2, expected 1.2.3" v1.2.3 wrong-version
run_case "rejects wrong non-host artifact format" failure "has unexpected binary format" v1.2.3 wrong-format

run_integrity_case() {
    name=$1
    expected_status=$2
    expected_message=$3
    integrity_mode=$4

    fixture=$(mktemp -d "${TMPDIR:-/tmp}/cog-release-integrity.XXXXXX")
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

- Release integrity coverage.
CHANGELOG

    create_artifacts "$fixture" good
    ruby -rdigest -e '
Dir.chdir(ARGV.fetch(0)) do
  names = Dir.glob("cog-*.tar.gz").sort
  File.write("SHA256SUMS", names.map { |name| "#{Digest::SHA256.file(name).hexdigest}  #{name}\n" }.join)
end
' "$fixture/artifacts"

    case "$integrity_mode" in
        good) ;;
        bad-checksum)
            ruby -pi -e 'sub(/\A./, "0") if $. == 1' "$fixture/artifacts/SHA256SUMS"
            ;;
        missing-checksum-entry)
            ruby -e 'lines = File.readlines(ARGV.fetch(0)); File.write(ARGV.fetch(0), lines.drop(1).join)' "$fixture/artifacts/SHA256SUMS"
            ;;
        checksum-subject-mismatch)
            ruby -pi -e 'sub(/cog-linux-x86_64\.tar\.gz/, "cog-linux-amd64.tar.gz") if $. == 3' "$fixture/artifacts/SHA256SUMS"
            ;;
        provenance-failure|provenance-digest-mismatch) ;;
        *)
            printf 'unknown integrity mode: %s\n' "$integrity_mode" >&2
            exit 2
            ;;
    esac

    printf '{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}\n' > "$fixture/provenance.json"
    cat > "$fixture/fake-gh" <<'FAKE_GH'
#!/bin/sh
printf '%s\n' "$*" >> "$GH_LOG"
if [ "${PROVENANCE_FAILURE:-false}" = true ]; then
    printf 'provenance verification failed\n' >&2
    exit 1
fi
if [ "${PROVENANCE_DIGEST_MISMATCH:-false}" = true ] && printf '%s' "$*" | grep -F 'cog-darwin-arm64.tar.gz' >/dev/null; then
    printf 'provenance digest does not match\n' >&2
    exit 1
fi
FAKE_GH
    chmod +x "$fixture/fake-gh"

    set +e
    output=$(cd "$fixture" && \
        GH="$fixture/fake-gh" \
        GH_LOG="$fixture/gh.log" \
        SOURCE_DIGEST=0123456789abcdef \
        SOURCE_REPOSITORY=trycog/cog-cli \
        SIGNER_WORKFLOW=trycog/cog-cli/.github/workflows/release.yml \
        PROVENANCE_FAILURE=$(if [ "$integrity_mode" = provenance-failure ]; then printf true; else printf false; fi) \
        PROVENANCE_DIGEST_MISMATCH=$(if [ "$integrity_mode" = provenance-digest-mismatch ]; then printf true; else printf false; fi) \
        ./validate-release.sh v1.2.3 "$fixture/artifacts" "$fixture/release-notes.md" "$fixture/provenance.json" 2>&1)
    status=$?
    set -e

    gh_log=
    if [ -f "$fixture/gh.log" ]; then
        gh_log=$(cat "$fixture/gh.log")
    fi
    rm -rf "$fixture"

    if [ "$expected_status" = success ]; then
        if [ "$status" -eq 0 ] && printf '%s' "$output" | grep -F "$expected_message" >/dev/null && \
            printf '%s' "$gh_log" | grep -F -- '--source-ref refs/tags/v1.2.3' >/dev/null && \
            printf '%s' "$gh_log" | grep -F -- '--source-digest 0123456789abcdef' >/dev/null; then
            printf 'ok - %s\n' "$name"
            pass=$((pass + 1))
        else
            printf 'not ok - %s\n%s\n%s\n' "$name" "$output" "$gh_log"
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

run_integrity_case "accepts checksums and provenance for release artifacts" success "Release integrity validated for source version 1.2.3" good
run_integrity_case "rejects a checksum mismatch" failure "SHA256SUMS digest mismatch" bad-checksum
run_integrity_case "rejects an incomplete checksum manifest" failure "SHA256SUMS must list exactly the release artifacts" missing-checksum-entry
run_integrity_case "rejects checksum subject mismatch" failure "SHA256SUMS must list exactly the release artifacts" checksum-subject-mismatch
run_integrity_case "rejects provenance verification failure" failure "provenance verification failed" provenance-failure
run_integrity_case "rejects provenance subject digest mismatch" failure "provenance verification failed for cog-darwin-arm64.tar.gz" provenance-digest-mismatch

workflow="$ROOT/.github/workflows/release.yml"
ci_workflow="$ROOT/.github/workflows/ci.yml"
workflow_checks=$(ruby -e '
release = File.read(ARGV.fetch(0))
ci = File.read(ARGV.fetch(1))
checks = {
  "release CI runs unit tests" => release.include?("- name: Run tests\n        run: zig build test"),
  "release CI runs indexing integration tests" => release.include?("- name: Run indexing integration tests\n        run: zig build test-indexing-integration"),
  "artifact build waits for release CI" => release.match?(/\n  build:\n    needs: ci\n/),
  "publication waits for artifact build" => release.match?(/\n  release:\n    needs: build\n/),
  "checksums precede provenance" => release.index("- name: Generate SHA-256 checksums").to_i < release.index("- name: Generate build provenance").to_i,
  "provenance verification precedes draft publication" => release.index("- name: Verify build provenance and release checksums").to_i < release.index("- name: Create draft GitHub Release").to_i,
  "regular CI tests release validation" => ci.include?("./test/release/validate-release.sh"),
}
checks.each { |name, ok| puts "#{ok ? "ok" : "not ok"} - #{name}" }
exit 1 unless checks.values.all?
' "$workflow" "$ci_workflow" 2>&1) || workflow_status=$?
workflow_status=${workflow_status:-0}
printf '%s\n' "$workflow_checks"
workflow_count=$(printf '%s\n' "$workflow_checks" | grep -c '^ok - ' || true)
pass=$((pass + workflow_count))
if [ "$workflow_status" -ne 0 ]; then
    workflow_failures=$(printf '%s\n' "$workflow_checks" | grep -c '^not ok - ' || true)
    fail=$((fail + workflow_failures))
fi

printf '%s passed, %s failed\n' "$pass" "$fail"
[ "$fail" -eq 0 ]
