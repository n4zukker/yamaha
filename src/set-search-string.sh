#!/bin/bash
#
# Instruct bash to be strict about error checking.
set -e          # stop if an error happens
set -u          # stop if an undefined variable is referenced
set -o pipefail # stop if any command within a pipe fails
set -o posix    # extra error checking

# We will log to stdout.  Get a copy of the stdout file descriptor.
# This will let us write logs even when we redirect stdout within the script
# for other purposes.
exec {fdLog}>&1

# The pid variable will be used in our logs.
declare -r -x pid="${$}"

# Import logging
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${SOURCE_DIR}/lib/bash-pino-trace.sh"
source "${SOURCE_DIR}/lib/call-rest.sh"
source "${SOURCE_DIR}/lib/yamaha.sh"

declare -r search="${1}"
declare -r index="${2:-}"

respJson="$(
  POST '/v1/netusb/setSearchString' --json "$(
    jq --arg search "${search}" --arg index "${index}" --null-input '
        {string: $search}
      + if $index != "" then {index: ($index | tonumber)} else {} end
    '
  )"
)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

"${SOURCE_DIR}/get-list-info.sh"
