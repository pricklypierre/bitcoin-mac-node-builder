#!/usr/bin/env zsh
#
# Amor et potentia oppressis.
#

########################################
typeset -g _SCRIPT_DIR="${0:A:h}"
if [[ -f "$_SCRIPT_DIR/pv_exec.zsh" ]]; then
    source "$_SCRIPT_DIR/pv_exec.zsh"
    pv_init
else
    echo "Error: pv_exec.zsh not found (should be in same directory as this script)"
    exit 1
fi

########################################
OSC0_FRMT='\033]0;%s\a'
BOLD='\033[1m'; UNBOLD='\033[22m'
RED='\033[91;1m'; GREEN='\033[32;1m'; BLUE='\033[94m'; YELLOW='\033[33;1m'
RESET='\033[0m'

if term_bg_isdark; then
    # Dark terminal background - use bright foreground colors
    PB_COLOR_FILL='\033[32m'        # Dark green for filled portion
    PB_COLOR_FILL2='\033[34m'       # Dark blue for filled portion
    PB_COLOR_EMPTY='\033[90m'       # Dark gray for empty portion
    PB_COLOR_BORDER='\033[37m'      # Light gray for borders/text
    PB_COLOR_TEXT='\033[97m'        # White for percentage text
    TABLE_BRDR_COLOR='\033[90m'     # Dark gray for table border
    TITLE_COLOR='\033[32m';         # Dark green for table title color
    TITLE_COLOR_ERR='\033[91m'      # Light red for table title error color
    LABEL_COLOR='\033[37m'          # Light gray for percentage text
    VALUE_COLOR='\033[97m'          # White for percentage text
else
    # Light terminal background - use dark foreground colors
    PB_COLOR_FILL='\033[34m'        # Dark blue for filled portion
    PB_COLOR_FILL2='\033[32m'       # Dark green for filled portion
    PB_COLOR_EMPTY='\033[37m'       # Light gray for empty portion
    PB_COLOR_BORDER='\033[90m'      # Dark gray for borders/text
    PB_COLOR_TEXT='\033[30m'        # Black for percentage text
    TABLE_BRDR_COLOR='\033[37m'     # Light gray for table border
    TITLE_COLOR='\033[34m'          # Dark blue for table title color
    TITLE_COLOR_ERR='\033[91m'      # Light red for table title error color
    LABEL_COLOR='\033[90m'          # Dark gray for percentage text
    VALUE_COLOR='\033[30m'          # Black for percentage text
fi

########################################
format_bytes() {
    local bytes=$1
    local out_result=$2   # after zsh 5.10+ use: local -n out_result=$2

    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || (( bytes < 0 )); then
        echo "0"
        return 0
    fi

    # Technically units should be TiB, GiB, MiB, KiB but no one cares.
    if (( bytes >= 1099511627776 )); then
        local -F 2 result_float=$((bytes / 1099511627776.0))
        # after zsh 5.10+ use: out_result="$result_float TB"
        : ${(P)out_result::="$result_float TB"}
    elif (( bytes >= 1073741824 )); then
        local -F 2 result_float=$((bytes / 1073741824.0))
        # after zsh 5.10+ use: out_result="$result_float GB"
        : ${(P)out_result::="$result_float GB"}
    elif (( bytes >= 1048576 )); then
        local -F 2 result_float=$((bytes / 1048576.0))
        # after zsh 5.10+ use: out_result="$result_float MB"
        : ${(P)out_result::="$result_float MB"}
    elif (( bytes >= 1024 )); then
        local -F 2 result_float=$((bytes / 1024.0))
        # after zsh 5.10+ use: out_result="$result_float KB"
        : ${(P)out_result::="$result_float KB"}
    else
        # after zsh 5.10+ use: out_result="bytes B"
        : ${(P)out_result::="${bytes} B"}
    fi
    return 0
}

# Marketing version of format_bytes used by deceptive SDD/HD storage industry.
format_bytes_marketing() {
    local bytes=$1
    local out_result=$2   # after zsh 5.10+ use: local -n out_result=$2

    if [[ ! "$bytes" =~ ^[0-9]+$ ]] || (( bytes < 0 )); then
        # after zsh 5.10+ use: out_result="0"
        : ${(P)out_result::="0"}
        return 0
    fi

    if (( bytes >= 1000000000000 )); then
        local -F 2 result_float=$((bytes / 1000000000000.0))
        # after zsh 5.10+ use: out_result="$result_float TB"
        : ${(P)out_result::="$result_float TB"}
    elif (( bytes >= 1000000000 )); then
        local -F 2 result_float=$((bytes / 1000000000.0))
        # after zsh 5.10+ use: out_result="$result_float GB"
        : ${(P)out_result::="$result_float GB"}
    elif (( bytes >= 1000000 )); then
        local -F 2 result_float=$((bytes / 1000000.0))
        # after zsh 5.10+ use: out_result="$result_float MB"
        : ${(P)out_result::="$result_float MB"}
    elif (( bytes >= 1000 )); then
        local -F 2 result_float=$((bytes / 1000.0))
        # after zsh 5.10+ use: out_result="$result_float KB"
        : ${(P)out_result::="$result_float KB"}
    else
        # after zsh 5.10+ use: out_result="bytes B"
        : ${(P)out_result::="${bytes} B"}
    fi
    return 0
}

