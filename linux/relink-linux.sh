#!/usr/bin/env bash
# ReLink for Linux (Bazzite, SteamOS, Fedora Silverblue and any other distribution): builds the game from your own copy and
# starts it. What the Windows launcher and ReLink-Setup.exe do, from a terminal. See docs/linux.md.
#
#   linux/relink-linux.sh install --game <file.nup | folder with exefs and romfs> [--out <folder>] [options]
#   linux/relink-linux.sh check   --game <file.nup | folder>
#   linux/relink-linux.sh update  [<game folder>] [--tag <vX.Y.Z>]
#   linux/relink-linux.sh play    [<game folder>] [-- game arguments]
#   linux/relink-linux.sh shortcut [<game folder>]      (the desktop and Steam's "Add a Non-Steam Game" list)
#   linux/relink-linux.sh doctor                        (what this PC has: CPU, memory, GPU, container engine)
#
# Options for install, check and update:
#   --out <folder>       where the game goes (default ~/Games/ReLink)
#   --language <code>    the game's language (en-US, en-GB, fr, fr-CA, de, it, es, es-419, pt-BR, nl, pl, ru, ja, ko,
#                        zh-Hans, zh-Hant)
#   --jobs <n>           compilers at once (default: one per CPU thread, as memory allows)
#   --native             build with this system's own clang, lld and Python instead of the container
#   --container          build in the container even when a native toolchain is there (the default on Bazzite)
#   --no-profile         do not download the latest release's play profile (the game is a little slower without it)
#   --no-shortcut        do not add the menu entry
#
# Environment: RELINK_ENGINE=podman|docker, RELINK_FEDORA=<version> (the container's Fedora), RELINK_BASE_IMAGE (default
# registry.fedoraproject.org/fedora; docker.io/library/fedora is the same), RELINK_IMAGE (a builder image made already),
# RELINK_DATA (default ~/.local/share/relink), and every RELINK_*, RX_* and HOS_* variable nx2/make_game.py and nx2/build.py read is passed on.
set -euo pipefail

SELF=$(readlink -f "${BASH_SOURCE[0]}")
ROOT=$(dirname "$(dirname "$SELF")")
DATA=${RELINK_DATA:-${XDG_DATA_HOME:-$HOME/.local/share}/relink}
WORK=${RELINK_WORK:-${XDG_CACHE_HOME:-$HOME/.cache}/relink-builder}
DEFAULT_OUT=$HOME/Games/ReLink
REPO=pixl27/ProjectReLink

die() { printf 'relink: %s\n' "$*" >&2; exit 1; }
say() { printf '\033[1m==> %s\033[0m\n' "$*"; }
note() { printf '    %s\n' "$*"; }

usage() { awk 'NR > 1 && !/^#/ { exit } NR > 1 { sub(/^# ?/, ""); print }' "$SELF"; exit "${1:-0}"; }

# ---------------------------------------------------------------- the toolchain: native or the container

engine() {
    if [[ -n ${RELINK_ENGINE:-} ]]; then command -v "$RELINK_ENGINE" >/dev/null || die "RELINK_ENGINE=$RELINK_ENGINE was not found"
        echo "$RELINK_ENGINE"; return; fi
    if command -v podman >/dev/null; then echo podman; elif command -v docker >/dev/null; then echo docker; else echo ""; fi
}

host_fedora() {   # the host's Fedora version (Bazzite and the other Universal Blue images say it in os-release)
    [[ -n ${RELINK_FEDORA:-} ]] && { echo "$RELINK_FEDORA"; return; }
    local id="" like="" ver=""
    if [[ -r /etc/os-release ]]; then
        id=$(. /etc/os-release; echo "${ID:-}"); like=$(. /etc/os-release; echo "${ID_LIKE:-}"); ver=$(. /etc/os-release; echo "${VERSION_ID:-}")
    fi
    if [[ $id == fedora || $like == *fedora* ]] && [[ $ver =~ ^[0-9]+$ ]]; then echo "$ver"
    else echo 41; fi   # (glibc 2.40: another distribution with an older C library should build with --native)
}

native_ready() {   # clang, lld and a Python with the packages the build reads
    command -v clang >/dev/null && command -v clang++ >/dev/null && { command -v ld.lld >/dev/null || command -v lld >/dev/null; } &&
        python3 -c 'import capstone, numpy, zstandard, lz4' 2>/dev/null
}

