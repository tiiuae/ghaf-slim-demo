#!/usr/bin/env bash

# SPDX-FileCopyrightText: 2025 TII (SSRC) and the Ghaf contributors
# SPDX-License-Identifier: Apache-2.0

################################################################################

# This script is a helper to check if a github user belongs to an organization.

set -e # exit immediately if a command fails
set -E # exit immediately if a command fails (subshells)
set -u # treat unset variables as an error and exit
set -o pipefail # exit if any pipeline command fails

MYNAME=$(basename "$0")
RED='' NONE=''

################################################################################

usage () {
    echo ""
    echo "Usage: $MYNAME [-h] [-v] -t TOKEN -o ORG -u USER"
    echo ""
    echo "Helper to check if a github USER belongs to an organization ORG"
    echo "as documented in: https://docs.github.com/en/rest/orgs/members."
    echo ""
    echo "Options:"
    echo " -t    Github token that allows read access to organization members."
    echo " -o    Github organization name."
    echo " -u    Github username."
    echo " -v    Set the script verbosity to DEBUG"
    echo " -h    Print this help message"
    echo ""
    echo "Examples:"
    echo ""
    echo "  Following command exits with success if Github user 'tmpuser'"
    echo "  is a member of 'orgname' organization:"
    echo ""
    echo "    $MYNAME -t github_token_with_read_access_to_org_members -o orgname -u tmpuser"
    echo ""
}

################################################################################

print_err () {
    printf "${RED}Error:${NONE} %b\n" "$1" >&2
}

argparse () {
    # Colorize output if stdout is to a terminal (and not to pipe or file)
    if [ -t 1 ]; then RED='\033[1;31m'; NONE='\033[0m'; fi
    # Parse arguments
    TOKEN=""; ORG=""; USERNAME=""; OPTIND=1
    while getopts "hvt:o:u:" copt; do
        case "${copt}" in
            h)
                usage; exit 0 ;;
            v)
                set -x ;;
            t)
                TOKEN="$OPTARG" ;;
            o)
                ORG="$OPTARG" ;;
            u)
                USERNAME="$OPTARG" ;;
            *)
                print_err "unrecognized option"; usage; exit 1 ;;
        esac
    done
    shift $((OPTIND-1))
    if [ -n "$*" ]; then
        print_err "unsupported positional argument(s): '$*'"; exit 1
    fi
    if [ -z "$TOKEN" ]; then
        print_err "missing mandatory option (-t)"; usage; exit 1
    fi
    if [ -z "$ORG" ]; then
        print_err "missing mandatory option (-o)"; usage; exit 1
    fi
    if [ -z "$USERNAME" ]; then
        print_err "missing mandatory option (-u)"; usage; exit 1
    fi
}

exit_unless_command_exists () {
    if ! command -v "$1" &>/dev/null; then
        print_err "command '$1' is not installed (Hint: are you inside a nix-shell?)"
        exit 1
    fi
}

################################################################################

main () {
    argparse "$@"
    exit_unless_command_exists curl
    response=$(curl -L -o /dev/null -w "%{http_code}" \
       -H "Accept: application/vnd.github+json" \
       -H "Authorization: Bearer $TOKEN" \
       -H "X-GitHub-Api-Version: 2022-11-28" \
       "https://api.github.com/orgs/$ORG/members/$USERNAME" 2>/dev/null)
    if [ "$response" == "204" ]; then
        echo "[+] User '$USERNAME' is a member of '$ORG'"
        exit 0
    else
        echo "[+] User '$USERNAME' is not a member of '$ORG'"
        exit 1
    fi
}

main "$@"

################################################################################

