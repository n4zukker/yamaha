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

# Usage:
#   POST {endpoint}
function POST () {
  local -r endpoint="$1"
  shift
  local -r otherArgs=("$@")

  local -r method='POST'
  local -r curlMethodArgs=(
  )

  curlMethod '--url' "${API_PATH}${endpoint}" "${otherArgs[@]}"
}
