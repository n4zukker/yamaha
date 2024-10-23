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

declare -r index="${1}"

request="$(
  runJq --null-input --arg path "${API_PATH}" '
    {
      url: "\($path)/v1/netusb/getListInfo",
      params: [ "list_id=main", "input=net_radio", "lang=en" ],
      arrayName: "list_info"
    }
  '
)"

exec {fdOut}>&1

respJson="$(PAGE_PIPE <<<"${request}" | runJq --slurp 'map ( .output.list_info ) | add' )"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson
echo "${respJson}"