MODE=""   # native | container
pick_mode() {
    if [[ -z $MODE ]]; then
        if [[ -n ${RELINK_CONTAINER:-} ]]; then MODE=native   # (already inside the builder image)
        elif [[ -n $(engine) ]] && ! native_ready; then MODE=container
        elif native_ready; then MODE=native
        else die "no way to build here: install podman (Bazzite, Fedora and SteamOS have it), or clang, lld and Python 3 with
    the packages capstone, numpy, zstandard and lz4 (then use --native)"; fi
    fi
    if [[ $MODE == container && -z $(engine) ]]; then die "--container needs podman or docker"; fi
}

image_tag() {
    [[ -n ${RELINK_IMAGE:-} ]] && { echo "$RELINK_IMAGE"; return; }   # (an image of your own, made from linux/Containerfile)
    local sum
    sum=$(cat "$ROOT/linux/Containerfile" "$ROOT/linux/build-deps.sh" | sha256sum | cut -c1-12)
    echo "localhost/relink-builder:f$(host_fedora)-$sum"
}

ensure_image() {
    local e tag
    e=$(engine); tag=$(image_tag)
    if "$e" image inspect "$tag" >/dev/null 2>&1; then return; fi
    [[ -z ${RELINK_IMAGE:-} ]] || die "RELINK_IMAGE=$RELINK_IMAGE: no such image"
    say "Preparing the build container ($tag): once, about 5 to 10 minutes"
    note "Fedora $(host_fedora) with clang, lld and Python, and FFmpeg built for ReLink. Nothing is installed on your system."
    "$e" build --build-arg "FEDORA_VERSION=$(host_fedora)" \
        ${RELINK_BASE_IMAGE:+--build-arg "BASE_IMAGE=$RELINK_BASE_IMAGE"} \
        -t "$tag" -f "$ROOT/linux/Containerfile" "$ROOT/linux"
}

ensure_native_deps() {   # the static FFmpeg and the Vulkan headers, once, for a native build
    [[ -n ${RELINK_CONTAINER:-} ]] && return
    if [[ -z ${RELINK_FFMPEG:-} || -z ${RX_CPM:-} ]]; then
        if [[ ! -f $DATA/deps/ffmpeg/lib/libavcodec.a || ! -d $DATA/deps/cpm/vulkanheaders ]]; then
            say "Building FFmpeg and fetching the Vulkan headers into $DATA/deps (once)"
            bash "$ROOT/linux/build-deps.sh" "$DATA/deps"
        fi
        export RELINK_FFMPEG=${RELINK_FFMPEG:-$DATA/deps/ffmpeg} RX_CPM=${RX_CPM:-$DATA/deps/cpm}
    fi
}

# run_builder <make_game.py arguments...>: in the container (the paths it needs mounted at the same place) or here
MOUNTS=()
mount_path() { [[ -n $1 ]] && MOUNTS+=("$(readlink -f "$1")"); }

run_builder() {
    export RELINK_TOOLS=1 RELINK_BUILDER_EXE="$SELF"
    mkdir -p "$WORK"
    if [[ $MODE == native ]]; then
        ensure_native_deps
        (cd "$ROOT" && python3 -I -u -X utf8 nx2/make_game.py "$@")
        return
    fi
    ensure_image
    local e args=() seen=" " m v
    e=$(engine)
    args+=(run --rm -i --init --security-opt label=disable -w "$ROOT" -e HOME="$HOME")
    [[ -t 0 && -t 1 ]] && args+=(-t)
    if [[ $e == podman ]]; then args+=(--userns=keep-id); else args+=(--user "$(id -u):$(id -g)"); fi
    for m in "$ROOT" "$WORK" "${MOUNTS[@]}"; do
        [[ $seen == *" $m "* ]] && continue
        seen+="$m "
        args+=(-v "$m:$m")
    done
    for v in $(compgen -e | grep -E '^(RELINK_|RX_|HOS_|OOT_)' | grep -v -E '^(RELINK_ENGINE|RELINK_FEDORA|RELINK_DATA|RELINK_BASE_IMAGE|RELINK_IMAGE)$'); do
        args+=(-e "$v")
    done
    "$e" "${args[@]}" "$(image_tag)" python3 -I -u -X utf8 nx2/make_game.py "$@"
}

# ---------------------------------------------------------------- the play profile (optional)

fetch_profile() {
    local list
    if [[ -f $ROOT/work/hot_funcs.txt ]]; then return; fi
    say "Downloading the latest release's play profile (pipelines and hot functions: smoother first visits)"
    list=$(mktemp)
    if python3 -I "$ROOT/scripts/release_parts.py" previous "$list" --repo "$REPO" --list-name relink-setup.txt >/dev/null &&
       python3 -I "$ROOT/scripts/release_parts.py" profile "$list" "$ROOT/work"; then
        :
    else
        note "it could not be downloaded: the game is built without it (it still works, the first visits stutter more)"
    fi
    rm -f "$list"
}