########################################
text_center_pad() {
    local -i width=$1
    local handle_widechars=$2
    local text_str=$3
    local out_text=$4   # after zsh 5.10+ use: local -n out_text=$4

    # Strip colors to get just the visible text (otherwise padding calculation are off)
    local -i text_len=0;  stripped_len $handle_widechars "$text_str" text_len
    local -i chop=$((width - text_len))
    if (( chop < 0 )); then
        if (( width > 3 )); then
            text_str="${text_str:0:$((chop-3))}..."
        elif (( text_len > -chop )); then
            text_str="${text_str:0:$chop}"
        else
            text_str=""
        fi
        text_len=$width
    fi
    local -i pad_left=$(((width - text_len) / 2))
    local -i pad_right=$((width - text_len - pad_left))
    ((pad_left < 0)) && pad_left=0
    ((pad_right < 0)) && pad_right=0
    print -v text_str -f '%*s%s%*s' "$pad_left" "" "$text_str" "$pad_right" ""

    # after zsh 5.10+ use: out_text="$text_str"
    : ${(P)out_text::="$text_str"}
    return 0
}

text_bold() {
    local in_text=$1
    local out_text=$2       # after zsh 5.10+ use: local -n out_text=$2
    local bold_text=""
    print -v bold_text -f "${BOLD}%s${UNBOLD}" "$in_text"
    # after zsh 5.10+ use: out_text="$bold_text"
    : ${(P)out_text::="$bold_text"}
    return 0
}

########################################
print_info() {
    printf "${MSG_INFO_TEXT_COLOR}%s${RESET}\n" "$1"
}

print_info_bold() {
    printf "${MSG_INFO_TEXT_COLOR}${BOLD}%s${RESET}\n" "$1"
}

print_warning() {
    printf "${MSG_WARNING_TEXT_COLOR}${BOLD}%s${RESET}\n" "$1"
}

print_success() {
    printf "${MSG_SUCCESS_TEXT_COLOR}${BOLD}%s${RESET}\n" "$1"
    pv_sleep 0.25
}

print_error() {
    printf "${MSG_FAILURE_TEXT_COLOR}${BOLD}%s${RESET}\n" "$1"
}

########################################
benchmark() {
    local cmd=$1
    local -i iterations=${2:-10}
    local -i total=0

    echo "Benchmark for: $cmd"
    for ((i=1; i<=iterations; i++)); do
        local start=$(date +%s.%N)  # ToDo: change this to use $EPOCHREALTIME
        eval "$cmd"
        local end=$(date +%s.%N)
        local time=$(echo "$end - $start" | bc)
        total=$(echo "$total + $time" | bc)
        # echo "Run $i: ${time}s"
    done
    echo "Average: $(echo "scale=3; $total/$iterations" | bc)s"
    echo
}

get_cpu_core_count() {
    local out_count=$1   # after zsh 5.10+ use: local -n out_count=$1
    local -i count=$(sysctl -n hw.ncpu)
    # after zsh 5.10+ use: out_count="$count"
    : ${(P)out_count::="$count"}
    return 0
}

process_cpu_load() {
    local pid=$1
    local out_cpuload=$2   # after zsh 5.10+ use: local -n out_cpuload=$2
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        # If $pid is zero or the process is dead just return 0.0.
        # after zsh 5.10+ use: out_cpuload="0.0"
        : ${(P)out_cpuload::="0.0"}
        return 0
    fi

    local -F 1 cpu=$(ps -p "$pid" -o %cpu=)
    # after zsh 5.10+ use: out_cpuload="$cpu"
    : ${(P)out_cpuload::="$cpu"}
    return 0
}

