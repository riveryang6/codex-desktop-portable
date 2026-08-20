#!/usr/bin/env bash
# Build the Windows bootstrapper and launcher cores from WSL.

set -euo pipefail

usage() {
    cat <<'EOF'
Usage: build-launcher.sh --output-root DIR [--dotnet PATH] [--framework-dir DIR]

Builds:
  DIR/CodexPortable.exe
  DIR/CodexData/tools/launchers/CodexPortable.x86.exe
  DIR/CodexData/tools/launchers/CodexPortable.x64.exe
  DIR/CodexData/tools/launchers/CodexPortable.arm64.exe
EOF
}

fail() {
    printf 'build-launcher.sh: %s\n' "$*" >&2
    exit 1
}

require_file() {
    local path=$1
    [[ -f "$path" ]] || fail "Required file is missing: $path"
}

extract_file_version() {
    local source=$1
    local -a versions=()
    mapfile -t versions < <(
        sed -nE 's/^[[:space:]]*\[assembly:[[:space:]]*AssemblyFileVersion\("([^"]+)"\)\][[:space:]]*$/\1/p' "$source"
    )
    [[ ${#versions[@]} -eq 1 ]] || fail "Expected one AssemblyFileVersion in: $source"
    printf '%s\n' "${versions[0]}"
}

find_roslyn_compiler() {
    local line version sdk_base candidate
    while IFS= read -r line; do
        if [[ $line =~ ^([^[:space:]]+)[[:space:]]+\[([^]]+)\]$ ]]; then
            version=${BASH_REMATCH[1]}
            sdk_base=${BASH_REMATCH[2]}
            candidate="$sdk_base/$version/Roslyn/bincore/csc.dll"
            if [[ -f "$candidate" ]]; then
                printf '%s\n' "$candidate"
            fi
        fi
    done < <("$dotnet_path" --list-sdks)
}

read_pe_machine() {
    local output=$1
    local pe_offset machine_offset
    [[ $(od -An -tx1 -N2 "$output" | tr -d '[:space:]') == '4d5a' ]] || \
        fail "Output is not a Windows executable: $output"
    pe_offset=$(od -An -tu4 -j60 -N4 "$output" | tr -d '[:space:]')
    [[ $pe_offset =~ ^[0-9]+$ ]] || fail "Cannot read PE header offset: $output"
    [[ $(od -An -tx1 -j"$pe_offset" -N4 "$output" | tr -d '[:space:]') == '50450000' ]] || \
        fail "Output has no PE signature: $output"
    machine_offset=$((pe_offset + 4))
    od -An -tu2 -j"$machine_offset" -N2 "$output" | tr -d '[:space:]'
}

assert_output() {
    local output=$1
    local expected_machine=$2
    local machine
    require_file "$output"
    machine=$(read_pe_machine "$output")
    [[ $machine == "$expected_machine" ]] || \
        fail "PE machine mismatch for $output (expected $expected_machine, got $machine)"
    strings -el "$output" | grep -Fx -- "$expected_version" >/dev/null || \
        fail "Assembly version $expected_version is missing from: $output"
}

build_target() {
    local label=$1
    local source=$2
    local platform=$3
    local output=$4
    local expected_machine=$5
    local -a compiler_args

    mkdir -p -- "$(dirname -- "$output")"
    compiler_args=(
        /nologo
        /noconfig
        /nostdlib+
        /langversion:5
        /codepage:65001
        /target:winexe
        "/platform:$platform"
        /optimize+
        /debug-
        /warn:4
        /warnaserror+
        "/out:$output"
        "/win32icon:$icon_path"
        "/win32manifest:$manifest_path"
        "/resource:$tray_dark_path,CodexPortable.Branding.TrayDark.ico"
        "/resource:$tray_light_path,CodexPortable.Branding.TrayLight.ico"
    )
    local reference
    for reference in "${references[@]}"; do
        compiler_args+=("/reference:$reference")
    done
    compiler_args+=("$source")

    printf 'Building %s...\n' "$label"
    "$dotnet_path" "$csc_path" "${compiler_args[@]}"
    assert_output "$output" "$expected_machine"
}

output_root=''
dotnet_path=''
framework_dir=''
while [[ $# -gt 0 ]]; do
    case $1 in
        --output-root)
            [[ $# -ge 2 ]] || fail '--output-root requires a directory'
            output_root=$2
            shift 2
            ;;
        --dotnet)
            [[ $# -ge 2 ]] || fail '--dotnet requires a path'
            dotnet_path=$2
            shift 2
            ;;
        --framework-dir)
            [[ $# -ge 2 ]] || fail '--framework-dir requires a directory'
            framework_dir=$2
            shift 2
            ;;
        --help|-h)
            usage
            exit 0
            ;;
        *)
            usage >&2
            fail "Unknown argument: $1"
            ;;
    esac
done

[[ -n $output_root ]] || {
    usage >&2
    fail '--output-root is required'
}

if [[ -z $dotnet_path ]]; then
    dotnet_path=$(command -v dotnet || true)
fi
[[ -n $dotnet_path && -x $dotnet_path ]] || fail 'A usable dotnet executable is required'

if [[ -z $framework_dir ]]; then
    framework_dir=/usr/lib/mono/4.8-api
fi
[[ -d $framework_dir ]] || fail "Framework reference directory is missing: $framework_dir"

for required_command in od sed strings grep tr; do
    command -v "$required_command" >/dev/null || fail "Required command is unavailable: $required_command"
done

script_dir=$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)
mkdir -p -- "$output_root"
output_root=$(cd -- "$output_root" && pwd -P)
framework_dir=$(cd -- "$framework_dir" && pwd -P)

core_source="$script_dir/CodexPortable.cs"
bootstrap_source="$script_dir/CodexPortableBootstrap.cs"
icon_path="$script_dir/codex.ico"
tray_dark_path="$script_dir/codex-tray-dark.ico"
tray_light_path="$script_dir/codex-tray-light.ico"
manifest_path="$script_dir/CodexPortable.manifest"
for input_path in "$core_source" "$bootstrap_source" "$icon_path" "$tray_dark_path" \
    "$tray_light_path" "$manifest_path"; do
    require_file "$input_path"
done

core_version=$(extract_file_version "$core_source")
bootstrap_version=$(extract_file_version "$bootstrap_source")
[[ $core_version == "$bootstrap_version" ]] || \
    fail "Launcher source versions differ: core=$core_version bootstrapper=$bootstrap_version"
expected_version=$core_version

mapfile -t csc_candidates < <(find_roslyn_compiler)
[[ ${#csc_candidates[@]} -gt 0 ]] || fail 'Could not find Roslyn csc.dll from dotnet --list-sdks'
csc_path=${csc_candidates[$((${#csc_candidates[@]} - 1))]}

reference_names=(
    mscorlib.dll
    System.dll
    System.Core.dll
    System.Drawing.dll
    System.IO.Compression.dll
    System.Web.Extensions.dll
    System.Windows.Forms.dll
    System.Xml.dll
)
references=()
for reference_name in "${reference_names[@]}"; do
    reference="$framework_dir/$reference_name"
    require_file "$reference"
    references+=("$reference")
done

build_target 'x86 bootstrapper' "$bootstrap_source" x86 \
    "$output_root/CodexPortable.exe" 332
build_target 'x86 launcher' "$core_source" x86 \
    "$output_root/CodexData/tools/launchers/CodexPortable.x86.exe" 332
build_target 'x64 launcher' "$core_source" x64 \
    "$output_root/CodexData/tools/launchers/CodexPortable.x64.exe" 34404
build_target 'ARM64 launcher' "$core_source" arm64 \
    "$output_root/CodexData/tools/launchers/CodexPortable.arm64.exe" 43620

printf 'Built launcher outputs under %s\n' "$output_root"
