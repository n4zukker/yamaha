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
if [ -z "${fdLog:-}" ]; then
  exec {fdLog}>&1
fi
declare -r -x fdLog

# The pid variable will be used in our logs.
declare -r -x pid="${$}"

# Import logging
SOURCE_DIR="$( cd "$( dirname "${BASH_SOURCE[0]}" )" && pwd )"
source "${SOURCE_DIR}/lib/bash-pino-trace.sh"
source "${SOURCE_DIR}/lib/call-rest.sh"
source "${SOURCE_DIR}/lib/yamaha.sh"

respJson="$(GET /v1/main/setPower --data 'power=on')"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/getPresetInfo)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/getPlayInfo)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/system/getFeatures)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/system/getAccountStatus)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/recallPreset '--data' 'zone=main' '--data' 'num=6')"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(
  POST '/v1/netusb/setSearchString' --json "$(
    jq --null-input '{string: "Lebanon"}'
  )"
)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/getListInfo '--data' 'input=net_radio' '--data' 'size=8')"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

respJson="$(GET /v1/netusb/recallPreset '--data' 'zone=main' '--data' 'num=4')"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson
