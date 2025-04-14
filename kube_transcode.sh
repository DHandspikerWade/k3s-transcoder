#!/bin/bash

INPUT_DIR="$1"
OUTPUT_DIR="$2"
DEFAULT_EXTRA_ARGS="--json"
NAMESPACE=transcode

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
    kubectl --namespace "$NAMESPACE" get job -l transcode_hash -o jsonpath='{.items[*].metadata.labels.transcode_hash}' | grep "$1" > /dev/null
    return $?
}

function submit_job() {
    local preset="$1"
    local input="$2"
    local output="$3"
    local extra_args=$(echo "$4" | sed "s/\"/'/g")

    # Hash to refer back to the job later
    local job_hash=$(echo -n "$preset $input $output $extra_args" | md5sum | awk '{ print tolower($1) }')
    if job_exists "$job_hash"; then
        echo "Job already exists!"

        # Is a duplicate an error? I think slient "ok" is fine
        return 0
    fi

    # yq insists on double quotes for a reason unclear to me
    cat template.job | yq "
        .metadata.labels.creator = \"$(basename "$0")\" |
        .metadata.labels.transcode_hash = \"$job_hash\" |
        .metadata.namespace = \"$NAMESPACE\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"PRESET_NAME\")).value = \"$preset\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"INPUT_FILE\")).value = \"$input\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"OUTPUT_FILE\")).value = \"$output\" |
        (.spec.template.spec.containers[0].env[] | select(.name == \"HANDBRAKE_ARGS\")).value = \"$extra_args\" |
        .spec.podFailurePolicy.rules[0].action = \"Ignore\" |
        .spec.podFailurePolicy.rules[0].onPodConditions[0].type = \"DisruptionTarget\"

    " | kubectl  --namespace "$NAMESPACE" create -f -
}

function create_suffix_output() {
    local known_suffixes=(
        '(WEBDL-1080p)'
        '(Bluray-1080p)'
        '- Bluray-2160p Remux' # Need to check before "- Bluray"
        '- Bluray AV1'
        '- DVD'
        '- Bluray'
        '- UHD'
        '- HDR'
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
    local preview_count=60

    echo "Checking $1"

    # TODO: Clean-up duplicate file checking code

    for i in $(seq 0 $(($tracks - 1)))
    do
        local is_hdr=0
        local track_data="$(echo "$media_info"| jq '.media.track['$i']')"
        if [ "$(echo "$track_data"| jq '.["@type"]')" = '"Video"' ]; then
                preview_count=$(echo '(' $(echo "$track_data" | jq .Duration --raw-output) / 60 ') + 1'| bc)
                echo "previewing $preview_count for " $(echo "$track_data" | jq .Duration --raw-output)

                # Safety catch for counting errors or sub-minute videos 
                if [ "$preview_count" -lt 10 ]; then
                    preview_count=10
                fi

                # Over three hours, we don't need a frame a minute
                if [ "$preview_count" -gt 180 ]; then
                    preview_count=180
                fi

             # Only HDR content cares about how bright the mastering was, assume if mentioned it's HDR
            if [ $(echo "$track_data"| jq '. | has("MasteringDisplay_Luminance")') = 'true' ]; then
                is_hdr=1
                echo "Found HDR video"

                local possible_file="$(create_suffix_output "$1" " - SDR")"
                if file_exists "$possible_file"; then
                    echo "$possible_file already exists"
                else
                    submit_job "HDR to SDR" "$1" "$possible_file" "$DEFAULT_EXTRA_ARGS --json --previews=$preview_count"
                fi
            fi
        fi

        if  [ "$(echo "$track_data"| jq '.["@type"]')" = '"Text"' ]; then
            local lower_title="$(echo "$track_data"| jq '.["Title"]' | awk '{ print tolower($0) }')"
            local language="$(echo "$track_data"| jq '.["Language"]' | awk '{ print tolower($0) }')"
            local forced="$(echo "$track_data"| jq '.["Forced"]' | awk '{ print tolower($0) }')"
            local default="$(echo "$track_data"| jq '.["Default"]' | awk '{ print tolower($0) }')"


            if [[ "$language" = '"en"' ]]; then
                local burnin=0

                if [[ "$lower_title" =~ (signs)|(songs) ]]; then
                    burnin=1
                    echo "Found song"
                fi

                if [[ "$forced" = '"yes"' ]]; then
                    burnin=1
                    echo "found force"
                fi

                if [[ "$default" = '"yes"' ]]; then
                    burnin=1
                    echo "found default"
                fi


                if [[ $burnin -gt 0 ]]; then
                    echo "Found subtitle for signs/songs or forced"

                    local possible_file="$(create_suffix_output "$1" " - Burn-in")"
                    # Streaming preset uses webm to compatibility 
                    # TODO: get the file type from the preset
                    possible_file="${possible_file%.mkv}.webm"
                    if file_exists "$possible_file"; then
                        echo "$possible_file already exists"
                    else
                        local subtitle_position="$(echo "$track_data"| jq -r '.["@typeorder"]' --raw-output)"

                        if [[ "$subtitle_position" = "null" ]]; then
                            echo "Missing typeorder on subtitle. Assuming an index #1."
                            subtitle_position=1
                        fi

                        echo  "$DEFAULT_EXTRA_ARGS -s $subtitle_position --subtitle-burned 1 --json --previews=$preview_count"
                        submit_job "Streaming" "$1" "$possible_file" "$DEFAULT_EXTRA_ARGS -s $subtitle_position --subtitle-burned 1 --json --previews=$preview_count"
                    fi
                fi
            fi
        fi
    done 
}

while IFS= read -d '' filename; do
  each_input "$filename"
done < <(find "$INPUT_DIR"  -maxdepth 10 -type f \( -iname '*.mkv' -o -iname '*.mp4' -o -iname '*.webm' \) -print0 | sort -z)
