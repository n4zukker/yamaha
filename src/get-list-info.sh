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

respJson="$(
    runJq --null-input --arg path "${API_PATH}" '
      {
        url: "\($path)/v1/netusb/getListInfo",
        params: [ "list_id=main", "input=net_radio", "lang=en" ],
        arrayName: "list_info"
      }
    ' \
  | PAGE_PIPE \
  | runJq --slurp '
      def tobits:
        def stream:
          recurse(if . > 0 then ./2 | floor else empty end) | . % 2
        ;

      if . == 0 then
        [0]
      else
        [stream] | reverse | .[1:]
      end
    ;

    ( [
        { longname: "Name exceeds max byte limit" },
        { select:   "Capable of Select"           },
        { play:     "Capable of Play"             },
        { search:   "Capable of Search"           },
        { art:      "Album Art available"         },
        { playing:  "Now Playing"                 },
        { bookmark: "Capable of Add Bookmark"     },
        { track:    "Capable of Add Track"        }
      ] ) as $attributeText
    | map(
          .output.list_info[]
	  | .attribute |= ( tobits | reverse | to_entries | map(
            select ( .value == 1 ) | $attributeText[.key]
          ) | add )
      )
    '
)"

pinoTrace -u "${fdLog}" 'Response from yamaha' respJson

echo "${respJson}"