# ---------------------------------------------------------------- the game's update offer

# (host/hos_update.c reads relink_version.txt: version= this release, builder= what to run for "Update now". nx2/make_game.py writes
# it only from a package's version.txt; a checkout of a release tag says its tag here. Any other commit says nothing: the game
# would offer an update at every start)
version_file() {
    local out=$1 tag
    [[ -d $ROOT/.git ]] || return 0
    tag=$(git -C "$ROOT" describe --tags --exact-match --match 'v[0-9]*' 2>/dev/null) || return 0
    [[ -z $(git -C "$ROOT" status --porcelain --untracked-files=no) ]] || return 0
    printf 'version=%s\nbuilder=%s\n' "$tag" "$SELF" > "$out/relink_version.txt"
}

# ---------------------------------------------------------------- the menu entry

shortcut() {
    local out=$1 apps="${XDG_DATA_HOME:-$HOME/.local/share}/applications" icons="${XDG_DATA_HOME:-$HOME/.local/share}/icons/hicolor/256x256/apps"
    [[ -x $out/relink || -x $out/bin/relink ]] || die "$out has no game in it (build it with: $0 install)"
    local exec_line="\"$SELF\" play \"$out\""
    [[ -x $out/relink && -x $out/bin/relink ]] && exec_line="\"$out/relink\""   # (the folder's own launcher: works wherever ReLink's sources go)
    mkdir -p "$apps" "$icons"
    cp -f "$ROOT/assets/relink.png" "$icons/relink.png"
    cat > "$apps/relink.desktop" <<EOF
[Desktop Entry]
Type=Application
Name=Project ReLink
Comment=Zelda: Ocarina of Time (Switch 2 remake), recompiled for Linux
Exec=$exec_line
Path=$out
Icon=relink
Terminal=false
Categories=Game;
StartupWMClass=relink
EOF
    command -v update-desktop-database >/dev/null && update-desktop-database "$apps" >/dev/null 2>&1 || true
    say "Menu entry added: Project ReLink"
    note "Steam (and Gaming Mode on Bazzite): Steam, Games, Add a Non-Steam Game to My Library, tick Project ReLink"
}

# ---------------------------------------------------------------- commands

GAME="" OUT="" LANGUAGE="" JOBS="" TAG="" PROFILE=1 SHORTCUT=1 FETCHED=0 EXTRA=()
parse() {
    while (($#)); do
        case $1 in
            --game) GAME=${2:?--game needs a path}; shift ;;
            --out) OUT=${2:?--out needs a folder}; shift ;;
            --language) LANGUAGE=${2:?}; shift ;;
            --jobs) JOBS=${2:?}; shift ;;
            --tag) TAG=${2:?}; shift ;;
            --native) MODE=native ;;
            --container) MODE=container ;;
            --no-profile) PROFILE=0 ;;
            --no-shortcut) SHORTCUT=0 ;;
            --no-fetch-again) FETCHED=1 ;;
            -h|--help) usage ;;
            --) shift; EXTRA+=("$@"); break ;;
            -*) die "unknown option $1 (see $0 --help)" ;;
            *) if [[ -z $OUT ]]; then OUT=$1; else EXTRA+=("$1"); fi ;;
        esac
        shift
    done
}

game_args() {
    [[ -n $GAME ]] || die "say where your copy of the game is: --game <file.nup or folder with exefs and romfs>"
    [[ -e $GAME ]] || die "$GAME was not found"
    GAME=$(readlink -f "$GAME")
    if [[ -f $GAME ]]; then mount_path "$(dirname "$GAME")"; else mount_path "$GAME"; fi
}

cmd_install() {
    parse "$@"
    game_args
    OUT=$(readlink -m "${OUT:-$DEFAULT_OUT}")
    mkdir -p "$OUT"; mount_path "$OUT"
    pick_mode
    say "Building ReLink into $OUT ($MODE build): 10 to 45 minutes depending on your CPU"
    ((PROFILE)) && fetch_profile
    local a=(--game "$GAME" --out "$OUT" --work "$WORK" --log "$OUT/relink_build_log.txt")
    [[ -n $LANGUAGE ]] && a+=(--language "$LANGUAGE")
    [[ -n $JOBS ]] && a+=(--jobs "$JOBS")
    run_builder "${a[@]}" "${EXTRA[@]}"
    version_file "$OUT"
    ((SHORTCUT)) && shortcut "$OUT"
    say "Done. Play with: $SELF play \"$OUT\""
    note "The first start prepares the shaders and pipelines once (about a quarter of an hour), with a progress screen."
}

cmd_check() {
    parse "$@"
    game_args
    pick_mode
    run_builder --check --game "$GAME" --work "$WORK" "${EXTRA[@]}"
}

