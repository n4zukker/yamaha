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


respJson="$(
    GET '/v1/netusb/getPlayInfo' \
  | runJq '
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
        { playable:        "Playable"},
        { stop:            "Capable of Stop"},
        { pause:           "Capable of Pause"},
        { prev:            "Capable of Prev Skip"},
        { next:            "Capable of Next Skip"},
        { fastreverse:     "Capable of Fast Reverse"},
        { fastforward:     "Capable of Fast Forward"},
        { repeat:          "Capable of Repeat"},
        { shuffle:         "Capable of Shuffle"},
        { feedback:        "Feedback Available (Pandora)"},
        { thumbsup:        "Thumbs-Up (Pandora)"},
        { thumbsdown:      "Thumbs-Down (Pandora)"},
        { video:           "Video (USB)"},
        { bookmark:        "Capable of Bookmark (Net Radio)"},
        { dmr:             "DMR Playback (Server)"},
        { station:         "Station Playback (Rhapsody / Napster)"},
        { ad:              "AD Playback (Pandora)"},
        { shared:          "Shared Station (Pandora)"},
        { addTrack:        "Capable of Add Track (Rhapsody/Napster/Pandora/JUKE/Qobuz)"},
        { addAlbum:        "Capable of Add Album (Rhapsody / Napster / JUKE)"},
        { shuffleStation:  "Shuffle Station (Pandora)"},
        { addChannel:      "Capable of Add Channel (Pandora)"},
        { sample:          "Sample Playback (JUKE)"},
        { musicPlay:       "MusicPlay Playback (Server)"},
        { link:            "Capable of Link Distribution"},
        { addPlaylist:     "Capable of Add Playlist (Qobuz)"},
        { addMusicCast:    "Capable of add MusicCast Playlist"}
      ]
    ) as $attributeText
  | .attribute |= ( tobits | reverse | to_entries | map(
      select ( .value == 1 ) | $attributeText[.key]
    ) | add )
  '
)"
pinoTrace -u "${fdLog}" 'Response from yamaha' respJson
