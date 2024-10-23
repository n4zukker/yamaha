#!/bin/bash

#
# Functions to interact with the github API.
#

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
      runJq --raw-output '
        "GET \(.url)\(
          ( ( .params // [] ) | select ( length > 0 ) | "?" + join ("&") ) // ""
        )"
      ' | while read -r msg ; do
        echo "$(date): ${msg}"
      done 1>&"${fdLog}"
    ) \
  | runJq --arg token "$GITHUB_TOKEN" --arg output_dir "${outputDir}" --raw-output '
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
      "header = \"Authorization: Bearer \( $token )\"",
      "header = \"Accept: application/json\"",
      "header = \"X-GitHub-Api-Version: 2022-11-28\"",
      "location",
      "write-out = \( $writeOut )",
      "output = \( $outputFilename )",
      ( $params[] | "data-urlencode = \"\( . )\"" )
    )
  ' \
  | tee >( sed -e 's/Bearer.*/Bearer XXX/' > "${curlConfigTrace}" ) \
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
  | tee "${curlMetadataTrace}" \
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

    runJq --slurpfile aBody "${outputFile}" ' . + { output: $aBody[0] } | del ( ( .response_code, .output_file ) )' <<<"${requestJson}" \
    | tee "${curlOutputTrace}"
    rm "${outputFile}"
  done || rc="$?"
  rm -r "${outputDir}"
  return "$rc"
}

declare NEXT_PAGES='5'

