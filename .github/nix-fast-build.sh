#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2022-2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

################################################################################

# This script is a helper to run nix-fast-build for specified flake targets.

################################################################################

# Set shell options after env_parallel as it would otherwise fail
set -e # exit immediately if a command fails
set -E # exit immediately if a command fails (subshells)
set -u # treat unset variables as an error and exit
set -o pipefail # exit if any pipeline command fails

TMPDIR="$(mktemp -d --suffix .evaltmp)"
MYNAME=$(basename "$0")

################################################################################

usage () {
    echo ""
    echo "Usage: $MYNAME [-h] [-v] [-o OPTS] {-f FILTER | -t 'TARGET1 [TARGET2 ...]'}"
    echo ""
    echo "Helper to run nix-fast-build for specified flake targets."
    echo ""
    echo "Options:"
    echo " -h    Print this help message."
    echo " -v    Set the script verbosity to DEBUG."
    echo " -o    Options passed directly to nix-fast-build. See available options at:"
    echo "       https://github.com/Mic92/nix-fast-build#reference."
    echo " -f    Target selector filter - regular expression applied over flake outputs"
    echo "       to determine the build targets. This option is mutually exclusive with"
    echo "       option -t."
    echo "       Example: -f '^devShells\.'"
    echo " -t    Target selector list - list of flake outputs to build. This options is"
    echo "       mutually exclusive with option -f. "
    echo "       Example: -t 'devShells.x86_64-linux.smoke-test packages.x86_64-linux.doc'"
    echo ""
    echo "Examples:"
    echo ""
    echo "  --"
    echo ""
    echo "  Following command builds the target 'packages.x86_64-linux.doc' locally:"
    echo ""
    echo "    $MYNAME -t packages.x86_64-linux.doc"
    echo ""
    echo "  --"
    echo ""
    echo "  Following command builds the target 'packages.x86_64-linux.doc' on the"
    echo "  remote builder 'my_builder' authenticating as current user:"
    echo ""
    echo "    $MYNAME -t packages.x86_64-linux.doc -o '--remote my-builder'"
    echo ""
    echo "  --"
    echo ""
    echo "  Following command builds all 'checks.x86_64-linux.*debug' targets on"
    echo "  the specified remote builder 'my_builder' authenticating as user 'me'"
    echo "  with ssh key '~/.ssh/my_key':"
    echo ""
    echo "    $MYNAME \\"
    echo "      -f '^checks\.x86_64-linux\..*debug$' \\"
    echo "      -o '--remote me@my_builder \\"
    echo "          --remote-ssh-option IdentityFile ~/.ssh/my_key'"
    echo ""
    echo "  --"
    echo ""
    echo "  Following command builds all non-release aarch64 checks targets"
    echo "  (outputs 'checks.aarch64-linux.' not followed by a word 'release'"
    echo "  in the output target name) on the specified remote builder 'my_builder'"
    echo "  authenticating as user 'me':"
    echo ""
    echo "    $MYNAME \\"
    echo "      -f '^checks\.aarch64-linux\.((?!release).)*$' \\"
    echo "      -o '--remote me@my_builder"
    echo ""
}

################################################################################

print_err () {
    printf "${RED}Error:${NONE} %b\n" "$1" >&2
}

exit_unless_command_exists () {
    if ! command -v "$1" &>/dev/null; then
        print_err "command '$1' is not installed (Hint: are you inside a nix-shell?)"
        exit 1
    fi
}

on_exit () {
    echo "[+] Removing tmpdir: '$TMPDIR'"
    rm -fr "$TMPDIR"
}

filter_targets () {
    filter="$1"
    typeset -n ref_TARGETS=$2 # argument $2 is passed as reference
    # Output all flake output names
    nix flake show --all-systems --json |\
      jq  '[paths(scalars) as $path | { ($path|join(".")): getpath($path) }] | add' \
      >"$TMPDIR/all"
    # Tidy: remove leading spaces and quotes, keep only '.name' attributes
    sed -n -E "s/^.*\"(\S*).name\".*$/\1/p" "$TMPDIR/all" > "$TMPDIR/out_names"
    # Apply the 'filter' argument
    if ! grep -P "${filter}" "$TMPDIR/out_names" | sort | uniq >"$TMPDIR/out_filtered";
    then
        print_err "No flake outputs match filter: '$filter'"; exit 1
    fi
    # Read lines from $TMPDIR/out_filtered to array 'ref_TARGETS' which
    # is passed as reference, so this changes the caller's variable
    # shellcheck disable=SC2034 # ref_TARGETS is not unused
    readarray -t ref_TARGETS<"$TMPDIR/out_filtered"
}

