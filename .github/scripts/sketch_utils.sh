#!/bin/bash

function build_sketch(){ # build_sketch <ide_path> <user_path> <path-to-ino> [extra-options]
    while [ ! -z "$1" ]; do
        case "$1" in
        -ai )
            shift
            ide_path=$1
            ;;
        -au )
            shift
            user_path=$1
            ;;
        -t )
            shift
            target=$1
            ;;
        -fqbn )
            shift
            fqbn=$1
            ;;
        -o )
            shift
            options=$1
            ;;
        -s )
            shift
            sketchdir=$1
            ;;
        * )
            break
            ;;
        esac
        shift
    done

    xtra_opts=$*

    if [ -z $sketchdir ]; then
        echo "ERROR: Sketch directory not provided"
        echo "$USAGE"
        exit 1
    fi

    # No FQBN was passed, try to get it from other options

    if [ -z $fqbn ]; then
        if [ -z $target ]; then
            echo "ERROR: Unspecified chip"
            echo "$USAGE"
            exit 1
        fi

        # The options are either stored in the test directory, for a per test
        # customization or passed as parameters.  Command line options take
        # precedence.  Note that the following logic also falls to the default
        # parameters if no arguments were passed and no file was found.

        if [ -z $options ] && [ -f $sketchdir/cfg.json ]; then
            # The config file could contain multiple FQBNs for one chip.  If
            # that's the case we build one time for every FQBN.

            len=`jq -r --arg chip $target '.targets[] | select(.name==$chip) | .fqbn | length' $sketchdir/cfg.json`
            fqbn=`jq -r --arg chip $target '.targets[] | select(.name==$chip) | .fqbn' $sketchdir/cfg.json`
        else
            # Since we are passing options, we will end up with only one FQBN to
            # build.

            len=1

            # Default FQBN options if none were passed in the command line.

            esp32_opts="PSRAM=enabled,PartitionScheme=huge_app"
            esp32s2_opts="PSRAM=enabled,PartitionScheme=huge_app"
            esp32s3_opts="PSRAM=opi,USBMode=default,PartitionScheme=huge_app"
            esp32c3_opts="PartitionScheme=huge_app"

            # Select the common part of the FQBN based on the target.  The rest will be
            # appended depending on the passed options.

            case "$target" in
                "esp32")
                    fqbn="espressif:esp32:esp32:${options:-$esp32_opts}"
                ;;
                "esp32s2")
                    fqbn="espressif:esp32:esp32s2:${options:-$esp32s2_opts}"
                ;;
                "esp32c3")
                    fqbn="espressif:esp32:esp32c3:${options:-$esp32c3_opts}"
                ;;
                "esp32s3")
                    fqbn="espressif:esp32:esp32s3:${options:-$esp32s3_opts}"
                ;;
            esac

            # Make it look like a JSON array.

            fqbn="[\"$fqbn\"]"
        fi
    else
        # An FQBN was passed.  Make it look like a JSON array.

        len=1
        fqbn="[\"$fqbn\"]"
    fi

    if [ -z "$fqbn" ]; then
        echo "No FQBN passed or unvalid chip: $target"
        exit 1
    fi

    ARDUINO_CACHE_DIR="$HOME/.arduino/cache.tmp"
    if [ -z "$ARDUINO_BUILD_DIR" ]; then
        build_dir="$sketchdir/build"
    else
        build_dir="$ARDUINO_BUILD_DIR"
    fi

    mkdir -p "$ARDUINO_CACHE_DIR"
    for i in `seq 0 $(($len - 1))`
    do
        rm -rf "$build_dir$i"
        mkdir -p "$build_dir$i"
        currfqbn=`echo $fqbn | jq -r --argjson i $i '.[$i]'`
        sketchname=$(basename $sketchdir)
        echo "Building $sketchname with FQBN=$currfqbn"
        $ide_path/arduino-builder -compile -logger=human -core-api-version=10810 \
            -fqbn=\"$currfqbn\" \
            -warnings="all" \
            -tools "$ide_path/tools-builder" \
            -tools "$ide_path/tools" \
            -built-in-libraries "$ide_path/libraries" \
            -hardware "$ide_path/hardware" \
            -hardware "$user_path/hardware" \
            -libraries "$user_path/libraries" \
            -build-cache "$ARDUINO_CACHE_DIR" \
            -build-path "$build_dir$i" \
            $xtra_opts "${sketchdir}/${sketchname}.ino"
    done
}

