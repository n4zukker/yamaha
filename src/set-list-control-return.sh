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

declare -r API_PATH='http://10.33.20.47/YamahaExtendedControl'

# Usage:
#   GET {endpoint}
function GET () {
  local -r endpoint="$1"
  shift
  local -r otherArgs=("$@")

  local -r method='GET'
  local -r curlMethodArgs=(
    '--get'
    '--header' 'Accept: application/json'
  )

  curlMethod '--url' "${API_PATH}${endpoint}" "${otherArgs[@]}"
}

respJson="$(GET /v1/netusb/setListControl '--data' 'list_id=main' '--data' 'type=return' )"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/getListInfo '--data' 'input=net_radio' '--data' 'size=8' '--data' 'index=0')"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