argparse () {
    # Parse arguments
    OPTS=""; FILTER=""; TARGETS=();
    OPTIND=1
    while getopts "hvo:f:t:" copt; do
        case "${copt}" in
            h)
                usage; exit 0 ;;
            v)
                set -x ;;
            o)
                OPTS="$OPTARG" ;;
            f)
                FILTER="$OPTARG" ;;
            t)
                TARGETS+=("$OPTARG") ;;
            *)
                print_err "unrecognized option"; usage; exit 1 ;;
        esac
    done
    shift $((OPTIND-1))
    if [ -n "$*" ]; then
        print_err "unsupported positional argument(s): '$*'"; exit 1
    fi
    if [ -z "$FILTER" ] && (( ${#TARGETS[@]} == 0 )); then
        print_err "either '-f' or '-t' must be specified"; usage; exit 1;
    fi
    if [ -n "$FILTER" ] && (( ${#TARGETS[@]} != 0 )); then
        print_err "'-f' and '-t' are mutually exclusive"; usage; exit 1;
    fi
    echo "[+] OPTS='$OPTS'"
    if [ -n "$FILTER" ]; then
        echo "[+] FILTER='$FILTER'"
        filter_targets "$FILTER" TARGETS
    fi
    if (( ${#TARGETS[@]} != 0 )); then
        echo "[+] TARGETS:"
        printf '  %s\n' "${TARGETS[@]}"
    fi
}

################################################################################

nix_fast_build () {
    target=".#$1"
    timer_begin=$(date +%s)
    echo "[+] $(date +"%H:%M:%S") Start: nix-fast-build '$target'"
    # Do not use ssh ControlMaster as it might cause issues with
    # nix-fast-build the way we use it. SSH multiplexing needs to be disabled
    # both by exporting `NIX_SSHOPTS` and `--remote-ssh-option` since
    # `--remote-ssh-option` only impacts commands nix-fast-build invokes
    # on remote over ssh. However, some nix commands nix-fast-build runs
    # locally (e.g. uploading sources) internally also make use of ssh. Thus,
    # we need to export the relevant option in `NIX_SSHOPTS` to completely
    # disable ssh multiplexing:
    export NIX_SSHOPTS="-o ControlMaster=no"
    # shellcheck disable=SC2086 # intented word splitting of $OPTS
    nix-fast-build \
      --flake "$target" \
      --eval-workers 4 \
      --option accept-flake-config true \
      --remote-ssh-option ControlMaster no \
      --remote-ssh-option ConnectTimeout 10 \
      --no-download \
      --skip-cached \
      --no-nom \
      $OPTS \
      2>&1
    ret="$?"
    lapse=$(( $(date +%s) - timer_begin ))
    echo "[+] $(date +"%H:%M:%S") Stop: nix-fast-build '$target' (took ${lapse}s; exit $ret)"
    # 'nix_fast_build' is run in its own process. Below, we set the
    # process exit status
    exit $ret
}

################################################################################

main () {
    # Colorize output if stdout is to a terminal (and not to pipe or file)
    RED='' NONE=''
    if [ -t 1 ]; then RED='\033[1;31m'; NONE='\033[0m'; fi
    # Error out if following commands are not available
    exit_unless_command_exists grep
    exit_unless_command_exists nix-fast-build
    exit_unless_command_exists parallel
    exit_unless_command_exists sed
    # Parse arguments
    argparse "$@"
    # Remove TMPDIR on exit
    trap on_exit EXIT
    echo "[+] Using tmpdir: '$TMPDIR'"
    # Build TARGETS with nix-fast-build
    echo "[+] Running builds ..."
    jobs=5
    # Run the function 'nix_fast_build' for each flake target in TARGETS[]
    # array. Each instance of nix_fast_build will run in its own process.
    # Limit the maximum number of concurrent processes to $jobs:
    export -f nix_fast_build; export OPTS TMPDIR;
    parallel --will-cite -j"$jobs" --halt 2 -k --lb nix_fast_build ::: "${TARGETS[@]}"
}

main "$@"

################################################################################
