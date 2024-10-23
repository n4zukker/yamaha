#!/bin/bash

#
# Function to make an arbitrary <method> request to an HTTP server.
#
# Usage:
#   curlMethod {args...} {url}
#
# with the following two variables set:
#   curlMethodArgs -- an array of arguments specific to the method
#      e.g. ('--get') for GET; (-X POST -H 'Content-Type: application/json') for POST...
#      This array is not logged, so sensitive info such as tokens should go here.   
#
#   method -- the name of the method (GET, POST, PATCH...)
#
# Logs and returns the JSON result of the request to stdout.
#
function curlMethod () {
  local argArray=("$@")

  local -r responseJsonFile="$(mktemp)"
  local -r responseCodeJsonFile="$(mktemp)"
  local rc

  responseCode=''

  pinoTrace -u "${fdLog}" 'Making curl request' method argArray
  if curl \
    --insecure \
    "${curlMethodArgs[@]}" \
    --silent \
    --output "${responseJsonFile}" \
    --write-out '{\n"response_code": %{response_code}\n}' \
    "$@" \
    >"${responseCodeJsonFile}" ; \
  then
    responseCode="$(grep '^"response_code": [0-9][0-9]*$' "${responseCodeJsonFile}" | tail --lines=1 | sed -e 's/"response_code": //')"
    local -r wcResponse="$( wc <"${responseJsonFile}")"
    case "${responseCode}" in
      2*)
        pinoTrace -u "${fdLog}" 'Response from request' method argArray responseCodeJsonFile responseCode wcResponse
        cat "${responseJsonFile}"
        rc='0'
        ;;

      4* | 5*)
        rc="$(( ${responseCode} - 400 ))"
        pinoTrace -u "${fdLog}" 'Response from request' method argArray responseCodeJsonFile responseJsonFile responseCode wcResponse
        ;;

      *)
        pinoTrace -u "${fdLog}" 'Response from request' method argArray responseCodeJsonFile responseJsonFile responseCode 
        rc='1'
        ;;
    esac
  else
    local -r rcCurl="$?"
    rc="${rcCurl}"
    pinoTrace -u "${fdLog}" 'Curl failed' method argArray rcCurl
  fi

  rm "${responseJsonFile}" "${responseCodeJsonFile}"
  return "${rc}"
}



# Run jq and print an error message indicating the arguments, line number, etc
# if there was a problem.  We use jq a lot here and the error messages that jq
# writes out can really benefit when placed in a context.
function runJq () {
  rc='0'
  jq "${@}" || rc="$?"
  if [[ "${rc}" != 0 ]]; then
    (
      echo "$(date): jq in ${FUNCNAME[0]}:${BASH_LINENO[0]} ended code ${rc} command -- ${@}"
    ) 1>&"${fdLog}"
  fi
  return "$rc"
}