cmd_update() {
    # (also the game's own update offer, host/hos_update.c: <builder> --update <folder> --tag <tag>)
    parse "$@"
    OUT=$(readlink -m "${OUT:-$DEFAULT_OUT}")
    [[ -d $OUT/.relink_exefs ]] || die "$OUT is not a game folder ReLink built (or it was built before updates came in): use install"
    mount_path "$OUT"
    if [[ -d $ROOT/.git ]] && ((!FETCHED)); then
        local want=${TAG:-}
        if [[ -z $want ]]; then
            want=$(git -C "$ROOT" ls-remote --tags --refs --sort=-v:refname "https://github.com/$REPO" 'v*' 2>/dev/null |
                   awk -F/ '{print $3}' | grep -E '^v[0-9]+(\.[0-9]+)*$' | head -1 || true)
        fi
        if [[ -n $want ]] && [[ -z $(git -C "$ROOT" status --porcelain --untracked-files=no) ]]; then
            say "Getting ReLink $want"
            git -C "$ROOT" fetch -q --depth 1 origin tag "$want" && git -C "$ROOT" -c advice.detachedHead=false checkout -q "$want"
            exec "$ROOT/linux/relink-linux.sh" update "$OUT" ${MODE:+--$MODE} ${JOBS:+--jobs "$JOBS"} --no-fetch-again
        elif [[ -n $want ]]; then
            note "your ReLink checkout has local changes: building $OUT again with it as it is, not $want"
        fi
    fi
    pick_mode
    say "Building $OUT again with these tools (saves, settings and mods stay)"
    ((PROFILE)) && fetch_profile
    run_builder --update "$OUT" --work "$WORK" --log "$OUT/relink_build_log.txt" ${JOBS:+--jobs "$JOBS"} "${EXTRA[@]}"
    version_file "$OUT"
    say "Done."
}

cmd_play() {
    parse "$@"
    OUT=$(readlink -m "${OUT:-$DEFAULT_OUT}")
    local exe=$OUT/bin/relink
    [[ -x $exe ]] || exe=$OUT/relink
    [[ -x $exe && ! -d $exe ]] || die "no game in $OUT (build it with: $0 install --game <your copy>)"
    cd "$OUT"
    exec "$exe" "${EXTRA[@]}"
}

cmd_shortcut() { parse "$@"; shortcut "$(readlink -m "${OUT:-$DEFAULT_OUT}")"; }

cmd_doctor() {
    local mem avx e mode
    say "This PC"
    note "system: $( (. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}") )"
    avx=no; grep -q -w avx2 /proc/cpuinfo && avx=yes
    note "CPU: $(grep -m1 'model name' /proc/cpuinfo | cut -d: -f2- | sed 's/^ //') (AVX2: $avx)"
    mem=$(awk '/MemTotal/ {printf "%d", $2/1048576}' /proc/meminfo)
    note "memory: ${mem} GB$( ((mem < 16)) && echo ' (16 GB or more recommended: use --jobs 2 if the build is stopped)')"
    note "free space in $(dirname "$WORK"): $(df -h --output=avail "$(dirname "$WORK")" | tail -1 | tr -d ' ') (about 60 GB needed while it builds)"
    if command -v vulkaninfo >/dev/null; then
        note "GPU: $(vulkaninfo --summary 2>/dev/null | grep -m1 deviceName | cut -d= -f2- | sed 's/^ //')"
        vulkaninfo 2>/dev/null | grep -q VK_EXT_mesh_shader && note "mesh shaders: yes" || note "mesh shaders: no (an experiment: about half the frame rate)"
    else
        note "GPU: vulkaninfo is not installed, not checked"
    fi
    e=$(engine)
    note "container engine: ${e:-none}"
    native_ready && note "native toolchain: yes (clang $(clang -dumpversion))" || note "native toolchain: no"
    mode=$( (MODE=""; pick_mode >/dev/null 2>&1; echo "$MODE") )
    note "build will use: ${mode:-nothing (install podman, or clang, lld and the Python packages)}"
}

main() {
    local cmd=${1:-}
    [[ -n $cmd ]] || usage 1
    shift
    case $cmd in
        install) cmd_install "$@" ;;
        check) cmd_check "$@" ;;
        update) cmd_update "$@" ;;
        --update) cmd_update "$@" ;;   # (host/hos_update.c: --update <folder> --tag <tag>)
        play) cmd_play "$@" ;;
        shortcut) cmd_shortcut "$@" ;;
        doctor) cmd_doctor ;;
        -h|--help|help) usage ;;
        *) die "unknown command $cmd (see $0 --help)" ;;
    esac
}

main "$@"
