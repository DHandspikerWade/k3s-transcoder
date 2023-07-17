#!/bin/bash

INPUT_DIR="$1"
OUTPUT_DIR="$2"

# As a function because I should be able to check from transcoder POV later rather than the script runner.
function file_exists() {
    test -e "$1"
    return $?
}

function trim_input_dir() {
    # TODO: Replace this with a actual shell solution
    php -r 'echo ltrim(substr($argv[2], strlen($argv[1]) * 1), "/");' "$INPUT_DIR" "$1"
}

function job_exists() {
    kubectl get job -l transcode_hash -o jsonpath='{.items[*].metadata.labels.transcode_hash}' | grep "$1" > /dev/null
    return $?
}

function submit_job() {
    preset="$1"
    input="$2"
    output="$3"
    extra_args="$4"

    # Hash to refer back to the job later
    job_hash=$(echo -n "$preset $input $output $extra_args" | md5sum | awk '{ print tolower($1) }')

    if job_exists "$job_hash"; then
        echo "Job already exists!"

        # Is a duplicate an error? I think slient "ok" is fine
        return 0
    fi

    # yq insists on double quotes for a reason unclear to me
    cat template.job | yq "
        .metadata.labels.creator = \"$(basename "$0")\" |
        .metadata.labels.transcode_hash = \"$job_hash\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"PRESET_NAME\")).value = \"$preset\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"INPUT_FILE\")).value = \"$input\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"OUTPUT_FILE\")).value = \"$output\"
    " | kubectl create -f -
}

function create_suffix_output() {
    local known_suffixes=(
        '- DVD'
        '- Bluray'
        '- UHD'
        '- HDR'
        '- Bluray-2160p Remux' # Made the mistake using Sonarr's naming for early rips
        '- Super Duper UHD' # Deadpool 2 has multiple UHD discs
    )
    local old_name=$( basename "$1")
    local name="${old_name%.*}"
    local extension="${old_name##*.}"

    for suffix in "${known_suffixes[@]}"; do
        name="${name/$suffix/""}"
    done

    # trim trailing space
    echo "$OUTPUT_DIR"/`dirname "$(trim_input_dir "$1")"`/`echo $name | sed 's/ *$//g'`"${2}.${extension}"
}

function each_input() {
    local media_info=$(mediainfo --Output=JSON --Language=raw "$1")
    local tracks=$(echo "$media_info"| jq '.media.track | length')

    echo "Checking $1"
    # echo "Has $tracks"

    for i in $(seq 0 $(($tracks - 1)))
    do
        local track_data="$(echo "$media_info"| jq '.media.track['$i']')"
        if [ "$(echo "$track_data"| jq '.["@type"]')" = '"Video"' ]; then

             # Only HDR content cares about how bright the mastering was, assume if mentioned it's HDR
            if [ $(echo "$track_data"| jq '. | has("MasteringDisplay_Luminance")') = 'true' ]; then
                echo "Found HDR video"

                possible_file="$(create_suffix_output "$1" " - SDR")"

                if file_exists "$possible_file"; then
                    echo "$possible_file already exists"
                else
                    submit_job "HDR to SDR" "$1" "$possible_file"
                fi  
            fi
        fi
    done 
}

while IFS= read -d '' filename; do
  each_input "$filename"
done < <(find "$INPUT_DIR"  -maxdepth 10 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.webm' \) -print0 )