# Run a series of GET requests and return the output in a pipe.
#
# Stdin should be one or more JSON objects.
#   {
#     "url": <url to GET>,
#     "params": <optional params to add to the GET>
#   }
#
# Stdout will be an echo of the input JSON object
# plus these additional properties:
#
#  {
#    "response_code": <HTTP response code, e.g. 200>,
#    "output_file": <file which contains response output>
#  }
#
# It's the responsibility of the caller to delete each output file
# once it is no longer needed.
#
# Pass in the name of a directory for the output files as the first argument
# to this function.
#
# Example:
# Command: curlPipe '/tmp/foo'
# Input:
#   { "url": "https://example.com", "context": "Sample GET" }
#
# Output:
#   { "url": "https://example.com", "respoonse_code": "200", "output_file": "/tmp/foo/1.out", "context": "Sample GET" }
#
# --------
#
# Input:
#   { "url": "https://example.com", "params": [ "page=1" }
#   { "url": "https://example.com", "params": [ "page=2", "search=abc" ]
#
# Output:
#   { "url": "https://example.com", "respoonse_code": "200", "output_file": "/tmp/foo/1.out", "params": [ "page=1" ] }
#   { "url": "https://example.com", "respoonse_code": "200", "output_file": "/tmp/foo/2.out", "params": [ "page=2", "search=abc" ] }
#
function curlPipe () {
  local -r outputDir="$1"
  local iFile=0

  # We expect to run many requests.  Put each request onto a separate line so that we can
  # easily read each one fully into bash.
  runJq --compact-output . \
  | while read -r getRequestJson ; do
    # Store the request into a numbered file and pair it with an output file.
    # curl doesn't like to write out long lines in its scripting language.  So
    # we will store the request body in a file and just write out the minimal via
    # curl.
    : $(( iFile++ ))
    requestJsonFile="${outputDir}/${iFile}.req"
    requestOutputFile="$outputDir/${iFile}.out"
    echo -n "${getRequestJson}" >"${requestJsonFile}"
    runJq --compact-output --arg requestJsonFile "${requestJsonFile}" --arg outputFile "${requestOutputFile}" '{ url, params, request_file: $requestJsonFile, output_file: $outputFile }' <<<"${getRequestJson}"
  done \
  | tee >(
      # Log a message so that we can see what GET requests are being made and have an idea of
      # the program's progress.
      runJq --raw-output '[.url, ( .params | join("&") )] | @sh' | while read -r args ; do
        eval set -- "${args}"
	url="$1"
	params="$2"
        pinoTrace -u "${fdLog}" 'GET' url params
      done
    ) \
  | runJq --arg output_dir "${outputDir}" --raw-output '
    #
    # The curl --config option gives us a way to perform many GET requests in
    # a single curl command.  See https://curl.se/docs/manpage.html#-K
    #
    # We will execute a GET request and write the output to a file.
    # For each request, JSON is written to stdout containing the
    # output filename and the response code of the request.
    #
    # One nice thing about this is that curl will keep the TCP/IP connection
    # open and re-use it across requests.
    #
    ( .output_file ) as $outputFilename
    | ( .request_file ) as $requestFilename
    | .url as $url
    | (
      (
        {
          url: $url,
	  request_file: $requestFilename,
          response_code: "%{response_code}",
	  output_file: $outputFilename
        }
      ) | @json
    ) as $writeOut
    | ( .params // [] ) as $params
    | (
      "#",
      "# \( @json )",
      "#",
      "next",
      "silent",
      "get",
      "url = \( $url )",
      "header = \"Accept: application/json\"",
      "location",
      "write-out = \( $writeOut )",
      "output = \( $outputFilename )",
      ( $params[] | "data-urlencode = \"\( . )\"" )
    )
  ' \
  | if read -r firstLine ; then
      # Run curl.  "--config -" is used so that we don't have to
      # write to the file system.  The bearer token doesn't get
      # stored on disk this way.
      #
      # One caveat is that curl will complain if it is passed an
      # empty file for config.  The if statement above and echo here
      # causes curl to only run when there is at least one line
      # in the stdin config file. 
      #
      ( echo "${firstLine}" ; cat ) | curl --config -
    fi \
  | runJq --raw-output '[ .request_file, ( . | @json ) ] | @sh' \
  | while read -r curlOutput ; do
      # As curl makes its requests, JSON gets emitted.  We
      # turn this JSON into something that the shell can parse
      # so that we can inject the contents of the request body
      # back into the output.
      eval set -- "${curlOutput}"
      requestFile="$1"
      json="$2"
      runJq --compact-output --slurpfile aRequest "${requestFile}" '. + $aRequest[0] | del(.request_file)' <<<"${json}"
      rm "${requestFile}"
    done
}

#
# Make GET requests using the curl pipe call above.
# This runs the same way as curlPipe except:
#   * The result of each GET is returned in an "output" property 
#   * This fails if the response_code is something other than a 2xx or 4xx.
#
function GET_PIPE () {
  local -r outputDir="$(mktemp --directory)"

  rc='0'
  curlPipe "${outputDir}" \
  | runJq --raw-output '[ .response_code, .url, .output_file, ( . | @json ) ] | @sh' \
  | while read -r curlResult ; do
    eval set -- "${curlResult}"
    responseCode="$1"
    url="$2"
    outputFile="$3"
    requestJson="$4"

    case "${responseCode}" in
      2* | 4*) ;;
      *)
        echo "$(date): GET ${url} returned ${responseCode}" 1>&"${fdLog}"
        exit 1;;      
    esac

    runJq --slurpfile aBody "${outputFile}" ' . + { output: $aBody[0] } | del ( ( .response_code, .output_file ) )' <<<"${requestJson}"
    rm "${outputFile}"
  done || rc="$?"
  rm -r "${outputDir}"
  return "$rc"
}

#
# This gets pages of content from yamaha using its pagination API.
#
# Input to this function is GET requests like above with an optional "arrayName" property.
#
# This function performs a breadth-first GET of the pages it is asked to collect.
# It will try to get the first page for each request in stdin.   Then for each requests that might have
# more pages, it will get those.
#
function PAGE_PIPE () {
  local -r perPage="${1:-8}"

  exec {fdOut}>&1

  # We GET the page and send the result to stdout.  We also check the result to
  # see if all the pages returned were completely full.  If the pages were all full
  # then there may be more pages to get.
  runJq --argjson lastIndex "0" --argjson perPage "${perPage}" '
    . as $c
    | ( {} + $c )
    | (
        .params |= (
            ( . // [] ) | map (
              select ( test("index=") // test("size=") | not )
            )
          +
            [ "index=\($lastIndex)", "size=\($perPage)" ]
        )
      )
  ' \
  | GET_PIPE \
  | tee "/dev/fd/${fdOut}" \
  | runJq --argjson perPage "${perPage}" '
      (
          .arrayName as $arrayName
        | .output
	| ( .index + ( .[$arrayName] | length ) )
      ) as $nextIndex
      | .output.max_line as $maxIndex
      | (
            del(.output)
	  | .params |= ( ( . // [] ) | map ( select ( test("index=") | not ) ) )
	) as $nextRequest
      | range ( $nextIndex ; $maxIndex; $perPage )
      | $nextRequest + { params: ( $nextRequest.params + [ "index=\(.)" ] ) }
    ' \
   | GET_PIPE
}

