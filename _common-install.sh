#!/bin/zsh
#
# Amor et tolerantia erga omnes oppressos.
#

########################################
NODE_BUILDER_VERSION="1.0.0"
CONFIG_FILENAME="global_config.yaml"

NODE_BUILDER_APP_SUPPORT_PATH="$HOME/Library/Application Support/Bitcoin Mac Node Builder"
# Directory for launchd helper scripts (must reside on internal drive, not external volume).
LAUNCHD_HELPER_DIR="$NODE_BUILDER_APP_SUPPORT_PATH/launchd"
BUILD_LOGS_DIR="$NODE_BUILDER_APP_SUPPORT_PATH/build-logs"

########################################
OSC0_FRMT='\033]0;%s\a'
BOLD='\033[1m'; UNBOLD='\033[22m'
RED='\033[91;1m'; GREEN='\033[32;1m'; BLUE='\033[94m'; YELLOW='\033[33;1m'
RESET='\033[0m'

########################################
# Avoid using tput since each call spawns a process. Echoti (or sending raw escape codes)
# is orders of magnitude faster.
zmodload zsh/terminfo   # for echoti() func

my_get_term_width()  {
    local out_cols=$1   # after zsh 5.10+ use: local -n out_cols=$1
    if [[ -n "${COLUMNS:-}" ]]; then
        # after zsh 5.10+ use: out_cols="$COLUMNS"
        : ${(P)out_cols::="$COLUMNS"}
    else
        __cols=$(echoti cols 2>/dev/null) || __cols=80
        # after zsh 5.10+ use: out_cols="$__cols"
        : ${(P)out_cols::="$__cols"}
    fi
    return 0
}
my_get_term_height() {
    local out_lines=$1   # after zsh 5.10+ use: local -n out_lines=$1
    if [[ -n "${LINES:-}" ]]; then
        # after zsh 5.10+ use: out_lines="$LINES"
        : ${(P)out_lines::="$LINES"}
    else
        __lines=$(echoti lines 2>/dev/null) || __lines=50
        # after zsh 5.10+ use: out_lines="$__lines"
        : ${(P)out_lines::="$__lines"}
    fi
    return 0
}

my_start_buffered_update() { print -nr -- $'\033[?2026h'; }  # start buffered update mode
my_end_buffered_update()   { print -nr -- $'\033[?2026l'; }  # end buffered updated mode (flushes output)

my_tput_clear() { echoti clear; }       # clear screen
my_tput_smcup() { echoti smcup; }       # start alternate screen (screen+cursor saved, clear, no scroll back)
my_tput_rmcup() { echoti rmcup; }       # exit alternate screen (screen+cursor restored)

my_tput_rmam()  { echoti rmam; }        # disable auto-wrapping of lines (no automatic margins)
my_tput_smam()  { echoti smam; }        # enable auto-wrapping of lines (automatic margins)

my_tput_civis() { echoti civis; }       # hide cursor
my_tput_cnorm() { echoti cnorm; }       # show cursor

my_tput_cuf()   { echoti cuf $1; }      # cursor forward (relative: move-right)
my_tput_cup()   { echoti cup $1 $2; }   # cursor position (absolute: y, x)
my_tput_sc()    { echoti sc; }          # cursor save
my_tput_rc()    { echoti rc; }          # cursor restore

my_tput_el()    { echoti el; }          # erase from cursor to end-of-line

my_tput_csr()   { echoti csr $1 $2; }   # set vertical scroll region (top, bottom)
my_tput_rcsr()  {
    # reset vertical scroll region to entire term
    local -i height=0
    my_get_term_height height
    echoti csr 0 $((height - 1));
}

