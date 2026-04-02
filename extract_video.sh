#!/usr/bin/env zsh

v2_playlist_url="$1"
if [ -z $v2_playlist_url ]; then
    echo "Missing v2_playlist_url argument!" >&2
    exit 1
fi

wget "$v2_playlist_url" -O "test_video.json"

JSON="test_video.json"   # change to your file

is_valid_url() {
  # Regex to check protocol, domain, and general structure
  local url_regex='^(https?|ftp|file)://[-A-Za-z0-9\+&@#/%?=~_|!:,.;]*[-A-Za-z0-9\+&@#/%=~_|]$'
  
  if [[ "$1" =~ $url_regex ]]; then
    return 0 # Success
  else
    return 1 # Failure
  fi
}

combine_urls() {
  local url="$1"
  shift

  # 1. Handle relative appending
  for rel in "$@"; do
    if [[ "$rel" =~ ^https?:// ]]; then
      url="$rel"
    else
      [[ "$url" != */ ]] && url="${url%/*}/"
      url="${url}${rel}"
    fi
  done

  # Preserve trailing slash intent
  local has_trailing_slash=0
  [[ "$url" == */ ]] && has_trailing_slash=1

  # 2. Extract protocol, host, and path separately
  local proto="${url%%://*}://"
  local rest="${url#*://}"
  local host="${rest%%/*}"
  local path="${rest#*/}"

  # Handle case where there's no path
  [[ "$rest" == "$host" ]] && path=""

  # 3. Resolve path
  local -a parts resolved
  parts=( ${(s:/:)path} )

  for p in "${parts[@]}"; do
    if [[ "$p" == ".." ]]; then
      (( ${#resolved} > 0 )) && resolved=("${resolved[@]:0:-1}")
    elif [[ "$p" != "." && -n "$p" ]]; then
      resolved+=("$p")
    fi
  done

  # 4. Join path
  local joined_path="${(j:/:)resolved}"

  # Rebuild URL
  local final="${proto}${host}"
  [[ -n "$joined_path" ]] && final+="/${joined_path}"
  (( has_trailing_slash )) && final+="/"

  echo "$final"
}

base_url=$(jq '.base_url' "$JSON")
clip_id=$(jq '.clip_id' "$JSON")

# Remove the quotes
base_url="${(Q)base_url}"

BEST=$(jq -c '
  .video |
  max_by( (.avg_bitrate//0)*1000000 + (.bitrate//0)*1000 + (.sample_rate//0) )
' "$JSON")

echo "=== Best Video Stream ==="
echo "$BEST" | jq -r '
  "ID: \(.id)",
  "Avg Bitrate: \(.avg_bitrate)",
  "Bitrate: \(.bitrate)",
  "Sample Rate: \(.sample_rate)"
'

# Extract init + index segment
#echo "$BEST" | jq -r '
#  "Init Segment: \(.init_segment)",
#  "Index Segment: \(.index_segment)"
#'

init_segment="$( echo "$BEST" | jq '.init_segment' )"
index_segment="$( echo "$BEST" | jq '.index_segment' )"

init_segment="${(Q)init_segment}"
index_segment="${(Q)index_segment}"

echo "Init Segment: $init_segment"
echo "Index Segment: $index_segment"

raw_init_segment="$(echo "$init_segment" | base64 -d)"
printf "%s" "$raw_init_segment" > video_init_segment

mkdir -p ./video/

base_media_url="$(combine_urls "$v2_playlist_url" "$base_url")"
echo "$base_media_url"

good_count=0
bad_cnt=0
bad_list=()

# Download all segments of the best stream
echo "$BEST" | jq -r '
  .segments[] |
  "\(.url) \(.start)_\(.end).mp4"
' | while read -r url filename; do
    #echo "Downloading: $filename"
    if [ -f "./video/$filename" ]; then
      continue
    fi

    curl -L -# -f -o "./video/$filename" "${base_media_url}${url}"

    if [ $? -eq 0 ]; then
      ((good_count++))
    else
      ((bad_count++))
      bad_list+=("$filename")
    fi

  done

  echo "Downloaded: [G]$good_count [B]$bad_count"
