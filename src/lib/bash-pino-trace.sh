#!/bin/bash

declare -f pinoTrace > /dev/null && return 0

declare -r hostname_for_pinoTrace="$(hostname)"

#
# Function to write a pino-like JSON log message.
# See https://www.npmjs.com/package/pino-pretty
#
# Usage:  pinoTrace {-u [fd]} <msg> <var1> <var2> ...
#
# Example:
#         cdir="ABC"
#         pinoTrace "Customer code" cdir
#
# will output JSON with {"msg": "Customer code", "cdir": "ABC"}
#
# if a variable name ends with "Json" then its value is treated as JSON
# if a variable name ends with "JsonFile" then its value is treated as naming a file containing one JSON value
# if a variable name ends with "TextFile" then its value is treated as naming a file containing plain text
# if a variable name ends with "Array" then its value is treated as an array of strings
# otherwise the values are considered strings.
#
# Output is written to stdout.  Pass in a different file descriptor if you want
# the output to appear elsewhere.
#
#         pinoTrace -u 2 "Customer code" cdir
#
# will output to stderr instead (file descriptor #2).
#
# You can also list names of variables in the LOGPROPS.  Those variables will be included
# in the log output.
#
# Note: variables here are passed by name, not value.
#
function pinoTrace() {
  # Save and turn off the shell tracing so that the caller doesn't have to see
  # all our commands when he's debugging his own code.
  local xtrace="$(shopt -po xtrace)"
  set +x

  # Where we write output to, defaults to stdout
  local fd=1

  local OPTARG OPTIND
  while getopts ':u:' opt; do
    case ${opt} in
      u ) fd="${OPTARG}"
        ;;
      \? ) echo "Usage: ${FUNCNAME[0]} [-u {fd}] message {var1} {var2}..." 1>&2
        return 1
        ;;
    esac
  done
  shift $((OPTIND -1))

  # first argument is a message string
  # subsequent arguments are names of variables to include in the JSON
  local -r msg="$1"
  shift

  local i
  local arr
  local tfile

  local myPid="${pid:-$$}"

  local -a tempFiles=()
  local -a props=()

  read -a props <<<"${LOGPROPS:-}"
  props+=("$@")

  # Make an array of variable assignment arguments to be passed on the `jq` command line.
  local -a argAssignments=('--arg' 'pid' "${myPid}" '--arg' 'msg' "${msg}" '--arg' 'hostname' "${hostname_for_pinoTrace}")
  for v in "${props[@]}"; do
    if [ -v "$v" ]; then
      if [[ "$v" == *Json ]]; then
        if [ -n "${!v}" ] ; then
          argAssignments+=('--arg' "${v}" "${!v}")
        fi
      elif [[ "$v" == *JsonFile ]]; then
        if [ -n "${!v}" ] ; then
          tfile="$(mktemp)"
          tempFiles+=("${tfile}")

          jq --raw-input --slurp . "${!v}" >"${tfile}"
          argAssignments+=('--slurpfile' "${v}" "${tfile}")
        fi
      elif [[ "$v" == *TextFile ]]; then
        if [ -n "${!v}" ] ; then
          tfile="$(mktemp)"
          tempFiles+=("${tfile}")

          jq --raw-input --slurp . "${!v}" >"${tfile}"
          argAssignments+=('--slurpfile' "${v}" "${tfile}")
        fi
      elif [[ "$v" == *Array ]]; then
        i=1
        arr="${v}[@]"
        for ai in "${!arr}"; do
          argAssignments+=('--arg' "${v}${i}" "${ai}")
          i=$(( ${i} + 1 ))
        done
      else
        argAssignments+=('--arg' "${v}" "${!v}")
      fi
    else
      argAssignments+=('--arg' "${v}" '<<<not defined>>>')
    fi
  done

  # Make a jq expression that pulls in all the variable assignments above.
  # jqVariables will be something like:
  #            { cdir: $cdir }
  #         or { cdir: $cdir, cmdArray: [ $cmdArray1, $cmdArray2 ] }
  #
  local jqVariables="$(
    #
    # If bash is set to warn about unset variables then we
    # will get an error if we are showing empty arrays.
    # Always turn this flag off here.
    # p.s. I'm not sure why we don't have to do the same above.
    #
    set +o nounset

    local cExpr=1
    local objExp
    local j
    for v in "${props[@]}"; do
      objExp="$(
        if [[ "$v" == *Json ]]; then
          if [ -n "${!v}" ] ; then
            echo "${v}: (try (\$${v} | fromjson) catch \"Not JSON: '\(\$${v})'\")"
          fi
        elif [[ "$v" == *JsonFile ]]; then
          if [ -n "${!v}" ] ; then
            echo "${v}: (try (\$${v}[0] | fromjson) catch \"Not JSON: '\(\$${v}[0])'\")"
          fi
        elif [[ "$v" == *TextFile ]]; then
          if [ -n "${!v}" ] ; then
            echo "${v}: \$${v}[0]"
          fi
        elif [[ "$v" == *Array ]]; then
          arr="${v}[@]"
          j=1
          echo -n "${v}: ["
          for aj in "${!arr}"; do
            if [ "${j}" -gt 1 ]; then
              echo -n ", "
            fi
            echo -n '$'"${v}${j}"
            j=$(( ${j} + 1 ))
          done
          echo -n "]"
        else
          echo "${v}: \$${v}"
        fi
      )"
      if [ -n "${objExp}" ] ; then
        if [ "${cExpr}" -gt 1 ]; then
          echo -n ", "
        fi
        echo "${objExp}"
        cExpr=$(( ${cExpr} + 1 ))
      fi
    done
  )"

  # Let `jq` construct the JSON based on the argument assignments and jq expression formed above.
  jq --null-input --compact-output "${argAssignments[@]}" '{ time: (now * 1000 | floor), level: 30, v: 1, pid: $pid, msg: $msg, hostname: $hostname}+'"{${jqVariables}}" 1>&"${fd}"

  if (( ${#tempFiles[@]} )); then
    rm "${tempFiles[@]}"
  fi

  # Restore what was set for tracing
  eval "${xtrace}"
}