#
# This gets pages of content from github using its pagination API.
# https://docs.github.com/en/rest/using-the-rest-api/using-pagination-in-the-rest-api?apiVersion=2022-11-28
#
# Input to this function is GET requests like above with an optional "arrayName" property.
#
# This function performs a breadth-first GET of the pages it is asked to collect.
# It will try to get the first page for each request in stdin.   Then for each requests that might have
# more pages, it will get those.
#
# The output of this function is a copy of the input requests with a "output" array added.  The
# array will contain the contents of one page of data.  So, it could contain between zero and
# "perPage" entries.  For requests that needed more pages, additional copies of the input request
# are output, each with an "output" array.   The array might be empty.  That just indicates that no
# data was on the requested page, not that there wasn't any data at all.
# 
function PAGE_PIPE () {
  # Default to getting a single first page.
  local -r page="${1:-0}"
  local -r cToGet="${2:-1}"
  local -r perPage="${3:-50}"
  local -r cNextToGet="${4:-${NEXT_PAGES:-5}}"

  # Duplicate stdout so that we can write to it explictly.
  local fdOut
  exec {fdOut}>&1

  # This formula will determine if more pages need to be requested for some (or all) of the input.
  # As a side effect, it also writes the page contents to stdout.
  local -r nextPages="$(
    # Make up "n" requests for the pages to get.  Each request is made with
    # a page and per_page parameter.
    #
    # We GET the page and send the result to stdout.  We also check the result to
    # see if all the pages returned were completely full.  If the pages were all full
    # then there may be more pages to get.
    #
    # The arrayName jq command looks at the output and replaces the page contents with just the
    # number of entries returned.  Then the next jq command groups that by url (because we
    # might request pages 5, 6, 7 and 8 for a url at once) and looks at the entry count.
    # Any requests for pages that were all full is fed back so that we can make more requests.
    runJq --argjson lastPage "${page}" --argjson cToGet "${cToGet}" --argjson perPage "${perPage}" '
      . as $c
      | range ( $cToGet )
      | . as $i
      | ( {} + $c )
      | (
          .params |= (
              ( . // [] ) | map (
                select ( test("page=") // test("per_page=") | not )
              )
            +
              [ "page=\($lastPage + 1 + $i)", "per_page=\($perPage)" ]
          )
        )
    ' \
    | GET_PIPE \
    | tee "/dev/fd/${fdOut}" \
    | runJq '( .arrayName // "" ) as $arrayName | .output |= (if $arrayName != "" then .[$arrayName] else . end | length)' \
    | runJq --compact-output --argjson perPage "${perPage}" --slurp 'group_by (.url) | map ( select ( all (.output == $perPage ) ) ) | map(.[0])[]'
  )"

  # Release the file descriptor that we allocated for the previous step.
  exec {fdOut}>&-

  echo "${nextPages:-empty}" >"${pageTrace}"

  if [ -n "${nextPages}" ] ; then
    # If we need more pages, recurse to get them.
    echo -n "${nextPages}" | PAGE_PIPE "$(( page + cToGet ))" "${cNextToGet}" "${perPage}" "${cNextToGet}"
  fi
}

# Helper function to turn arguments into a series of JSON strings.
# If there are no arguments then nothing is output.
function jsonStrings () {
  if [[ $# > 0 ]]; then
    printf "%s\n" "${@}" | runJq --raw-input .
  fi
}

# Function to make a single GET request to github.
#
# Usage:
#   GET {endpoint} ...params...
#
function GET () {
  local -r endpoint="$1"
  shift

  jsonStrings "${@}" | runJq --slurp --arg url "${endpoint}" '{ url: $url, params: . }' | GET_PIPE | runJq --raw-output '.output'
}

# Function to get a page of data for a single resource.
#
# Usage:
#   PAGE {endpoint} {arrayName} ...params...
#
function PAGE () {
  local -r endpoint="$1"
  local -r arrayName="${2:-}"
  shift
  shift || true

  jsonStrings "${@}" | runJq --slurp --arg url "${endpoint}" --arg arrayName "${arrayName}" '{ url: $url, params: ., arrayName: $arrayName }' | PAGE_PIPE | runJq --raw-output '.output[]'
}

# Function to list all the organizations that the token can access.
#
function ORGS () {
  # https://docs.github.com/en/rest/orgs/orgs?apiVersion=2022-11-28#list-organizations
  PAGE 'https://api.github.kyndryl.net/organizations' '' "$@" \
  | runJq '{ url }' \
  | GET_PIPE \
  | runJq '.output'
}

# Function to list all repos within an organization.
#
# stdin should be one or more organizations JSON.  Specifically, each request should
# have a url property pointing to the link for that org.
#
# The output is simply a series of `{ url }` objects, one for each repo.
function REPOS () {
  # https://docs.github.com/en/rest/repos/repos?apiVersion=2022-11-28#list-organization-repositories
  local -r paramsJson="$(jsonStrings | runJq --slurp '.')"

  runJq --argjson params "${paramsJson}" '( .url |= "\(.)/repos" ) + { params: $params }' \
  | PAGE_PIPE \
  | runJq '.output[] | { url }'
}

# Function to list the workflow runs for a repository
# https://docs.github.com/en/rest/actions/workflow-runs?apiVersion=2022-11-28#list-workflow-runs-for-a-repository
#
# "created" should match the examples here:
# https://docs.github.com/en/search-github/getting-started-with-searching-on-github/understanding-the-search-syntax#query-for-dates
#
# stdin to this function should be one or more repos, specifically with a {url} property pointing to that repo.
function RUNS () {
  local -r created="$1"
  shift

  runJq --arg created "${created}" '.url |= "\(.)/actions/runs" | .params |= ( . // [] ) + [ "created=\($created)" ] | .arrayName="workflow_runs" ' \
  | PAGE_PIPE \
  | runJq '.output.workflow_runs[]'
}

# Function to list the workflows runs for a repository along with the jobs and steps executed for each run.
# https://docs.github.com/en/rest/actions/workflow-jobs?apiVersion=2022-11-28#list-jobs-for-a-workflow-run
#
function RUNS_WITH_JOBS () {
  local -r created="$1"
  shift

  RUNS "${created}" "$@" \
  | runJq '{ url: .jobs_url, arrayName: "jobs", run: . }' \
  | PAGE_PIPE \
  | runJq --slurp --compact-output '
      map( .run + { jobs: .output.jobs } | del (.output) )
      | group_by ( .url )
      | map ( .[0] + { jobs: [ .[].jobs[] ] } )[]
    '
}