my_get_cursor_row() {
    emulate -L zsh
    local out_row=$1   # after zsh 5.10+ use: local -n out_row=$1

    local fd  # open controlling terminal for r+w
    exec {fd}<>/dev/tty || return 1

    # Save TTY and switch to no echo and no waiting
    local old=$(stty -g <&$fd)
    stty -echo -icanon min 1 time 1 <&$fd

    # Request report cursor position (CPR), preferring echoti over escape code.
    if ! echoti u7 >&$fd 2>/dev/null; then
        printf '\033[6n' >&$fd
    fi

    # Read reply: ESC [ row ; col R (1-based)
    local resp
    IFS= read -r -d R -u $fd resp
    local read_ok=$?

    # Immediately restore TTY
    stty "$old" <&$fd
    exec {fd}>&-

    # And then parse the result
    if ((read_ok == 0)); then
        resp=${resp#*$'\033['}        # Strip leading ESC[
        local row=${resp%%;*}
        if [[ $row == <-> ]]; then
            ((row--)) # 0-based to match 'tput cup'
            # after zsh 5.10+ use: out_row="${row}"
            : ${(P)out_row::="${row}"}
            return 0
        fi
    fi
    return 1
}

########################################
# Similar to sleep(), but doesn't start a new process.
my_sleep() {
    local duration=$1
    local -i zsel_duration=$((100 * duration))
    zselect -t $zsel_duration
    return 0
}

########################################
program_exists() {
    command -v "$1" &>/dev/null
    return $?
}

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
# Remove escape sequences (used to set color, style, cursor pos, etc.) using zsh parameter expansion.
strip_control_chars() {
    setopt localoptions extendedglob
    local input=$1
    local output=$2 # after zsh 5.10+ use: local -n output=$2

    local cleaned=${input//*$'\x0D'/}                  # Remove everything up to and including CR

    cleaned=${cleaned//$'\033['[0-9;]#[a-zA-Z]/}       # Most CSI sequences
    cleaned=${cleaned//$'\033'[a-zA-Z]/}               # Simple ESC sequences
    cleaned=${cleaned//$'\033'[0-9]/}                  # ESC + single digit
    cleaned=${cleaned//$'\033Y'??/}                    # VT52 cursor positioning

    cleaned=${cleaned//$'\x9B'[0-9;]#[a-zA-Z]/}        # 8-bit CSI sequences
    cleaned=${cleaned//[$'\x80'-$'\x8F'$'\x91'-$'\x98'$'\x9A'$'\x9E'-$'\x9F']/} # Single-byte C1
    cleaned=${cleaned//$'\007'/}                       # Bell character (BEL)

    # Note using parameter expansion (above) is orders of magnitude faster than using sed
    # or anything that spawns a new process.

    # after zsh 5.10+ use: output="$cleaned"
    : ${(P)output::="$cleaned"}
    return 0
}

stripped_len() {
    local handle_widechars=$1
    local stripped=""
    strip_control_chars "$2" stripped
    local outlen=$3     # after zsh 5.10+ use: local -n outlen=$3
    local -i width=0
    if [[ $handle_widechars == "true" ]]; then
        # Optimization: only try to handle widechars if caller requests it.
        local -i i=1
        local -i len=${#stripped}
        while (( i <= len )); do
            # Basic heuristic for common wide characters
            local char="${stripped[i]}"
            local codepoint=$((#char))
            if (( codepoint >= 0x1F000 && codepoint <= 0x1F9FF )); then
                ((width += 2))  # Emojis
            elif (( codepoint >= 0x2600 && codepoint <= 0x27BF )); then
                ((width += 2))  # Miscellaneous Symbols and Dingbats (includes ✅ at U+2705)
            elif (( codepoint >= 0x4E00 && codepoint <= 0x9FFF )); then
                ((width += 2))  # CJK Unified Ideographs
            elif (( codepoint >= 0x3000 && codepoint <= 0x303F )); then
                ((width += 2))  # CJK Symbols and Punctuation
            elif (( codepoint >= 0xAC00 && codepoint <= 0xD7AF )); then
                ((width += 2))  # Hangul Syllables
            elif (( codepoint >= 0xFF01 && codepoint <= 0xFF60 )); then
                ((width += 2))  # Fullwidth Forms
            else
                ((width += 1))  # Normal width
            fi
            ((i++))
        done
    else
        width=${#stripped}
    fi
    # after zsh 5.10+ use: outlen="$width"
    : ${(P)outlen::="$width"}
    return 0
}

text_trunc() {
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
    fi
    # after zsh 5.10+ use: out_text="$text_str"
    : ${(P)out_text::="$text_str"}
    return 0
}

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
# This encodes a file name or file path it into an absoluste file:// URL.
url_encode_file() {
    setopt localoptions extendedglob
    local filepath="${1:A}"     # :A normalizes filename/path to an absolute path
    local out_url=$2            # after zsh 5.10+ use: local -n out_url=$2
    local encoded_url="file://"

    local -i pos filepath_len=${#filepath}
    for (( pos=1; pos<=filepath_len; pos++ )); do
        local ch=${filepath[pos]}
        if [[ "$ch" == [a-zA-Z0-9._~/-] ]]; then
            encoded_url+="$ch"
        else
            local hex=""
            print -v hex -f "%02X" "'$ch"
            encoded_url+="%$hex"
        fi
    done
    # after zsh 5.10+ use: out_url="encoded_url"
    : ${(P)out_url::="$encoded_url"}
    return 0
}

# This extracts a UI label to show for the URL, which is the filename
# with spaces (%20) decoded. If the URL isn't pointing to a filename
# then the entire encoded URL is just returned.
url_extract_ui_label() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_label=$2       # after zsh 5.10+ use: local -n out_label=$2

    # Strip trailing slashes
    in_url="${in_url%/}"

    # Extract everything after the last slash
    local filename="${in_url##*/}"

    # If filename part exists (not empty or just query params)
    if [[ -n "$filename" && "$filename" != \?* ]]; then
        filename="${filename%%\?*}"  # Strip ?query
        filename="${filename%%\#*}"  # Strip #fragment

        # Test for filename extensions.
        if [[ "$filename" == *.* && "$filename" != .* ]]; then
            # Test against common extensions
            local extension="${filename##*.}"
            if [[ "${extension:l}" == (txt|out|html|htm|pdf|doc|docx|zip|tar|gz|json|xml|csv|md|js|css|py|sh|zsh|conf|toml|yaml|yml|log) ]]; then
                filename=${filename//\%20/ }  # for display labels convert encoded spaces back to space chars.
                # after zsh 5.10+ use: out_label="filename"
                : ${(P)out_label::="$filename"}
                return 0
            fi
            # # Or just assume if extension < 6 characters it is likely a file?
            # if (( ${#extension} <= 5 )); then
            #     filename=${filename//%20/ }  # for display labels convert encoded spaces back to space chars.
            #     # after zsh 5.10+ use: out_label="filename"
            #     : ${(P)out_label::="$filename"}
            #     return 0
            # fi
        fi
    fi

    # Default to returning the full URL if we aren't confident we can extract a filename.
    # after zsh 5.10+ use: out_label="in_url"
    : ${(P)out_label::="$in_url"}
    return 0
}

# This escape encodes the URL arg (file://, http://, etc.) into a sequence that most
# terminal apps (not macOS Terminal, unfortunately) recognize and allow for hot clicking
# (normally via CMD+click).
url_term_render() {
    setopt localoptions extendedglob
    local in_url=$1
    local out_text=$2       # after zsh 5.10+ use: local -n out_text=$2
    local url_text=""

    local label=""
    url_extract_ui_label "$in_url" label

    local url_glyph="🔗"
    if [[ "$in_url" == file://* ]]; then
        local url_glyph="🧾"
    fi

    # Try escaped hyperlink encoding in supported terminals. Could probably remove this conditional
    # and just always do the encoding.
    local -i render_blue=0
    if [[ -n "${TERM_PROGRAM:-}" && "${TERM_PROGRAM:l}" == (iterm.app|apple_terminal) ]]; then
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s \033]8;;%s\007%s\033]8;;\007${RESET}" "$url_glyph" "$in_url" "$label"
        else
            print -v url_text -f "%s \033]8;;%s\007%s\033]8;;\007" "$url_glyph" "$in_url" "$label"
        fi
    else
        if ((render_blue)); then
            print -v url_text -f "${MSG_INFO_TEXT_COLOR}%s %s${RESET}" "$url_glyph" "$label"
        else
            print -v url_text -f "%s %s" "$url_glyph" "$label"
        fi
    fi
    # after zsh 5.10+ use: out_text="$url_text"
    : ${(P)out_text::="$url_text"}
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
    my_sleep 0.25
}

print_error() {
    printf "${MSG_FAILURE_TEXT_COLOR}${BOLD}%s${RESET}\n" "$1"
}

typeset -i _TERM_BG_IS_DARK_CACHE=-1
term_bg_isdark() {
    if ((_TERM_BG_IS_DARK_CACHE != -1)); then
        return $_TERM_BG_IS_DARK_CACHE
    fi

    local -i is_dark=1   # Default to dark (1) if all queries below fail.
    if [[ -n "$COLORFGBG" ]]; then
        local bg_color_index="${COLORFGBG##*;}"
        if (( bg_color_index < 8 )); then
            is_dark=1   # Dark background
        else
            is_dark=0   # Light background
        fi
    else
        # $COLORFGBG not defined (caller probably using SSH), so query terminal directly.
        if program_exists "stty"; then
            local saved_settings=$(stty -g 2>/dev/null)
            if [[ -n "$saved_settings" ]]; then
                {
                    stty raw -echo min 0 time 3 2>/dev/null
                    printf '\033]11;?\a' > /dev/tty  # Make sure query goes to terminal
                    local response=""
                    local char
                    while read -t 2 -k 1 char 2>/dev/null; do
                        response+="$char"
                        [[ "$char" == $'\a' || "$response" == *$'\033\\' ]] && break
                    done
                    stty "$saved_settings" 2>/dev/null

                    if [[ "$response" =~ rgb:([0-9a-fA-F]+)/([0-9a-fA-F]+)/([0-9a-fA-F]+) ]]; then
                        local r=$((16#${match[1]:0:2}))  # zsh arithmetic with hex
                        local g=$((16#${match[2]:0:2}))
                        local b=$((16#${match[3]:0:2}))
                        local luminance=$(((r * 299 + g * 587 + b * 114) / 1000))
                        # echo "DEBUG: RGB L=$r $g $b   $luminance" > /dev/tty; sleep 5
                        if (( luminance < 128 )); then
                            is_dark=1
                        else
                            is_dark=0
                        fi
                    fi
                } 2>/dev/null
            fi
        fi
    fi
    _TERM_BG_IS_DARK_CACHE="$is_dark"
    if ((_TERM_BG_IS_DARK_CACHE)); then
        return 0
    fi
    return 1
}

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
    STATUS_COLOR='\033[32m'         # Dark green for success status
    STATUS_COLOR_ERR='\033[91m'     # Light red for failure status
    LOG_TEXT_COLOR='\033[37m'       # Light gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[96m'    # Bright cyan for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[96m'      # Bright cyan for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[92m'   # Bright green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[93m'   # Bright yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[91m'   # Bright red for failure text messages
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
    LOG_TEXT_COLOR='\033[90m'       # Dark gray for text in scroll views
    STATUS_COLOR='\033[32m'         # Dark green for success status
    STATUS_COLOR_ERR='\033[91m'     # Light red for failure status
    LOG_TEXT_COLOR='\033[90m'       # Dark gray for text in scroll views
    PROCESSING_TEXT_COLOR='\033[34m'    # Dark blue for scroll view processing text and border frame
    MSG_INFO_TEXT_COLOR='\033[34m'      # Dark blue for info text messages
    MSG_SUCCESS_TEXT_COLOR='\033[32m'   # Dark green for success text messages
    MSG_WARNING_TEXT_COLOR='\033[33m'   # Dark yellow for warning text messages
    MSG_FAILURE_TEXT_COLOR='\033[31m'   # Dark red for failure text messages
fi

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

########################################
create_target_dirs() {
    if [[ ! -d "$1" ]]; then
        echo
        print_info "Creating target directory: $1"
        mkdir -p "$1" || return $?
    fi
    if [[ ! -d "$2" ]]; then
        mkdir -p "$2" || return $?
    fi
    if [[ ! -d "$3" ]]; then
        mkdir -p "$3" || return $?
    fi
    return 0
}

delete_file_if_exists() {
    if [[ -f "$1" || -L "$1" ]]; then
        rm -f "$1" || return $?
        print_success "Removed: $1"
    fi
    return 0
}

delete_dir_if_empty() {
    if [[ -d "$1" ]]; then
        if [ -z "$(ls "$1" | grep -v '^\.')" ]; then
            rm -rf "$1" || return $?
            print_success "Removed: $1"
        fi
    fi
    return 0
}

########################################
my_brew_prep() {
    emulate -L zsh
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    exec_with_popview \
        "Updating brew and all formulae..." \
        "" \
        brew update \
    || return $?
    return 0
}

my_brew_cleanup() {
    emulate -L zsh
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    exec_with_popview \
        "Cleaning up brew..." \
        "" \
        brew cleanup \
    || return $?
    return 0
}

_my_brew_install() {
    emulate -L zsh
    local outfile=$1; shift 1
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    local -a outdated=($(brew outdated --quiet))
    local formula
    for formula in "$@"; do
        [[ -z "$formula" ]] && continue

        if ! brew list --versions "$formula" &>/dev/null; then
            exec_with_popview \
                "Installing $formula via brew..." \
                "$outfile" \
                brew install --formula "$formula" \
            || return $?
        elif [[ " ${outdated[@]} " == *" $formula "* ]]; then
            exec_with_popview \
                "Upgrading $formula via brew..." \
                "$outfile" \
                brew upgrade --formula "$formula" \
            || return $?
        else
            print_info "✓ Found $formula"
        fi
    done
    return 0
}

my_brew_install() {
    _my_brew_install "" "$@"
    return $?
}

my_brew_install_withlog() {
    local outfile=$1; shift 1
    _my_brew_install "$outfile" "$@"
    return $?
}

_my_brew_uninstall() {
    emulate -L zsh
    local outfile=$1; shift 1
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    local formula
    for formula in "$@"; do
        [[ -z "$formula" ]] && continue

        if brew list --versions "$formula" &>/dev/null; then
            exec_with_popview \
                "Uninstalling $formula via brew..." \
                "$outfile" \
                brew uninstall --formula "$formula" \
            || return $?
        fi
    done
    return 0
}

my_brew_uninstall() {
    _my_brew_uninstall "" "$@"
    return $?
}

my_brew_uninstall_withlog() {
    local outfile=$1; shift 1
    _my_brew_uninstall "$outfile" "$@"
    return $?
}

my_brew_services_start() {
    emulate -L zsh
    local service=$1
    exec_with_popview \
        "Starting $service service..." \
        "" \
        brew services start "$service" \
    || return $?
    return 0
}

my_brew_services_restart() {
    emulate -L zsh
    local service=$1
    exec_with_popview \
        "Restarting $service service..." \
        "" \
        brew services restart "$service" \
    || return $?
    return 0
}

my_brew_services_stop() {
    emulate -L zsh
    local service=$1
    exec_with_popview \
        "Stopping $service service..." \
        "" \
        brew services stop "$service" \
    || return $?
    return 0
}

########################################
zmodload zsh/datetime   # for $EPOCHREALTIME var
zmodload zsh/zselect

typeset -i SV_ENABLE=1                    # 0 to disable dynamic scrolling popview on task execution
typeset -i SV_WRAP_LINES=1                # 0 to truncate lines
typeset -i SV_BORDER_SHOW=1
typeset -i SV_BORDER_ANIMATE_CLOSE=1
typeset -i SV_MAX_HEIGHT=13
typeset -i SV_BORDER_MARGIN_LEFT=2        # 2 character margin on left border
typeset -i SV_BORDER_MARGIN_RIGHT=2       # 2 character margin on right border
typeset -i SV_LOG_TO_PADDING=50           # 60 character padding before rendering label "logged to: "

typeset -i SV_DEBUG_SKIP_CLOSE=0          # if enabled scroll view is not closed (even if successful)
typeset -F SV_CLOSE_DELAY=1.75            # small delay before erasing and closing views.
typeset -F SV_CLOSE_ANIMATE_DELAY=0.035   # delay between animation updates of view closing

typeset -i SV_MIN_WIN_WIDTH=$((SV_BORDER_MARGIN_LEFT + SV_BORDER_MARGIN_RIGHT + 12))
typeset -i SV_MIN_WIN_HEIGHT=$((SV_MAX_HEIGHT + 8))
typeset -i SV_WIN_TOO_SMALL=0

SV_PID=""; SV_FD=""; SV_OUTBUF="";
SV_TOP_BORDER_STR=""; SV_BOT_BORDER_STR=""
typeset -i SV_WIN_ORIG_WIDTH=0      SV_WIN_ORIG_HEIGHT=0
typeset -i SV_TOP_ANCHOR=0
typeset -i SV_TOP_SCROLLREGION=0    SV_BOT_SCROLLREGION=0
typeset -i SV_CUR_HEIGHT=0
typeset -i SV_INSIDE_TPUTCSR=0

typeset -F SV_SPINNER_UPDATE_INTERVAL=0.15
typeset -F SV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
typeset -a SV_SPINNER_CHARS=( "⠋" "⠙" "⠹" "⠸" "⠼" "⠴" "⠦" "⠧" "⠇" "⠏" )
             # alternative: ( "⠁" "⠈" "⠐" "⠠" "⢀" "⡀" "⠄" "⠂" )
typeset -i SV_SPINNER_LEN=${#SV_SPINNER_CHARS[@]}
typeset -i SV_SPINNER_IDX=1

_yield_to_parser() {
    # Before calling my_get_term_width/height, we must force zsh to hit its parser
    # boundary processing which will update $COLUMNS and $LINES (which our my_get_term_*
    # funcs use). If we don't do this then we never detect window resizing. I tried
    # using local trap on WINCH and the global TRAPWINCH() function, but those will not
    # work either without the parser boundary processing. The local trap on WINCH is only
    # processed when parser boundary is hit. The global TRAPWINCH() function is called
    # immediately (via signal) BUT any variables it updates (like RESIZE_NEEDED=1) will
    # not be reflected in our loop here until the parser boundary. The only solution
    # would be to write to a temp FD inside TRAPWINCH() that we then add to our zselect,
    # but even with that we would then (here) still need to force the parser boundary
    # (using /usr/bin/true, sleep 0.01, etc.) to have $COLUMNS and $LINES updates, so
    # the only gain is that we would process the resize more quickly. Given our zselect
    # delay here is very short (SV_SPINNER_UPDATE_INTERVAL), we will handle the resize
    # quickly enough without all that extra overhead/code.
    /usr/bin/true
    # Here are a couple of alternative techniques for forcing parser boundary that
    # are slower. I tried to find a way to trip it without having to call/spawn a
    # new process but couldn't find any that worked.
    #   : | :
    #   sleep 0.001
    return 0
}

_render_label_processing() {
    local label=$1
    my_tput_rmam  # disable auto-wrapping of lines
    printf "  ${PROCESSING_TEXT_COLOR}%s${RESET}" "$label"
    my_tput_el
    my_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_done() {
    local label=$1
    local label_color=$2
    local outfile=$3

    my_tput_rmam  # disable auto-wrapping of lines
    local outfile_term_rendered=""
    if [[ -n "$outfile" ]]; then
        local outfile_url=""
        url_encode_file "$outfile" outfile_url
        url_term_render "$outfile_url" outfile_term_rendered

        local -i label_width=${#label}
        local -i log_to_padding=$((SV_LOG_TO_PADDING - label_width))
        ((log_to_padding < 1)) && log_to_padding=1
        printf "${label_color}%s${RESET}%*s logged to: %s" "$label" "$log_to_padding" "" "$outfile_term_rendered"
    else
        printf "${label_color}%s${RESET}" "$label"
    fi
    my_tput_el
    my_tput_smam  # re-enable auto-wrapping of lines
    print
    return 0
}

_render_label_success() {
    local label=$1
    local outfile=$2

    print -v label -f "✓ %s success" "$label"
    _render_label_done "$label" "$PROCESSING_TEXT_COLOR" "$outfile"
    return 0
}

_render_label_failure() {
    local label=$1
    local outfile=$2
    local rc=$3

    print -v label -f "✗ %s failed with rc %d" "$label" "$rc"
    _render_label_done "$label" "$MSG_FAILURE_TEXT_COLOR" "$outfile"
    return 0
}

_append_log_timestamp() {
    local outfile="$1"
    local msg="${@:2}"  # Capture args 2+ directly

    if [[ -z "$outfile" ]]; then
        return 0
    fi
    local parent_dir="$(dirname "$outfile")"
    if [[ ! -d "$parent_dir" ]]; then
        mkdir -p "$parent_dir" 2>/dev/null
    fi

    if [[ -f "$outfile" && -s "$outfile" ]]; then
        local border_str=${(l:86::━:):""}
        printf "\n\n%s\n" "$border_str" >> "$outfile"
    fi
    print "[$(date '+%Y-%m-%d %H:%M:%S')] $msg" >> "$outfile"
    return 0
}

_start_popview() {
    local label=$1
    my_get_term_width SV_WIN_ORIG_WIDTH; my_get_term_height SV_WIN_ORIG_HEIGHT

    print                               # Placeholder for label (will be filled in below)
    local -i placeholder_lines_needed="$SV_MAX_HEIGHT"
    if ((SV_BORDER_SHOW)); then
        local padleft_str=${(l:$SV_BORDER_MARGIN_LEFT:: :):""}
        local border_str=${(l:$((SV_WIN_ORIG_WIDTH - SV_BORDER_MARGIN_LEFT - SV_BORDER_MARGIN_RIGHT - 2))::─:):""}
        print -v SV_TOP_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╭%s╮${RESET}" "$padleft_str" "$border_str"
        print -v SV_BOT_BORDER_STR -f "%s${PROCESSING_TEXT_COLOR}╰%s╯${RESET}" "$padleft_str" "$border_str"
        print                           # Placeholder for top border
        ((placeholder_lines_needed++))  # Additional placeholder line needed for bottom border
    fi
    local -i count
    for (( count = 1; count < placeholder_lines_needed; count++ )); do
        print                           # Placeholders for scroll view output region
    done

    # Render the task label above the scroll view.
    my_get_cursor_row SV_TOP_ANCHOR
    SV_TOP_ANCHOR=$((SV_TOP_ANCHOR - SV_MAX_HEIGHT))
    ((SV_BORDER_SHOW)) && ((SV_TOP_ANCHOR-=2))
    ((SV_TOP_ANCHOR < 0)) && SV_TOP_ANCHOR=0
    my_tput_cup $SV_TOP_ANCHOR 0
    _render_label_processing "$label"

    # Define scroll region to SV_MAX_HEIGHT rows (enabled later when first output line arrives).
    SV_TOP_SCROLLREGION=$((SV_TOP_ANCHOR + 1))
    ((SV_BORDER_SHOW)) && ((SV_TOP_SCROLLREGION++))
    SV_BOT_SCROLLREGION=$((SV_TOP_SCROLLREGION + SV_MAX_HEIGHT - 1))
    my_tput_cup "$SV_TOP_SCROLLREGION" 0   # move cursor to top-left of scroll region
    SV_CUR_HEIGHT=0
    return 0
}

_end_popview_leave_open() {
    local label=$1
    local outfile=$2
    local rc=$3

    my_tput_cup $SV_TOP_ANCHOR 0
    if (( rc == 0 )); then
        _render_label_success "$label" "$outfile"
    else
        _render_label_failure "$label" "$outfile" "$rc"
        if ((SV_BORDER_SHOW && SV_CUR_HEIGHT > 0)); then
            # Re-render the border in red (leaving text inside view untouched).
            my_get_term_width SV_WIN_ORIG_WIDTH; my_get_term_height SV_WIN_ORIG_HEIGHT

            local -i rt_border_xpos=$((SV_WIN_ORIG_WIDTH - SV_BORDER_MARGIN_RIGHT - 1))
            local padleft_str=${(l:$SV_BORDER_MARGIN_LEFT:: :):""}
            local border_str=${(l:$((SV_WIN_ORIG_WIDTH - SV_BORDER_MARGIN_LEFT - SV_BORDER_MARGIN_RIGHT - 2))::─:):""}
            print -v SV_TOP_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╭%s╮${RESET}" "$padleft_str" "$border_str"
            print -v SV_BOT_BORDER_STR -f "%s${MSG_FAILURE_TEXT_COLOR}╰%s╯${RESET}" "$padleft_str" "$border_str"

            print "$SV_TOP_BORDER_STR"
            local -i index=0    ypos=$SV_TOP_SCROLLREGION
            for (( index = 0; index < SV_CUR_HEIGHT; index++, ypos++ )); do
                my_tput_cup "$ypos" 0;                  printf "%s${MSG_FAILURE_TEXT_COLOR}│" "$padleft_str"
                my_tput_cup "$ypos" "$rt_border_xpos";  print "│${RESET}"
            done
            print "$SV_BOT_BORDER_STR"
            return 0
        fi
    fi
    if ((SV_CUR_HEIGHT > 0)); then
        local -i ypos=$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT - 1))
        ((SV_BORDER_SHOW)) && ((ypos++))
        my_tput_cup "$ypos" 0
        print
    fi
    return 0
}

_end_popview_with_close() {
    local label=$1
    local outfile=$2

    my_tput_cup $SV_TOP_ANCHOR 0
    _render_label_success "$label" "$outfile"
    if ((SV_CUR_HEIGHT == 0)); then
        return 0  # Nothing was ever rendered, so no cleanup needed.
    fi

    my_sleep $SV_CLOSE_DELAY
    local -i unused_width=0 unused_height=0
    if _process_win_resize unused_width unused_height; then
        _render_label_success "$label" "$outfile"
        return 0
    fi

    if ((SV_BORDER_SHOW && SV_BORDER_ANIMATE_CLOSE)); then
        SV_BOT_SCROLLREGION=$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT))
        my_tput_csr "$SV_TOP_SCROLLREGION" "$SV_BOT_SCROLLREGION"; SV_INSIDE_TPUTCSR=1
        my_tput_cup "$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT))" 0
        local -i index
        for (( index = 0; index < SV_CUR_HEIGHT; index++ )); do
            print
            my_sleep $SV_CLOSE_ANIMATE_DELAY
            if _process_win_resize unused_width unused_height; then
                _render_label_success "$label" "$outfile"
                return 0
            fi
        done
        ((SV_INSIDE_TPUTCSR)) && my_tput_rcsr; SV_INSIDE_TPUTCSR=0
        my_tput_cup "$((SV_TOP_ANCHOR + 2))" 0;     my_tput_el
        my_tput_cup "$((SV_TOP_ANCHOR + 1))" 0;     my_tput_el
    else
        local -i top=$((SV_TOP_ANCHOR + 1))
        local -i bottom=$((SV_BOT_SCROLLREGION))
        if ((SV_BORDER_SHOW)); then
            ((bottom++))
        fi
        local -i row
        for (( row = bottom; row >= top; row-- )); do
            my_tput_cup $row 0;     my_tput_el
        done
    fi
    return 0
}

_render_progress_spinner() {
    if (( EPOCHREALTIME - SV_SPINNER_LAST_UPDATE < SV_SPINNER_UPDATE_INTERVAL )); then
        return 0
    fi
    SV_SPINNER_LAST_UPDATE=$EPOCHREALTIME
    my_tput_cup $SV_TOP_ANCHOR 0
    printf "%s" "${SV_SPINNER_CHARS[SV_SPINNER_IDX]}"
    ((SV_SPINNER_IDX++ && SV_SPINNER_IDX > SV_SPINNER_LEN)) && SV_SPINNER_IDX=1
    return 0
}

_render_line() {
    local text=$1
    local width=$2

    my_tput_rmam  # disable auto-wrapping of lines
    my_start_buffered_update

    if ((SV_BORDER_SHOW)); then
        # This case is more complicated because we animate/grow the border frame downward
        # as the first SV_MAX_HEIGHT lines arrive, and only set the scroll region once
        # that height is hit.
        if ((SV_CUR_HEIGHT == 0)); then
            # First output line: draw top border.
            local -i ypos=$((SV_TOP_SCROLLREGION - 1))
            my_tput_cup "$ypos" 0
            print "$SV_TOP_BORDER_STR"
        else
            # Advance to next line (previous output line doesn't include /n).
            # This will force a line scroll if SV_CUR_HEIGHT == SV_MAX_HEIGHT.
            local -i ypos=$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT - 1))
            my_tput_cup "$ypos" 0
            print
        fi
        # Render the output line (which was wrapped for us using 'fold').
        local padleft_str=${(l:$SV_BORDER_MARGIN_LEFT:: :):""}
        if ((1)); then
            # Handling double-width characters is problematic since neither the built-in
            # string length primitives (printf with %-*s) nor the 'fold' command handle
            # them correctly. This results in the line truncation (or wrapping if using fold)
            # breaking at the wrong place, which also results in our right border line
            # rendering at the incorrect location (offset to the right or offscreen).
            #
            # The best we can do here is turn off auto-wrappping of lines and truncate
            # the line using printf %-*s primitive which might bleed over to the right
            # too many characters. Next we force the cursor to the correct location to
            # draw the right border charcter, then clear to end-of-line. This results in
            # at least the right border drawing at the correct location. Some characters
            # in the line might be truncated in this case (even if SV_WRAP_LINES is 1),
            # but is a pretty small rendering buglet probably not noticed.
            printf "%s${PROCESSING_TEXT_COLOR}│ ${LOG_TEXT_COLOR}%-*s " "$padleft_str" "$width" "$text"
            local -i ypos=$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT))
            ((SV_CUR_HEIGHT == SV_MAX_HEIGHT)) && ((ypos--))
            my_tput_cup "$ypos" "$((SV_WIN_ORIG_WIDTH - SV_BORDER_MARGIN_RIGHT - 1))"
            print -n "${PROCESSING_TEXT_COLOR}│${RESET}";    my_tput_el
        else
            # This unused technique works okay if there are no double-width characters. If there
            # are then the right border will be at the wrong location and SV_BORDER_MARGIN_RIGHT
            # won't be obeyed.
            printf "%s${PROCESSING_TEXT_COLOR}│ ${LOG_TEXT_COLOR}%-*s ${PROCESSING_TEXT_COLOR}│${RESET}" "$padleft_str" "$width" "$text"
            my_tput_el
        fi
        if ((SV_CUR_HEIGHT < SV_MAX_HEIGHT)); then
            # Re-render bottom border one line down (it was just erased by the
            # output line above). This creates the dynamic growing border view
            # animation.
            print -n "\n$SV_BOT_BORDER_STR";    my_tput_el
            ((SV_CUR_HEIGHT++))
            if ((SV_CUR_HEIGHT == SV_MAX_HEIGHT)); then
                # The last output line above was on the last line of the scroll
                # region, so it is time to set the scroll region so all subsequent
                # output lines automatically scroll correctly. After this point
                # we no longer need to render the bottom border, as the scroll
                # region is now full and locked in (the bottom border is no longer
                # overwritten by the output since it is outside the scroll region).
                my_tput_csr "$SV_TOP_SCROLLREGION" "$SV_BOT_SCROLLREGION"; SV_INSIDE_TPUTCSR=1
            fi
            my_tput_cup "$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT - 1))" 0
        fi
    else
        # This case (no border) is simpler since we can set the scroll region on the very
        # first output line, and then let it handle the scrolling from that point forward.
        if ((SV_CUR_HEIGHT == 0)); then
            # First output line: set scroll region and move cursor to top
            local -i ypos=$SV_TOP_SCROLLREGION
            my_tput_csr "$ypos" "$SV_BOT_SCROLLREGION"; SV_INSIDE_TPUTCSR=1
            my_tput_cup "$ypos" 0
        else
            # Advance to next line (previous output line doesn't include /n).
            # This will force a line scroll if SV_CUR_HEIGHT == SV_MAX_HEIGHT.
            local -i ypos=$((SV_TOP_SCROLLREGION + SV_CUR_HEIGHT - 1))
            my_tput_cup "$ypos" 0
            print
        fi
        if ((SV_CUR_HEIGHT < SV_MAX_HEIGHT)); then
            ((SV_CUR_HEIGHT++))
        fi
        local padleft_str=${(l:$SV_BORDER_MARGIN_LEFT:: :):""}
        printf "%s  ${LOG_TEXT_COLOR}%-*s${RESET}  " "$padleft_str" "$width" "$text";    my_tput_el
    fi

    my_end_buffered_update
    my_tput_smam  # re-enable auto-wrapping of lines
    return 0
}

_process_win_resize() {
    local out_width=$1    # after zsh 5.10+ use: local -n out_width=$1
    local out_height=$2   # after zsh 5.10+ use: local -n out_height=$2

    # must call yield before my_get_term_width / my_get_term_height
    _yield_to_parser
    local -i width=0 height=0
    my_get_term_width width; my_get_term_height height
    # after zsh 5.10+ use: out_width="$width" and out_height="$height"
    : ${(P)out_width::="$width"}
    : ${(P)out_height::="$height"}

    if ((width != SV_WIN_ORIG_WIDTH || height != SV_WIN_ORIG_HEIGHT)); then
        # Window resize detected. There isn't a graceful way to re-render everything
        # already shown, so we clear the screen, and have ther caller reprint the
        # label.
        SV_WIN_TOO_SMALL=$((width < SV_MIN_WIN_WIDTH || height < SV_MIN_WIN_HEIGHT))
        ((SV_INSIDE_TPUTCSR)) && my_tput_rcsr; SV_INSIDE_TPUTCSR=0
        my_tput_clear
        return 0
    fi
    return 1
}

_process_popview() {
    local label=$1
    if [[ -z $SV_PID || -z $SV_FD ]]; then
        return 0   # No pending async process, bail out.
    fi

    local -i select_timeout=$((100 * SV_SPINNER_UPDATE_INTERVAL))
    while true; do
        local -i fd_readable=0
        zselect -t $select_timeout -r $SV_FD && fd_readable=1
        local -i cur_width=0 cur_height=0
        if _process_win_resize cur_width cur_height; then
            if ((SV_WIN_TOO_SMALL)); then
                # Window shrank to be too small for useful rendering. Just
                # Re-render the processing label and bail out from trying.
                ((SV_INSIDE_TPUTCSR)) && my_tput_rcsr; SV_INSIDE_TPUTCSR=0
                _render_label_processing "$label"
                return 0
            else
                # Window resized but is still large enough. Reset and restart
                # the scroll view and continue rendering loop.
                _start_popview $label
            fi
        fi
        if (( fd_readable )); then
            local lineout=""
            if ! read -r -u $SV_FD lineout; then
                break
            fi
            # Saving entire scrollview buffer (SV_OUTBUF) is currently disabled since
            # we don't reference it anywhere (and provide an optional $outfile argument
            # to save all output to a file). If we ever need it, then just uncomment:
            #   SV_OUTBUF+="$lineout"$'\n'

            local -i width=$((cur_width - SV_BORDER_MARGIN_LEFT - SV_BORDER_MARGIN_RIGHT - 4))
            if (( SV_WRAP_LINES )); then
                while IFS= read -r text; do
                    local noesc_text=""
                    strip_control_chars "$text" noesc_text
                    _render_line "$noesc_text" "$width"
                done < <(printf '%s\n' "$lineout" | fold -s -w "$width")
            else
                # Hard truncate to width instead of wrapping.
                local noesc_text=""
                strip_control_chars "$lineout" noesc_text
                ((${#noesc_text} > width)) && noesc_text="${noesc_text[1,$width]}"
                _render_line "$noesc_text" "$width"
            fi
            _render_progress_spinner
        else
            _render_progress_spinner
        fi
    done
    # reset scroll region to full screen
    ((SV_INSIDE_TPUTCSR)) && my_tput_rcsr; SV_INSIDE_TPUTCSR=0
    return 0
}

exec_with_popview() {
    emulate -L zsh
    local label=$1
    local outfile=$2
    shift 2

    local -i width=0 height=0
    my_get_term_width width; my_get_term_height height
    if ((SV_ENABLE == 0 || width < SV_MIN_WIN_WIDTH || height < SV_MIN_WIN_HEIGHT)); then
        _render_label_processing "$label"
        if [[ -n "$outfile" ]]; then
            # Scrolling popview not enabled (or window to narrow); only capture output to file.
            _append_log_timestamp "$outfile" "$@"
            "$@" 1>> "$outfile" 2>&1
        else
            # No output file specified; output is not captured and only process error code is checked.
            "$@" &>/dev/null
        fi
        local rc=$?
        if (( rc == 0 )); then
            _render_label_success "$label" "$outfile"
        else
            _render_label_failure "$label" "$outfile" "$rc"
            return rc
        fi
        return 0
    fi
    SV_WIN_TOO_SMALL=0

    # Else scrolling popview is enabled, so we'll capture the output as it comes and
    # temporarily display it until process is finished.
    if [[ -n $SV_PID ]]; then
        # Should never happen, but bail out if it does.
        print_error "Error: exec_with_popview cannot be called recursively or asynchronously"
        return 1
    fi

    SV_PID=""; SV_FD=""; SV_OUTBUF=""
    if [[ -n "$outfile" ]]; then
        _append_log_timestamp "$outfile" "$@"
        coproc {
            set -o pipefail
            "$@" 2>&1 | tee -a "$outfile"
        }
    else
        coproc {
            "$@" 2>&1
        }
    fi
    SV_PID=$!
    exec {SV_FD}<&p

    trap 'my_tput_rcsr; my_tput_cnorm; echo' EXIT
    trap 'my_tput_rcsr; my_tput_cnorm; echo; exit' INT TERM HUP QUIT
    my_tput_civis

    SV_INSIDE_TPUTCSR=0
    _start_popview $label
    _process_popview $label

    # Clean up the fd, and wait (process is dead, so will be instant) to retrieve return code.
    local -i rc
    exec {SV_FD}<&-;    SV_FD=""
    wait $SV_PID;       rc=$?
    SV_PID="";  SV_OUTBUF=""
    if (( rc != 0 || SV_DEBUG_SKIP_CLOSE )); then
        # failure: leave scroll view visible since it likely explains the failure
        _end_popview_leave_open "$label" "$outfile" "$rc"
        my_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
        return rc
    else
        # success: wipe the scroll view rows, show a single success line, cleanup
        _end_popview_with_close "$label" "$outfile"
        my_tput_cnorm
        trap - INT TERM HUP QUIT EXIT
    fi
    return 0
}

########################################
# Before we can load the global_config.yaml file, we need to have installed:
#
#   XCode Command Line Tools, Homebrew, and yq.
#
# Other install and build dependencies are installed as-needed later by the installer scripts.
install_dev_tools() {
    if ! xcrun -f clang >/dev/null 2>&1; then
        print_info "This script requires the Xcode Command Line Tools."
        print_info "Click 'Install' inside alert to proceed, and after the installation completes re-run this script."
        # ToDo: might need to first do: sudo xcodebuild -license
        xcode-select --install
        exit 1
    fi
    # brew for installing script and build dependencies
    export HOMEBREW_NO_ENV_HINTS=1
    if [[ -f "/opt/homebrew/bin/brew" ]] && ! program_exists "brew"; then
        # In case this line isn't included in .zprofile ('brew' won't be found), we
        # can just manually eval it now. This should add the directory used by brew
        # to PATH so it can be found in the next (program_exists) conditional.
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi
    if ! program_exists "brew"; then
        if ! sudo -n /usr/bin/true 2>/dev/null; then
            # Homebrew install script below requires sudo perms, so prime a sudo session first.
            print_info "This script requires homebrew for installing dependencies. Enter your macOS account password to proceed."
            sudo /usr/bin/true
        else
            # We already in a sudo session (or running under admin privs).
            print_info "This script requires homebrew for installing dependencies."
        fi
        export NONINTERACTIVE=1
        exec_with_popview \
            "Installing homebrew..." \
            "" \
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || exit $?
        # Direct technique if exec_with_popview is failing for some reason:
        #
        #    print_info "Installing homebrew..."
        #    /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        #      || exit $?

        grep -E '^eval "\$\(/opt/homebrew/bin/brew shellenv\)"' "$HOME/.zprofile" &>/dev/null
        if (( $? != 0 )); then
            print_info "✓ Adding 'brew shellevn' to ~/.zprofile"
            echo >> "$HOME/.zprofile"
            echo "# Added by Bitcoin Mac Node Builder" >> "$HOME/.zprofile"
            echo 'eval "$(/opt/homebrew/bin/brew shellenv)"' >> "$HOME/.zprofile"
        fi
        eval "$(/opt/homebrew/bin/brew shellenv)"
    fi

    # jq for parsing of json results
    if ! program_exists "jq" && ! brew list jq &>/dev/null; then
        my_brew_install jq || exit $?
    fi
    # yq for yaml parsing of config files
    if ! program_exists "yq" && ! brew list yq &>/dev/null; then
        my_brew_install yq || exit $?
    fi
}

########################################
parse_global_config_file() {
    install_dev_tools

    typeset -g CONFIG_FILE="$SCRIPT_DIR/$CONFIG_FILENAME"
    typeset -g SCRIPT_DIR="${0:A:h}"
    typeset -g BITCOIN_CORE_INSTALL_SH_FILE="$SCRIPT_DIR/bitcoin-core-install.sh"
    typeset -g ELECTRS_INSTALL_SH_FILE="$SCRIPT_DIR/electrs-install.sh"
    if [[ ! -f "$CONFIG_FILE" ]]; then
        print_error "Error: $CONFIG_FILENAME not found (should be in same directory as this script)"
        exit 1
    fi
    typeset -g CONFIG_YAML=$(<"$CONFIG_FILE")

    # Populate BITCOIN_CORE_CONFIG from global_config.yaml
    typeset -gA BITCOIN_CORE_CONFIG
    while read -r line; do
        key="${line%%=*}"     # Everything before first =
        val="${line#*=}"      # Everything after first =
        BITCOIN_CORE_CONFIG[$key]=$val
    done < <(yq -r '.bitcoin_core | to_entries | .[] | "\(.key)=\(.value)"' <<< "$CONFIG_YAML")
    # Populate BITCOIN_CORE_RAW with all key/values which have an underscore prefix.
    typeset -gA BITCOIN_CORE_RAW
    for key in "${(@k)BITCOIN_CORE_CONFIG}"; do
        if [[ "$key" == _* ]]; then
            raw_key="${key#_}"
            BITCOIN_CORE_RAW[$raw_key]="${BITCOIN_CORE_CONFIG[$key]}"
        fi
    done

    # Populate ELECTRS_SERVER_CONFIG from global_config.yaml
    typeset -gA ELECTRS_SERVER_CONFIG
    while read -r line; do
        key="${line%%=*}"     # Everything before first =
        val="${line#*=}"      # Everything after first =
        ELECTRS_SERVER_CONFIG[$key]=$val
    done < <(yq -r '.electrs_server | to_entries | .[] | "\(.key)=\(.value)"' <<< "$CONFIG_YAML")

    # Debug dumping the config values read from global_config.yaml:
    #
    # for key in "${(@k)BITCOIN_CORE_CONFIG}"; do
    #     printf 'BITCOIN_CORE_CONFIG[%s] = %s\n' "$key" "${BITCOIN_CORE_CONFIG[$key]}"
    # done
    # for key in "${(@k)ELECTRS_SERVER_CONFIG}"; do
    #     printf 'ELECTRS_SERVER_CONFIG[%s] = %s\n' "$key" "${ELECTRS_SERVER_CONFIG[$key]}"
    # done
    # echo; echo
}