function count_sketches(){ # count_sketches <path> [target]
    local path=$1
    local target=$2

    if [ $# -lt 1 ]; then
      echo "ERROR: Illegal number of parameters"
      echo "USAGE: ${0} count <path> [target]"
    fi

    rm -rf sketches.txt
    if [ ! -d "$path" ]; then
        touch sketches.txt
        return 0
    fi

    local sketches=$(find $path -name *.ino | sort)
    local sketchnum=0
    for sketch in $sketches; do
        local sketchdir=$(dirname $sketch)
        local sketchdirname=$(basename $sketchdir)
        local sketchname=$(basename $sketch)
        if [[ "$sketchdirname.ino" != "$sketchname" ]]; then
            continue
        elif [[ -n $target ]] && [[ -f "$sketchdir/.skip.$target" ]]; then
            continue
        else
            echo $sketch >> sketches.txt
            sketchnum=$(($sketchnum + 1))
        fi
    done
    return $sketchnum
}

function build_sketches(){ # build_sketches <ide_path> <user_path> <target> <path> <chunk> <total-chunks> [extra-options]

    local args=""
    while [ ! -z "$1" ]; do
        case $1 in
        -ai )
            shift
            ide_path=$1
            ;;
        -au )
            shift
            user_path=$1
            ;;
        -t )
            shift
            target=$1
            args+=" -t $target"
            ;;
        -fqbn )
            shift
            fqbn=$1
            args+=" -fqbn $fqbn"
            ;;
        -p )
            shift
            path=$1
            ;;
        -i )
            shift
            chunk_index=$1
            ;;
        -m )
            shift
            chunk_max=$1
            ;;
        * )
            break
            ;;
        esac
        shift
    done

    local xtra_opts=$*

    if [ -z $chunk_index ] || [ -z $chunk_max ]; then
        echo "ERROR: Invalid chunk paramters"
        echo "$USAGE"
        exit 1
    fi

    if [ "$chunk_max" -le 0 ]; then
        echo "ERROR: Chunks count must be positive number"
        return 1
    fi

    if [ "$chunk_index" -gt "$chunk_max" ] &&  [ "$chunk_max" -ge 2 ]; then
        chunk_index=$chunk_max
    fi

    set +e
    count_sketches "$path" "$target"
    local sketchcount=$?
    set -e
    local sketches=$(cat sketches.txt)
    rm -rf sketches.txt

    local chunk_size=$(( $sketchcount / $chunk_max ))
    local all_chunks=$(( $chunk_max * $chunk_size ))
    if [ "$all_chunks" -lt "$sketchcount" ]; then
        chunk_size=$(( $chunk_size + 1 ))
    fi

    local start_index=0
    local end_index=0
    if [ "$chunk_index" -ge "$chunk_max" ]; then
        start_index=$chunk_index
        end_index=$sketchcount
    else
        start_index=$(( $chunk_index * $chunk_size ))
        if [ "$sketchcount" -le "$start_index" ]; then
            echo "Skipping job"
            return 0
        fi

        end_index=$(( $(( $chunk_index + 1 )) * $chunk_size ))
        if [ "$end_index" -gt "$sketchcount" ]; then
            end_index=$sketchcount
        fi
    fi

    local start_num=$(( $start_index + 1 ))
    echo "Found $sketchcount Sketches for target '$target'";
    echo "Chunk Index : $chunk_index"
    echo "Chunk Count : $chunk_max"
    echo "Chunk Size  : $chunk_size"
    echo "Start Sketch: $start_num"
    echo "End Sketch  : $end_index"

    local sketchnum=0
    args+=" -ai $ide_path -au $user_path"
    for sketch in $sketches; do
        local sketchdir=$(dirname $sketch)
        local sketchdirname=$(basename $sketchdir)
        sketchnum=$(($sketchnum + 1))
        if [ "$sketchnum" -le "$start_index" ] \
        || [ "$sketchnum" -gt "$end_index" ]; then
            continue
        fi
        echo ""
        echo "Building Sketch Index $(($sketchnum - 1)) - $sketchdirname"
        args+=" -s $sketchdir $xtra_opts"
        build_sketch $args
        local result=$?
        if [ $result -ne 0 ]; then
            return $result
        fi
    done
    return 0
}

USAGE="
USAGE: ${0} [command] [options]
Available commands:
  count: Count sketches.
  build: Build a sketch.
  chunk_build: Build a chunk of sketches.
"

cmd=$1
shift
if [ -z $cmd ]; then
    echo "ERROR: No command supplied"
    echo "$USAGE"
    exit 2
fi

case "$cmd" in
    "count") count_sketches $*
    ;;
    "build") build_sketch $*
    ;;
    "chunk_build") build_sketches $*
    ;;
    *)
        echo "ERROR: Unrecognized command"
        echo "$USAGE"
        exit 2
esac

