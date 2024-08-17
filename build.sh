#!/bin/bash

RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
CYAN='\033[0;36m'
WHITE='\033[0;37m'
NC='\033[0m'

ERROR=1
WARN=2
INFO=3
DEBUG=4
TRACE=5

LOG_LEVEL=$TRACE

log() {
    local level="$1"
    shift
    local message="$@"
    local timestamp=$(date "+%Y-%m-%d %H:%M:%S")

    if [[ $level -le $LOG_LEVEL ]]; then
        case $level in
            $ERROR) color=$RED; prefix="🛑 ERROR:" ;;
            $WARN)  color=$YELLOW; prefix="⚠️  WARN:" ;;
            $INFO)  color=$BLUE; prefix="ℹ️  INFO:" ;;
            $DEBUG) color=$MAGENTA; prefix="🔍 DEBUG:" ;;
            $TRACE) color=$CYAN; prefix="🔎 TRACE:" ;;
            *)      color=$NC; prefix="LOG:" ;;
        esac
        while IFS= read -r line; do
            echo -e "${color}${timestamp} ${prefix} ${line}${NC}"
        done <<< "$message"
    fi
}

function usage {
    log $INFO "Usage: $0 <dir> [<target>]"
    log $INFO "    <dir>      Directory containing the 'build' recipe (required)"
    log $INFO "    <target>   Target to build (optional)"
}

function load_build_script {
    local dir=$1
    local build_script="$dir/build"

    if [[ -f "$build_script" && -x "$build_script" ]]; then
        log $INFO "Loading build script from \"$build_script\""
        source "$build_script"
    else
        log $ERROR "'build' script not found or not executable in $dir."
        exit 1
    fi
}

function get_value {
    local var_name="$1"
    if [[ -z "${!var_name+x}" ]]; then
        echo "@null"
    else
        echo "${!var_name}"
    fi
}

function check_value {
    local var_name="$1"
    local result=$(get_value "$var_name")
    log $TRACE "Checking $var_name, result=${result[@]}"
    
    if [[ "$result" == "@null" ]]; then
        log $ERROR "Didn't find \"$var_name\""
        exit 1
    fi
}