# The "physical footprint" memory is the most accurate on macOS since it takes into
# account compressed and shared memory. There isn't yet a 'ps -o footprint=' style
# selector to retrieve it, but Xcode CLT includes a 'footprint' tool that calculates
# it quickly. If that isn't present, we can fallback to using 'top', but it is slow.
process_footprint_memory() {
    local pid=$1
    local out_ftprnt_mem=$2   # after zsh 5.10+ use: local -n out_ftprnt_mem=$2
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        # If $pid is zero or the process is dead just return 0B.
        # after zsh 5.10+ use: out_ftprnt_mem="0 B"
        : ${(P)out_ftprnt_mem::="0 B"}
        return 0
    fi

    if program_exists "footprint"; then
        local footprint_str=$(footprint -p "$pid" -f bytes)
        local mem_bytes=${footprint_str##*Footprint: }  # Remove everything before "Footprint: "
        mem_bytes=${mem_bytes%% B*}                     # and everything after " B"
        local mem_str=""
        format_bytes "$mem_bytes" mem_str
        # after zsh 5.10+ use: out_ftprnt_mem="${mem_str}"
        : ${(P)out_ftprnt_mem::="${mem_str}"}
        return 0
    else
        # This is too slow to use (about 0.5s on a fast Mac), so just return unavail.
        # after zsh 5.10+ use: out_ftprnt_mem="- unavailable -"
        : ${(P)out_ftprnt_mem::="- unavailable -"}
        return 0
        # If we enable this then we'll want to significantly decrease the frequency called.
        # User should install Xcode CLT so the footprint command technique (above) will work.
        # Top can return it (MEM column) but it always samples for at least half a second.
        local mem_str=$(top -l 1 -pid "$pid" -stats mem | tail -n 1 | awk '{ print $1 }')
        # Extract number and suffix
        local number=${mem_str%[KMGTP]*}
        local suffix=${mem_str##*[0-9]}
        # Convert to bytes based on suffix
        local mem_bytes
        case $suffix in
        K) mem_bytes=$(( number * 1024 )) ;;
        M) mem_bytes=$(( number * 1024 * 1024 )) ;;
        G) mem_bytes=$(( number * 1024 * 1024 * 1024 )) ;;
        T) mem_bytes=$(( number * 1024 * 1024 * 1024 * 1024 )) ;;
        P) mem_bytes=$(( number * 1024 * 1024 * 1024 * 1024 * 1024 )) ;;
        *) mem_bytes=$number ;;
        esac
        local mem_str=""
        format_bytes "$mem_bytes" mem_str
        # after zsh 5.10+ use: out_ftprnt_mem="${mem_str}"
        : ${(P)out_ftprnt_mem::="${mem_str}"}
        return 0
    fi
}

# Old school resident set size (RSS) or real memory size. Not as useful or accurate
# on macOS.
process_rss_memory() {
    local pid=$1
    local out_rss_mem=$2   # after zsh 5.10+ use: local -n out_rss_mem=$2
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        # If $pid is zero or the process is dead just return 0B.
        # after zsh 5.10+ use: out_rss_mem="0 B"
        : ${(P)out_rss_mem::="0 B"}
        return 0
    fi

    local mem_kb=$(ps -p "$pid" -o rss=)
    mem_kb=${mem_kb// /}  # Strip all spaces
    local mem_str=""
    format_bytes "$((mem_kb * 1024))" mem_str
    if ((1)); then # ((1)) conditional is just to avoid a linter parse bug
        # after zsh 5.10+ use: out_rss_mem="${mem_str}"
        : ${(P)out_rss_mem::="${mem_str}"}
    fi
    return 0
}

process_uptime() {
    local pid=$1
    local out_uptime=$2   # after zsh 5.10+ use: local -n out_uptime=$2
    if [[ -z "$pid" ]] || ! kill -0 "$pid" 2>/dev/null; then
        # If $pid is zero or the process is dead just return 0m 0s.
        # after zsh 5.10+ use: out_uptime='0m 0s'
        : ${(P)out_uptime::='0m 0s'}
        return 0
    fi

    # etime format will be (days and hours can be optional):
    #   [[dd-]hh:]mm:ss
    local etime=$(ps -p "$pid" -o etime=)
    if [[ "$etime" =~ ([0-9]+)-([0-9]+):([0-9]+):([0-9]+) ]]; then
        # Format: dd-hh:mm:ss
        local -i days=$((10#${match[1]}))    # Force base 10 and strip leading zeros
        local -i hours=$((10#${match[2]}))
        local -i minutes=$((10#${match[3]}))
        local -i seconds=$((10#${match[4]}))
        # after zsh 5.10+ use: out_uptime="${days}d ${hours}h ${minutes}m ${seconds}s"
        : ${(P)out_uptime::="${days}d ${hours}h ${minutes}m ${seconds}s"}
        return 0
    elif [[ "$etime" =~ ([0-9]+):([0-9]+):([0-9]+) ]]; then
        # Format: hh:mm:ss
        local -i hours=$((10#${match[1]}))
        local -i minutes=$((10#${match[2]}))
        local -i seconds=$((10#${match[3]}))
        # after zsh 5.10+ use: out_uptime="${hours}h ${minutes}m ${seconds}s"
        : ${(P)out_uptime::="${hours}h ${minutes}m ${seconds}s"}
        return 0
    elif [[ "$etime" =~ ([0-9]+):([0-9]+) ]]; then
        # Format: mm:ss
        local -i minutes=$((10#${match[1]}))
        local -i seconds=$((10#${match[2]}))
        # after zsh 5.10+ use: out_uptime="${minutes}m ${seconds}s"
        : ${(P)out_uptime::="${minutes}m ${seconds}s"}
        return 0
    fi
    # (shouldn't happen, but just return raw etime if it does)
    if ((1)); then # ((1)) conditional is just to avoid a linter parse bug
        # after zsh 5.10+ use: out_uptime="${etime}"
        : ${(P)out_uptime::="${etime}"}
    fi
    return 0
}