function check_default_target {
    log $TRACE "Checking default target presence in targets array."
    
    if [[ ! ${#targets[@]} -gt 1 ]]; then
        IFS=',' read -r -a targets <<< "${targets[0]}"
    fi

    local found=0
    for target in "${targets[@]}"; do
        if [[ "$target" == "$default_target" ]]; then
            found=1
            break
        fi
    done

    if [[ $found -eq 0 ]]; then
        log $ERROR "Target \"$default_target\" not found."
        exit 1
    fi
}

function set_dir {
    log $TRACE "Changing directory to $1"
    pushd "$1" > /dev/null || { log $ERROR "Failed to change directory to $1"; exit 1; }
}

function revert_dir {
    log $TRACE "Reverting directory"
    popd > /dev/null || { log $ERROR "Failed to revert directory"; exit 1; }
}

function check_file {
    local file="$1"

    if ! [[ -f "$file" ]]; then
        log $ERROR "File '$file' does not exist or is not a regular file."
        exit 1
    fi
}

function check_function {
    local func_name="$1"

    if ! declare -f "$func_name" > /dev/null; then
        log $WARN "Warning: Function '$func_name' does not exist."
    fi
}

function spawn_command {
    local command="$1"
    shift
    local args=("$@")
    
    log $TRACE "Spawning command: $command ${args[@]}"
    "$command" "${args[@]}" &
    local pid=$!
    wait $pid
    
    if [[ $? -ne 0 ]]; then
        log $ERROR "Command \"$command ${args[@]}\" failed with exit code $?"
    else
        log $TRACE "Command \"$command ${args[@]}\" completed successfully."
    fi
}

function spawn_commands_parallel {
    local commands=("$@")
    
    local pids=()
    
    for cmd in "${commands[@]}"; do
        log $TRACE "Spawning command: $cmd"
        eval "$cmd" &
        pids+=($!)
    done
    
    for pid in "${pids[@]}"; do
        wait $pid
        if [[ $? -ne 0 ]]; then
            log $ERROR "Command with PID $pid failed."
        fi
    done
    
    log $TRACE "All parallel commands completed successfully."
}

function expand_wildcards {
    local pattern="$1"
    local result=()

    while IFS= read -r file; do
        result+=("$file")
    done < <(find . -type f -name "$(basename "$pattern")")

    echo "${result[@]}"
}

function build_c_simple {
    check_value src_files

    src_files_decoded=()

    for pattern in "${src_files[@]}"; do
        if [[ "$pattern" == **/* ]]; then
            files=($(expand_wildcards "$pattern"))
        else
            files=($(eval echo "$pattern"))
        fi

        if [[ ${#files[@]} -eq 0 ]]; then
            log $WARN "Warning: No files matched the pattern '$pattern'."
        else
            src_files_decoded+=("${files[@]}")
        fi
    done

    log $TRACE "Source files: ${src_files_decoded[@]}"

    cc=$(get_value compiler)
    [[ "$cc" == "@null" ]] && cc="cc"
    log $DEBUG "Using compiler: $cc"

    ld=$(get_value linker)
    [[ "$ld" == "@null" ]] && ld="$cc"  # Use compiler as linker if no linker is provided
    log $DEBUG "Using linker: $ld"

    ccflags=$(get_value cflags)
    ldflags=$(get_value lflags)

    obj_dir=$(get_value build_dir)
    [[ "$obj_dir" == "@null" ]] && obj_dir="build"
    mkdir -p "$obj_dir"
    log $DEBUG "Using build directory: $obj_dir"

    out_dir=$(get_value bin_dir)
    [[ "$out_dir" == "@null" ]] && out_dir="bin"
    mkdir -p "$out_dir"
    log $DEBUG "Using bin directory: $out_dir"

    object_files=()
    for src_file in "${src_files_decoded[@]}"; do
        base_name=$(basename "$src_file")
        obj_file="$obj_dir/${base_name%.*}.o"
        compile_command="$cc $ccflags -c $src_file -o $obj_file"
        log $TRACE "Compiling $src_file to $obj_file"
        spawn_command "$cc" $ccflags -c "$src_file" -o "$obj_file"
        if [[ $? -ne 0 ]]; then
            log $ERROR "Compilation of $src_file failed."
            exit 1
        fi
        object_files+=("$obj_file")
    done

    output_file="$out_dir/$(basename "${src_files_decoded[0]}" .c)"
    link_command="$ld $ldflags -o $output_file ${object_files[@]}"
    log $TRACE "Linking object files into $output_file"
    spawn_command "$ld" $ldflags -o "$output_file" "${object_files[@]}"
    if [[ $? -ne 0 ]]; then
        log $ERROR "Linking failed."
        exit 1
    fi

    log $INFO "Build successful. Executable is located at $output_file"
}

function build {
    log $TRACE "Checking for target file $default_target.target"
    check_file "$default_target.target"
    source "$default_target.target"
    
    local func_name="${default_target}_pre"
    log $TRACE "Checking if function $func_name exists."
    check_function "$func_name"
    if [[ $(declare -f "$func_name") ]]; then
        log $DEBUG "Executing function $func_name"
        $func_name
    else
        log $DEBUG "Function $func_name does not exist, skipping."
    fi

    handle_project_type $project_type

    case $project_type in
        C-Simple)
            log $DEBUG "Identified C-Simple project"
            build_c_simple
            ;;
        *)
            log $ERROR "Unhandled project type: $project_type"
            ;;
    esac
}

function pre_build {
    log $TRACE "Checking build values"
    check_value project_kind
    check_value targets
    check_value default_target

    check_default_target

    log $DEBUG "Project Kind: $project_kind"
    log $DEBUG "Targets: ${targets[@]}"
    log $DEBUG "Default Target: $default_target"
    
    set_dir "$dir"
    build
    revert_dir
}

function handle_project_type {
    local project_type=$1
    log $TRACE "Checking project type $project_type"
    case $project_type in
        C-Simple)
            log $DEBUG "Valid project type"
            ;;
        *)
            log $ERROR "Unknown project type: $project_type"
            exit 1
            ;;
    esac
}

if [[ $# -lt 1 ]]; then
    log $ERROR "Directory argument is required."
    usage
    exit 1
fi

dir=$1
target=${2:-}
project_type=''

if [[ -d "$dir" ]]; then
    log $INFO "Loading build script from directory $dir"
    load_build_script "$dir"
    if [[ -n "$target" ]]; then
        default_target=$target
        log $INFO "Using specified target: $default_target"
    fi
    
    project_type=${project_kind:-default}

    pre_build
    
else
    log $ERROR "$dir is not a valid directory."
    usage
    exit 1
fi
