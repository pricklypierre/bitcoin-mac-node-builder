#!/bin/zsh
#
# Amor et tolerantia erga omnes oppressos.
#

emulate -L zsh

########################################
NODE_MONITOR_VERSION="1.0.0"

########################################
SCRIPT_DIR="${0:A:h}"
if [[ -f "$SCRIPT_DIR/_common-install.sh" ]]; then
    source "$SCRIPT_DIR/_common-install.sh"
    parse_global_config_file
else
    echo "Error: _common-install.sh not found (should be in same directory as this script)"
    exit 1
fi
setopt extended_glob    # needed for case insensitive compares throughout

########################################
typeset -F SLEEP_INTERVAL=0.15

BTC_TARGET_PATH=${BITCOIN_CORE_CONFIG[target_path]}
BTC_ENABLE_INSTALL=${BITCOIN_CORE_CONFIG[enable_install]:-false}

BTC_GUI_APP_NAME="Bitcoin-Qt"
BTC_PROCESS_NAME="bitcoind"
BTC_PROCESS_PATH="$BTC_TARGET_PATH/bin/$BTC_PROCESS_NAME"
BTC_PROCESS_PID=""
BTC_CLI_NAME="bitcoin-cli"
BTC_CLI_PATH="$BTC_TARGET_PATH/bin/$BTC_CLI_NAME"
BTC_START_SH="$BTC_TARGET_PATH/bin/start.sh"
BTC_STOP_SH="$BTC_TARGET_PATH/bin/stop.sh"
BTC_LOG_NAME="debug.log"
BTC_LOG_PATH="$BTC_TARGET_PATH/$BTC_LOG_NAME"

ELECTRS_TARGET_PATH=${ELECTRS_SERVER_CONFIG[target_path]}
ELECTRS_ENABLE_INSTALL=${ELECTRS_SERVER_CONFIG[enable_install]:-false}
ELECTRS_ENABLED=0
if [[ $ELECTRS_ENABLE_INSTALL == (#i)true ]]; then
    ELECTRS_ENABLED=1
fi

ELECTRS_PROCESS_NAME="electrs"
ELECTRS_PROCESS_PATH="$ELECTRS_TARGET_PATH/bin/$ELECTRS_PROCESS_NAME"
ELECTRS_PROCESS_PID=""
ELECTRS_START_SH="$ELECTRS_TARGET_PATH/bin/start.sh"
ELECTRS_STOP_SH="$ELECTRS_TARGET_PATH/bin/stop.sh"
ELECTRS_LOG_NAME="electrs.log"
ELECTRS_LOG_PATH="$ELECTRS_TARGET_PATH/$ELECTRS_LOG_NAME"
ELECTRS_CHAIN_HEIGHT="--"  # parsed out as log file is rendered

if pgrep -x "$BTC_GUI_APP_NAME" > /dev/null; then
    print_error "$BTC_GUI_APP_NAME (GUI app) is running. This montior script only works with the bitcoind (headless) process."
    exit 1
fi
if [[ "$BTC_ENABLE_INSTALL" == (#i)false ]]; then
    print_error "enable_install is not set for Bitcoin Core. To enable building/installing edit the ${CONFIG_FILENAME} file:"
    echo
    print_error "  ${CONFIG_FILE}"
    echo
    print_error "then run the installer script:"
    echo
    print_error "  ${BITCOIN_CORE_INSTALL_SH_FILE}"
    exit 1
fi
if [[ ! -f "$BTC_CLI_PATH" ]]; then
    print_error "Bitcoin Core installation not found (missing $BTC_CLI_PATH). To install use:"
    echo
    print_error "  ${BITCOIN_CORE_INSTALL_SH_FILE}"
    exit 1
fi

########################################
typeset -i TERM_WIDTH=0 TERM_HEIGHT=0
my_get_term_width TERM_WIDTH; my_get_term_height TERM_HEIGHT
typeset -i COL1_WIDTH=20
typeset -i COL1_MIN_WIDTH=8  # threshold at which we punt on rendering column
typeset -i COL2_WIDTH=40
typeset -i STATS_VIEW_WIDTH=$((COL1_WIDTH + COL2_WIDTH + 7))  # +7 for spacing and borders
typeset -i PB_WIDTH=30

# Adaptive Layout Metrics:
#
# Only show log views (right column tables) if there is at least a width
# of 46 left after stats tables are rendered (left column tables).
typeset -i LOGVIEW_MIN_WIDTH=46

# Only render secondary stats/log views (Electrs, etc.) If after rendering
# the main bitcoind stats/log views there is at least a height of 12 left.
# This value should match the height of the secondary stats table view.
typeset -i SECONDARY_MIN_HEIGHT=12
# Cap secondary log height to a maximum of 16, after which the main log
# view is maximized to fill the remaining height.
typeset -i SECONDARY_PREFERRED_HEIGHT=16

zmodload zsh/datetime   # for $EPOCHREALTIME var
typeset -i DEBUG_SHOW=0
typeset -i DEBUG_BENCHMARK_FUNCS=0
typeset -i DEBUG_MIN_HEIGHT=13

########################################
# We make all bitcoin-cli calls async because they can stall for several
# seconds, especially during bitocind startup and initial block download.
typeset -i ASYNC_BTC_CLI_CALLS=1
if (( ASYNC_BTC_CLI_CALLS )); then
    FETCH_JSON_FUNC="fetch_json_data_async"
    BTC_CLI_CMDS=(      # We getmempoolinfo more often since it updates most frequently (after IBD)
        "getblockchaininfo"
        "getmempoolinfo"
        "getnetworkinfo"
        "getmempoolinfo"
        "getnettotals"
    )
    BTC_CLI_LEN=${#BTC_CLI_CMDS[@]}
    BTC_CLI_CMDIDX=1
    # During IBD getmempool isn't useful, so just get blockchain and network info.
    BTC_CLI_CMDS_IBD=(
        "getblockchaininfo"
        "getnetworkinfo"
        "getblockchaininfo"
        "getnettotals"
    )
    BTC_CLI_LEN_IBD=${#BTC_CLI_CMDS_IBD[@]}
    BTC_CLI_CMDIDX_IBD=1
else
    FETCH_JSON_FUNC="fetch_json_data"
fi

typeset -i NODE_RUNNING=0
FETCH_JSON_ERROR=""
WAITING_ON_IBD="false"
BTC_BLOCKINFO_JSON=""; BTC_MEMPOOLINFO_JSON=""; BTC_NETINFO_JSON=""; BTC_NETTOTALS_JSON=""
BTC_BLOCKINFO_NEED_PARSE=0; BTC_MEMPOOLINFO_NEED_PARSE=0; BTC_NETINFO_NEED_PARSE=0; BTC_NETTOTALS_NEED_PARSE=0
BTC_CLI_PID=""; BTC_CLI_FD=""; BTC_CLI_OUTBUF=""
BTC_CLI_CURCMD=""

########################################
# As an optimization we don't refresh/calculate all of the metrics
# on every loop iteration. For example, process_footprint_memory is
# particularly slow (about 0.051s). The iteration counts below are
# based on approximately how slow the calls are (shown below) to
# keep the average iteration loop speed fast so that the log file
# rendering is snappy (it renders on every iteration loop).
typeset -A CALL_COUNTERS
typeset -A CALL_INTERVALS
CALL_INTERVALS[mem_usage]=5      # Every 5th iteration (0.062s for process_rss_memory + process_footprint_memory calls)
CALL_INTERVALS[cpu_usage]=2      # Every 2th iteration (0.024s for process_uptime + process_cpu_load calls)
CALL_INTERVALS[disk_usage]=9     # Every 9th iteration (0.019s for 1 du + 2 df calls)

########################################
typeset -i CORE_COUNT=0
get_cpu_core_count CORE_COUNT

########################################
poll_out_async() {
    if [[ -z $BTC_CLI_PID || -z $BTC_CLI_FD ]]; then
        return 0   # No pending async process, bail out.
    fi

    # Non-blocking read any pending data, regardless if process is still alive or not
    local lineout
    while read -r -t 0 -u $BTC_CLI_FD lineout; do
        BTC_CLI_OUTBUF+="$lineout"$'\n'
    done
    if kill -0 "$BTC_CLI_PID" 2>/dev/null; then
        # (note calling "kill -0" above is way faster than using "ps -p")
        return 0   # Process is still alive (processing or writing data), bail to avoid blocking.
    fi
    # Process is finished/dead, so can now safely block reading the last bit of data.
    while read -r -u $BTC_CLI_FD lineout; do
        BTC_CLI_OUTBUF+="$lineout"$'\n'
    done
    # Clean up the fd, and wait (process is dead, so will be instant) to retrieve return code.
    exec {BTC_CLI_FD}<&-; BTC_CLI_FD=""
    local rc; wait $BTC_CLI_PID; rc=$?; BTC_CLI_PID=""
    if (( rc == 0 )); then
        NODE_RUNNING=1
        FETCH_JSON_ERROR=""
        case "$BTC_CLI_CURCMD" in
            "getblockchaininfo")    BTC_BLOCKINFO_JSON="${BTC_CLI_OUTBUF%$'\n'}";   BTC_BLOCKINFO_NEED_PARSE=1   ;;
            "getnetworkinfo")       BTC_NETINFO_JSON="${BTC_CLI_OUTBUF%$'\n'}";     BTC_NETINFO_NEED_PARSE=1     ;;
            "getnettotals")         BTC_NETTOTALS_JSON="${BTC_CLI_OUTBUF%$'\n'}";   BTC_NETTOTALS_NEED_PARSE=1   ;;
            "getmempoolinfo")       BTC_MEMPOOLINFO_JSON="${BTC_CLI_OUTBUF%$'\n'}"; BTC_MEMPOOLINFO_NEED_PARSE=1 ;;
            *)                      return 1 ;;
        esac
        BTC_CLI_OUTBUF=""
    else
        # Do we really want to wipe out all the JSON if a single command fails? probably...
        # Could append BTC_CLI_OUTBUF onto FETCH_JSON_ERROR here to show more detail, but let's
        # keep it to a single error line to display in the refreshing UI since this might be
        # a transient error (node is starting up).
        NODE_RUNNING=0
        BTC_CLI_OUTBUF=""
        BTC_BLOCKINFO_JSON=""; BTC_MEMPOOLINFO_JSON=""; BTC_NETINFO_JSON=""; BTC_NETTOTALS_JSON=""
        BTC_BLOCKINFO_NEED_PARSE=0; BTC_MEMPOOLINFO_NEED_PARSE=0; BTC_NETINFO_NEED_PARSE=0; BTC_NETTOTALS_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoin-cli ${BTC_CLI_CURCMD} failed (bitcoind might be starting up)"
    fi

    return 0
}

fetch_json_data_async() {
    # First, handle polling data out of the async process pipes.
    poll_out_async

    if [[ -z "$BTC_PROCESS_PID" ]] || ! kill -0 "$BTC_PROCESS_PID" 2>/dev/null; then
        # (note calling "kill -0" above is way faster than using "ps -p")
        NODE_RUNNING=0
        BTC_BLOCKINFO_JSON=""; BTC_MEMPOOLINFO_JSON=""; BTC_NETINFO_JSON=""; BTC_NETTOTALS_JSON=""
        BTC_BLOCKINFO_NEED_PARSE=0; BTC_MEMPOOLINFO_NEED_PARSE=0; BTC_NETINFO_NEED_PARSE=0; BTC_NETTOTALS_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoind is not running"
        return 1
    fi
    NODE_RUNNING=1

    # Next, if there is no pending async process then start the next one.
    if [[ -z $BTC_CLI_PID ]]; then
        BTC_CLI_FD=""; BTC_CLI_OUTBUF=""

        if [[ "${WAITING_ON_IBD:-false}" == "true" ]]; then
            BTC_CLI_CURCMD="${BTC_CLI_CMDS_IBD[$BTC_CLI_CMDIDX_IBD]}"
            ((BTC_CLI_CMDIDX_IBD++ && BTC_CLI_CMDIDX_IBD > BTC_CLI_LEN_IBD)) && BTC_CLI_CMDIDX_IBD=1
        else
            BTC_CLI_CURCMD="${BTC_CLI_CMDS[$BTC_CLI_CMDIDX]}"
            ((BTC_CLI_CMDIDX++ && BTC_CLI_CMDIDX > BTC_CLI_LEN)) && BTC_CLI_CMDIDX=1
        fi
        coproc {
            my_sleep 0.25      # Give bitcoind some idle time between requests.
            "$BTC_CLI_PATH" "$BTC_CLI_CURCMD" 2>&1
        }
        BTC_CLI_PID=$!
        exec {BTC_CLI_FD}<&p
    fi
    return 0
}

fetch_json_data() {
    if [[ -z "$BTC_PROCESS_PID" ]] || ! kill -0 "$BTC_PROCESS_PID" 2>/dev/null; then
        # (note calling "kill -0" above is way faster than using "ps -p")
        NODE_RUNNING=0
        FETCH_JSON_ERROR="bitcoind is not running"
        return 1
    fi

    FETCH_JSON_ERROR=""
    BTC_BLOCKINFO_JSON=""
    if RESULT="$("$BTC_CLI_PATH" getblockchaininfo 2>&1)"; then
        BTC_BLOCKINFO_JSON=$RESULT
        BTC_BLOCKINFO_NEED_PARSE=1
    else
        NODE_RUNNING=0
        BTC_BLOCKINFO_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoin-cli getblockchaininfo failed (bitcoind might be starting up)"
        # Could append $RESULT onto FETCH_JSON_ERROR here to show more detail, but let's
        # keep it to a single error line to display in the refreshing UI since this might be
        # a transient error (node is starting up).
        # print_error "$RESULT"
        return 1
    fi
    BTC_NETINFO_JSON=""
    if RESULT="$("$BTC_CLI_PATH" getnetworkinfo 2>&1)"; then
        BTC_NETINFO_JSON=$RESULT
        BTC_NETINFO_NEED_PARSE=1
    else
        NODE_RUNNING=0
        BTC_NETINFO_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoin-cli getnetworkinfo failed (bitcoind might be starting up)"
        return 1
    fi
    BTC_NETTOTALS_JSON=""
    if RESULT="$("$BTC_CLI_PATH" getnettotals 2>&1)"; then
        BTC_NETTOTALS_JSON=$RESULT
        BTC_NETTOTALS_NEED_PARSE=1
    else
        NODE_RUNNING=0
        BTC_NETTOTALS_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoin-cli getnettotals failed (bitcoind might be starting up)"
        return 1
    fi
    BTC_MEMPOOLINFO_JSON=""
    if RESULT="$("$BTC_CLI_PATH" getmempoolinfo 2>&1)"; then
        BTC_MEMPOOLINFO_JSON=$RESULT
        BTC_MEMPOOLINFO_NEED_PARSE=1
    else
        NODE_RUNNING=0
        BTC_MEMPOOLINFO_NEED_PARSE=0
        FETCH_JSON_ERROR="bitcoin-cli getmempoolinfo failed (bitcoind might be starting up)"
        return 1
    fi
    NODE_RUNNING=1
    return 0
}

########################################
calc_block_sync_progress_ui() {
    local blocks_processed=$1
    local headers_seen=$2
    local progress_float=$3
    local out_progress_bar=$4   # after zsh 5.10+ use: local -n out_progress_bar=$4

    local progress_bar=""
    if [[ $blocks_processed == 0 && $headers_seen == 0 ]]; then
        local empty=${(l:$PB_WIDTH::█:):""}
        print -v progress_bar -f "${PB_COLOR_BORDER}|${PB_COLOR_FILL}%s${PB_COLOR_EMPTY}%s${PB_COLOR_BORDER}| ${PB_COLOR_TEXT}%s%%${RESET}" \
          "" "$empty" "0"
    else
        local filled=$((progress_float * PB_WIDTH / 100))
        print -v filled -f "%.0f" "$filled"
        ((filled > PB_WIDTH)) && filled=$PB_WIDTH
        ((filled < 0)) && filled=0
        if ((filled == PB_WIDTH)) && [[ $blocks_processed != $headers_seen ]]; then
            ((filled--))    # If not 100% sync'd then don't show progress bar 100% full
        fi
        local bar1=${(l:$filled::█:):""}
        local empty=${(l:$((PB_WIDTH - filled))::█:):""}
        local progress_txt=""
        if ((progress_float <= 0.01)); then
            progress_txt="0"
        elif ((progress_float >= 99.99)); then
            if [[ $blocks_processed != $headers_seen ]]; then
                progress_txt="99.99+"
            else
                progress_txt="100"
            fi
        else
            print -v progress_txt -f "%.2f" "$progress_float"
        fi
        print -v progress_bar -f "${PB_COLOR_BORDER}|${PB_COLOR_FILL}%s${PB_COLOR_EMPTY}%s${PB_COLOR_BORDER}| ${PB_COLOR_TEXT}%s%%${RESET}" \
          "$bar1" "$empty" "$progress_txt"
    fi
    # after zsh 5.10+ use: out_progress_bar="$progress_bar"
    : ${(P)out_progress_bar::="$progress_bar"}
    return 0
}

calc_disc_usage_progress_ui() {
    local target_path=$1
    local target_label=$2
    local out_progress_bar=$3    # after zsh 5.10+ use: local -n out_progress_bar=$3
    local out_progress_desc=$4   # after zsh 5.10+ use: local -n out_progress_desc=$4

    local progress_bar="" progress_desc=""
    if [[ -z $target_path ]]; then
        local empty=${(l:$PB_WIDTH::█:):""}
        print -v progress_bar -f "${PB_COLOR_BORDER}|${PB_COLOR_FILL}%s${PB_COLOR_FILL2}%s${PB_COLOR_EMPTY}%s${PB_COLOR_BORDER}| ${PB_COLOR_TEXT}%s%%${RESET}" \
          "" "" "$empty" "0"
        print -v progress_desc -f "${PB_COLOR_FILL}■ ${VALUE_COLOR}${target_label}   ${PB_COLOR_FILL2}■ ${VALUE_COLOR}other   ${PB_COLOR_EMPTY}■ ${VALUE_COLOR}free"
    else
        local df_array=($(df -kP "$target_path" | awk 'NR==2 {print $4, $2}'))
        local disk_avail=$df_array[1]
        local disk_total=$df_array[2]
        local disc_target_usage=$(du -ks "$target_path" 2>/dev/null | awk '{print $1}')
        local disc_other_usage=$((disk_total - disk_avail - disc_target_usage))

        local disk_ratio=$(((disc_target_usage + disc_other_usage + 0.0) / disk_total))
        local target_ratio=$(((disc_target_usage + 0.0) / disk_total))
        local other_ratio=$(((disc_other_usage + 0.0) / disk_total))

        format_bytes_marketing "$((disk_avail * 1024))" disk_avail
        format_bytes_marketing "$((disk_total * 1024))" disk_total
        format_bytes_marketing "$((disc_target_usage * 1024))" disc_target_usage
        format_bytes_marketing "$((disc_other_usage * 1024))" disc_other_usage

        local target_filled=$((target_ratio * PB_WIDTH))
        print -v target_filled -f "%.0f" "$target_filled"
        local other_filled=$((other_ratio * PB_WIDTH))
        print -v other_filled -f "%.0f" "$other_filled"
        # Sanity check combined width in case both rounded up.
        while ((target_filled + other_filled > PB_WIDTH)); do
            if ((other_filled > 0)); then
                other_filled=$((other_filled - 1))
            else
                target_filled=$((target_filled - 1))
            fi
        done
        ((target_filled < 0)) && target_filled=0
        ((other_filled < 0)) && other_filled=0

        local bar1=${(l:$target_filled::█:):""}
        local bar2=${(l:$other_filled::█:):""}
        local empty=${(l:$((PB_WIDTH - target_filled - other_filled))::█:):""}
        local -F 2 disk_perc=$((100.0 - disk_ratio * 100))

        print -v progress_bar -f "${PB_COLOR_BORDER}|${PB_COLOR_FILL}%s${PB_COLOR_FILL2}%s${PB_COLOR_EMPTY}%s${PB_COLOR_BORDER}| ${PB_COLOR_TEXT}%s%%${RESET}" \
          "$bar1" "$bar2" "$empty" "$disk_perc"
        print -v progress_desc -f "${PB_COLOR_FILL}■ ${VALUE_COLOR}${target_label}   ${PB_COLOR_FILL2}■ ${VALUE_COLOR}other   ${PB_COLOR_EMPTY}■ ${VALUE_COLOR}${disk_avail} free"
    fi
    # after zsh 5.10+ use: out_progress_bar="$progress_bar"    out_progress_desc="$progress_desc"
    : ${(P)out_progress_bar::="$progress_bar"}
    : ${(P)out_progress_desc::="$progress_desc"}
    return 0
}

render_table_row() {
    local col1_text="$1"
    local col2_text="$2"
    local col1_width_adjstd="$3"
    local out_buf=$4   # after zsh 5.10+ use: local -n out_buf=$4

    # Strip colors to get just the visible text len (otherwise padding calculation are off).
    local -i col1_len=0 col2_len=0
    stripped_len "false" "$col1_text" col1_len
    stripped_len "false" "$col2_text" col2_len

    # Calculate padding needed and render into $row.
    if (( col1_width_adjstd < COL1_MIN_WIDTH )); then
        # Label column is too narrow to be useful; punt on trying to render it.
        local pad1_str="" pad2_str=""
        local -i adjust_amt=$(( (col1_width_adjstd + 3) / 2 ))
        local -i adjust_rmder=$(( (col1_width_adjstd + 3) % 2 ))
        local -i pad1=$((adjust_amt + adjust_rmder))
        if ((pad1 > 0)); then
            pad1_str=${(l:$pad1:: :):""}
        fi
        local -i pad2=$((COL2_WIDTH - col2_len + adjust_amt))
        if ((pad2 > 0)); then
            pad2_str=${(l:$pad2:: :):""}
        fi

        local row=""
        print -v row -f "${TABLE_BRDR_COLOR}│ ${VALUE_COLOR}%s%s%s ${TABLE_BRDR_COLOR}│\n" \
          "$pad1_str" "$col2_text" "$pad2_str"
        # after zsh 5.10+ use: out_buf+="$row"
        : ${(P)out_buf::="$row"}
        return 0
    else
        local pad1_str="" pad2_str=""
        local -i pad1=$((col1_width_adjstd - col1_len))
        if ((pad1 > 0)); then
            # Label text fits; pad with spaces on the right.
            pad1_str=${(l:$pad1:: :):""}
        elif ((pad1 < 0)); then
            # Label text needs to be truncated to fit.
            #
            # If col1_text (label text) ever has double-wide characters
            # this text_trunc may not work correctly depending on if they
            # are in the truncation range or not.
            text_trunc "$col1_width_adjstd" "true" "$col1_text" col1_text
        fi
        local -i pad2=$((COL2_WIDTH - col2_len))
        if ((pad2 > 0)); then
            pad2_str=${(l:$pad2:: :):""}
        fi

        local row=""
        print -v row -f "${TABLE_BRDR_COLOR}│ ${LABEL_COLOR}%s%s ${TABLE_BRDR_COLOR}│ ${VALUE_COLOR}%s%s ${TABLE_BRDR_COLOR}│\n" \
          "$col1_text" "$pad1_str" \
          "$col2_text" "$pad2_str"
        # after zsh 5.10+ use: out_buf+="$row"
        : ${(P)out_buf::="$row"}
        return 0
    fi
}

render_centered() {
    local -i width=$1
    local in_text=$2
    local text_color=$3
    local out_text=$4       # after zsh 5.10+ use: local -n out_text=$4
    local text_str=""
    text_center_pad "$width" "true" "$in_text" text_str
    print -v text_str -f "${text_color}%s${RESET}\n" "$text_str"
    # after zsh 5.10+ use: out_text+="$text_str"
    : ${(P)out_text::="$text_str"}
    return 0
}

draw_stats_table() {
    local -i xpos=$1
    local -i ypos=$2
    local -i max_width=$3
    local -i max_height=$4
    local title_color=$5
    local header_txt=$6
    local out_width=$7   # after zsh 5.10+ use: local -n out_width=$7
    local out_height=$8   # after zsh 5.10+ use: local -n out_height=$8
    local -i argindex_stats=9

    # Sanity check to avoid negative rendering values.
    if (( max_width < COL1_WIDTH + 10 || max_height < 5 )); then
        return 0  # Too narrow to be useful for rendering table; bail out.
    fi

    # Top Border with table title
    local table_buf="" table_row=""
    local -i total_width=$STATS_VIEW_WIDTH   total_height=0
    local -i col1_width_adjstd=$COL1_WIDTH
    local -i width_shrink=$(( max_width - total_width ))
    if (( width_shrink < 0 )); then
        # Terminal window is very narrow. Shrink column 1 (labels) so we can still
        # render the actual stat values.
        ((col1_width_adjstd += width_shrink))
        total_width=$max_width
        if (( col1_width_adjstd < 0 )); then
            # Table to narrow to render (already adjusted column 1 beyond 0).
            return 0  # Too narrow to be useful for rendering table; bail out.
        fi
    fi
    local -i col1_repeat=$((col1_width_adjstd + 2))
    local -i col2_repeat=$((COL2_WIDTH + 2))
    local t1=${(l:$col1_repeat::─:):""}
    local t2=${(l:$col2_repeat::─:):""}
    local -i max_header_width=$((total_width - 8))
    if [[ -z $header_txt ]]; then
        header_txt=" "   # rendering logic below doesn't handle empty string
    fi
    text_trunc "$max_header_width" "true" "$header_txt" header_txt
    local -i header_len=0;  stripped_len "true" "$header_txt" header_len
    print -v header_txt -f "${BOLD}${title_color}${header_txt}${UNBOLD}"
    local header_top_bot=${(l:$header_len::─:):""}
    local header_rt_padding_len=$((max_header_width - header_len))
    print -v table_row -f "${TABLE_BRDR_COLOR}   ╭─%s─╮%*s \n" "$header_top_bot" "$header_rt_padding_len" ""
    table_buf+="$table_row"
    if ((header_rt_padding_len > COL2_WIDTH + 3)); then
        header_rt_padding_len=$((header_rt_padding_len - COL2_WIDTH - 3))
        local header_rt_padding=${(l:$header_rt_padding_len::─:):""}
        print -v table_row -f "${TABLE_BRDR_COLOR}╭──│ %s ${TABLE_BRDR_COLOR}│%s┬%s╮\n" "$header_txt" "$header_rt_padding" "$t2"
        table_buf+="$table_row"
        print -v table_row -f "${TABLE_BRDR_COLOR}│  ╰─%s─╯%*s│%*s│\n" "$header_top_bot" "$header_rt_padding_len" "" "$col2_repeat" ""
        table_buf+="$table_row"
    elif ((header_rt_padding_len == COL2_WIDTH + 3)); then
        print -v table_row -f "${TABLE_BRDR_COLOR}╭──│ %s ${TABLE_BRDR_COLOR}│┬%s╮\n" "$header_txt" "$t2"
        table_buf+="$table_row"
        print -v table_row -f "${TABLE_BRDR_COLOR}│  ╰─%s─╯│%*s│\n" "$header_top_bot" "$col2_repeat" ""
        table_buf+="$table_row"
    elif ((header_rt_padding_len > 0)); then
        local header_rt_padding=${(l:$header_rt_padding_len::─:):""}
        print -v table_row -f "${TABLE_BRDR_COLOR}╭──│ %s ${TABLE_BRDR_COLOR}│%s╮\n" "$header_txt" "$header_rt_padding"
        table_buf+="$table_row"
        print -v table_row -f "${TABLE_BRDR_COLOR}│  ╰─%s─╯%*s│\n" "$header_top_bot" "$header_rt_padding_len" ""
        table_buf+="$table_row"
    else
        print -v table_row -f "${TABLE_BRDR_COLOR}╭──│ %s ${TABLE_BRDR_COLOR}│╮\n" "$header_txt"
        table_buf+="$table_row"
        print -v table_row -f "${TABLE_BRDR_COLOR}│  ╰─%s─╯│\n" "$header_top_bot"
        table_buf+="$table_row"
    fi

    # Table rows
    for ((i=argindex_stats; i<=$#; i+=2)); do
        local col1_text=$argv[$i]
        local col2_text=$argv[$((i + 1))]
        render_table_row "$col1_text" "$col2_text" "$col1_width_adjstd" table_row
        table_buf+="$table_row"
    done

    for ln in "${(f)table_buf}"; do
        my_tput_cup $ypos $xpos
        print -n "$ln";     ((ypos++)); ((total_height++))
        if ((total_height >= max_height)); then break; fi
    done

    # Bottom border
    my_tput_cup $((ypos-1)) $xpos
    if (( col1_width_adjstd < COL1_MIN_WIDTH )); then
        print -f "${TABLE_BRDR_COLOR}╰%s─%s╯" "$t1" "$t2"
    else
        print -f "${TABLE_BRDR_COLOR}╰%s┴%s╯" "$t1" "$t2"
    fi

    # after zsh 5.10+ use: out_width="$total_width"
    # after zsh 5.10+ use: out_height="$total_height"
    : ${(P)out_width::="$total_width"}
    : ${(P)out_height::="$total_height"}
    return 0
}

render_log_rows() {
    # Future optimizations: Currently we just re-render the entire log view
    # on every call. Could possibly be optimized to use DECSTBM for scrolling
    # just the log view region as new lines come in. Could also use a piped
    # secondary process of the "tail" to get the changes as they occur.
    # Another option is to cache the result of 'tail' and only do the render
    # if it (or width_total/max_rows) changes; otherwise could return a cache
    # of the render. (caching complicated by the fact that we can render
    # multiple differnet log files)
    local logfile="$1"                      # Path to the log file
    local -i width_total="$2"               # Total column width including border
    local -i max_rows="$3"                  # Max number of log rows
    local out_buf=$4   # after zsh 5.10+ use: local -n out_buf=$4

    local filename="${logfile:t}"           # :t is zsh modifier to get tail/basename
    local -i is_electrs=0
    if [[ "$filename" == "$ELECTRS_LOG_NAME" ]]; then
        is_electrs=1
    fi

    local indent="   "                      # 3-space indent for wrapped lines
    local width_txt=$((width_total - 2))    # Inside column width for text

    # Read the last $max_rows from the log file
    if [[ -f "$logfile" ]]; then
        local log_lines=("${(@f)$(tail -n "$max_rows" "$logfile")}")
    else
        local log_lines=("")
        log_lines+=("Log file not found:")
        log_lines+=("    ${logfile}")
    fi

    # Process each log line for wrapping
    local wrapped_lines=()
    for line in "${log_lines[@]}"; do
        # Electrs sometimes dumps hundreds of KB of encoded binary data to the
        # log, which can cause this loop to grind to a hault. Prevent that here
        # by truncating lines that are longer than 600 characters.
        if (( $#line > 600 )); then
            line="${line[@]:0:600}..."
        fi
        # If electrs.log then parse out the last chain height logged.
        if ((is_electrs)); then
            _process_electrs_log_line "$line"
        fi
        # Strip out any control characters (shouldn't be any).
        strip_control_chars "$line" line
        # Wrap the first line (no left padding).
        local first_line="${line[@]:0:$width_txt}"
        # Presume timestamp part starts with [ or 0-9 and goes until first space
        # character (is true for Bitcoin Core and Electrs log files). Match so
        # we can use a different color/style for timestamps.
        if [[ "$first_line" =~ ^[\[]?[0-9] ]]; then
            local space_pos="${first_line[(i) ]}"
            local timestamp="${first_line:0:$space_pos}"
            local rest_of_line="${first_line:$space_pos}"
            # Pad with spaces on right to reach width_txt
            print -v first_line -f "${VALUE_COLOR}%s${LABEL_COLOR}%-$((width_txt-space_pos))s${RESET}" "$timestamp" "$rest_of_line"
        else
            # Pad with spaces on right to reach width_txt
            print -v first_line -f "${LABEL_COLOR}%-${width_txt}s${RESET}" "$first_line"
        fi
        wrapped_lines+=(${first_line})

        # Wrap the remaining part of the line with the indent.
        local remaining_line="${line[@]:$width_txt}"
        while [[ -n "$remaining_line" ]]; do
            # Indent and pad with spaces on right to reach width_txt.
            next_line="$indent${remaining_line[@]:0:$((width_txt - $#indent))}"
            print -v next_line -f "${LABEL_COLOR}%-${width_txt}s" "$next_line"
            wrapped_lines+=($next_line)
            # Continue processing the remaining text until finished.
            remaining_line="${remaining_line[@]:$(($width_txt - $#indent))}"
        done
    done

    # Calculate the starting index to show the last max_rows lines.
    local total_rows=$#wrapped_lines
    local start_idx=$((total_rows - max_rows + 1))      # zsh arrays start at 1
    (( start_idx < 1 )) && start_idx=1                  # don't go less than 1 in zsh arrays

    # Render all the wrapped and truncated lines to $log_buf
    local lines_printed=0
    local log_buf="" ln=""
    for ((i = start_idx; i <= total_rows; i++)); do
        print -v ln -f "${TABLE_BRDR_COLOR}│ %s ${TABLE_BRDR_COLOR}│\n" \
            "${wrapped_lines[i]}"
        log_buf+="$ln"
        ((lines_printed++))
    done

    # Remaining rows are filled with empty lines (log file only has a few lines).
    while ((lines_printed < max_rows)); do
        print -v ln -f "${TABLE_BRDR_COLOR}│ %-${width_txt}s │\n" ""
        log_buf+="$ln"
        ((lines_printed++))
    done

    # after zsh 5.10+ use: out_buf+="$row"
    : ${(P)out_buf::="$log_buf"}
    return 0
}

_process_electrs_log_line() {
    local line=$1
    if [[ "$line" == *"chain updated"* && "$line" == *"height="* ]]; then
        local height_part="${line##*height=}"
        ELECTRS_CHAIN_HEIGHT="${height_part%%[^0-9]*}"
    fi
}

process_log_file() {
    local -i parse_line_count=$1
    local logfile=$2
    if [[ ! -f "$logfile" ]]; then
        return 0
    fi
    local filename="${logfile:t}" # :t is zsh modifier to get tail/basename
    if [[ "$filename" == "$ELECTRS_LOG_NAME" ]]; then
        # Read and process last $parse_line_count lines from the log file
        local log_lines=("${(@f)$(tail -n "$parse_line_count" "$logfile")}")
        for line in "${log_lines[@]}"; do
            _process_electrs_log_line "$line"
        done
    fi
    return 0
}

draw_log_file() {
    local -i xpos=$1
    local -i ypos=$2
    local -i view_width=$3
    local -i view_height=$4
    local header_prefix=$5
    local filepath=$6
    local filename="${filepath:t}"  # :t is zsh modifier to get tail/basename
    local -i width=$((view_width - 3))
    local -i row_count=$((view_height - 4))

    # Sanity check to avoid negative rendering values.
    if (( view_width < 12 || view_height < 5 )); then
        process_log_file 10 "$filepath"
        return 0  # Too narrow to be useful for rendering table; bail out.
    fi

    # Top Border with filename
    local table_buf="" table_row=""
    local header_txt="${header_prefix} ${filename}"
    local title_color
    if [[ -f "$filepath" ]]; then
        title_color=$TITLE_COLOR
    else
        title_color=$TITLE_COLOR_ERR
    fi
    print -v header_txt -f "${BOLD}${title_color}${header_txt}${UNBOLD}"
    local -i header_len=0;  stripped_len "true" "$header_txt" header_len
    local header_top_bot=${(l:$header_len::─:):""}
    local header_rt_padding_len=$((width - header_len - 6))
    local header_rt_padding=""
    if ((header_rt_padding_len > 0)); then
        header_rt_padding=${(l:$header_rt_padding_len::─:):""}
    fi
    print -v table_row -f "${TABLE_BRDR_COLOR}   ╭─%s─╮%*s \n" "$header_top_bot" "$header_rt_padding_len" ""
    table_buf+="$table_row"
    print -v table_row -f "${TABLE_BRDR_COLOR}╭──│ %s ${TABLE_BRDR_COLOR}│%s╮\n" "$header_txt" "$header_rt_padding"
    table_buf+="$table_row"
    print -v table_row -f "${TABLE_BRDR_COLOR}│  ╰─%s─╯%*s│\n" "$header_top_bot" "$header_rt_padding_len" ""
    table_buf+="$table_row"

    # Log rows
    local log_rows=""
    render_log_rows "$filepath" $width $row_count log_rows
    table_buf+="$log_rows"

    # Bottom border
    local bot_brder=${(l:$width::─:):""}
    print -v table_row -f "${TABLE_BRDR_COLOR}╰%s╯" "$bot_brder"
    table_buf+="$table_row"

    for ln in "${(f)table_buf}"; do
        my_tput_cup $ypos $xpos
        print -n "$ln";     ((ypos++))
    done
}

########################################
typeset -i RESIZE_PENDING=0
trap 'RESIZE_PENDING=1' WINCH

typeset -i NEED_CLEANUP=0
typeset SAVED_STTY=""
cleanup_term_settings() {
    (( NEED_CLEANUP )) && {
        my_tput_cnorm                   # show cursor
        my_tput_smam                    # re-enable auto-wrapping of lines
        my_tput_rmcup                   # restore alt screen
        printf "$OSC0_FRMT" ""          # clear window title
        [[ -n $SAVED_STTY ]] && stty "$SAVED_STTY" 2>/dev/null  # restore original stty settings
        SAVED_STTY=""
    }
    NEED_CLEANUP=0
}
TRAPHUP()  { cleanup_term_settings; exit 129; }
TRAPINT()  { cleanup_term_settings; exit 130; }   # Ctrl-C
TRAPQUIT() { cleanup_term_settings; exit 131; }
TRAPTERM() { cleanup_term_settings; exit 143; }   # Killed (default)
TRAPEXIT() { cleanup_term_settings; }             # Graceful exit

init_term_settings() {
    SAVED_STTY=$(stty -g)
    stty -echo  # not needed to (but could) set: -icanon -ixon -ixoff min 0 time 0
    printf "$OSC0_FRMT" "Node Monitor"  # set the window title
    my_tput_smcup                       # start alt screen
    my_tput_rmam                        # disable auto-wrapping of lines
    my_tput_civis                       # hide cursor
    my_tput_clear                       # clear screen
    NEED_CLEANUP=1
}

handle_interactive_keys() {
    local read_timeout=$(( DEBUG_SHOW ? 0.0 : SLEEP_INTERVAL))
    local key=""
    if read -k 1 -s -t "$read_timeout" key; then
        case "$key" in
        [qQ])       # Q: Exit
            exit 0
            ;;
        [dD])       # D: Toggle debug view
            (( DEBUG_SHOW = !DEBUG_SHOW ))
            my_tput_clear
            ;;
        [bB])       # B: Start/stop bitcoind
            if [[ -f "$BTC_START_SH" && -f "$BTC_STOP_SH" ]]; then
                my_tput_clear
                if [[ -z "$BTC_PROCESS_PID" ]] || ! kill -0 "$BTC_PROCESS_PID" 2>/dev/null; then
                    $BTC_START_SH
                else
                    $BTC_STOP_SH
                fi
                my_sleep 1; my_tput_clear
            fi
            ;;
        [eE])       # E: Start/stop electrs
            if (( ELECTRS_ENABLED )) && [[ -f "$ELECTRS_START_SH" && -f "$ELECTRS_STOP_SH" ]]; then
                my_tput_clear
                if [[ -z "$ELECTRS_PROCESS_PID" ]] || ! kill -0 "$ELECTRS_PROCESS_PID" 2>/dev/null; then
                    $ELECTRS_START_SH
                else
                    $ELECTRS_STOP_SH
                fi
                my_sleep 1; my_tput_clear
            fi
            ;;
        esac
    fi
}

########################################
show_usage() {
    local script_name=$1
    cat <<EOF
$script_name (v$NODE_MONITOR_VERSION) - Realtime monitoring dashboard for Bitcoin node and Electrs Electrum server.

USAGE: $script_name [-h] [-v] [-d]

OPTIONS:
    -h, --help          Show this help message.
    -v, --version       Show version information.
    -d, --debug         Enable debug mode (show additional debug and timing information).

INTERACTIVE COMMANDS / KEYS:
    B                   Start/stop the Bitcoin node daemon (if installed).
    E                   Start/stop the Electrs Electrum daemon (if installed).
    D                   Toggle debug view on/off.
    Q                   Quit the monitor.
EOF
}

########################################
run_dashboard() {
    setopt localoptions extendedglob
    local -i debug_loop_index=0
    local -i debug_loop_count=20
    local -F debug_loop_ts_start=$EPOCHREALTIME
    local debug_loop_ts_delta_str=""--""
    local secondary_exists=ELECTRS_ENABLED
    while true; do
        # ───── FETCH PIDs ─────
        # Optimization: "pgrep" is slow, so only call when needed (pid isn't valid/running):
        if [[ -z "$BTC_PROCESS_PID" ]] || ! kill -0 "$BTC_PROCESS_PID" 2>/dev/null; then
            BTC_PROCESS_PID=$(pgrep "$BTC_PROCESS_NAME")
        fi
        if (( ELECTRS_ENABLED )); then
            if [[ -z "$ELECTRS_PROCESS_PID" ]] || ! kill -0 "$ELECTRS_PROCESS_PID" 2>/dev/null; then
                ELECTRS_PROCESS_PID=$(pgrep "$ELECTRS_PROCESS_NAME")
            fi
        fi

        # ───── FETCH BITCOIN JSON DATA ─────
        $FETCH_JSON_FUNC

        # ───── PARSE BLOCKCHAIN DATA ─────
        if (( NODE_RUNNING )) && [[ -n "${BTC_BLOCKINFO_JSON:+x}" ]]; then
            if (( BTC_BLOCKINFO_NEED_PARSE )); then
                BTC_BLOCKINFO_NEED_PARSE=0
                local block_info=($(jq -r '
                        .initialblockdownload,
                        .chain,
                        .blocks,
                        .headers,
                        (.verificationprogress * 100)
                    ' <<< "$BTC_BLOCKINFO_JSON"))
                WAITING_ON_IBD=$block_info[1]
                local btc_chain=$block_info[2]
                local blocks_processed=$block_info[3]
                local block_headers_seen=$block_info[4]  # also used in Electrs stats later
                local progress_float=$block_info[5]
                print -v blocks_processed -f "%'d" "$blocks_processed"; text_bold "$blocks_processed" blocks_processed
                print -v headers_seen -f "%'d" "$block_headers_seen";   text_bold "$headers_seen" headers_seen
                local sync_progress_txt=""
                text_center_pad "((PB_WIDTH+4))" "false" "$blocks_processed / $headers_seen" sync_progress_txt

                # ───── BLOCK SYNC PROGRESS BAR ─────
                local sync_progress_bar=""
                calc_block_sync_progress_ui $blocks_processed $headers_seen $progress_float sync_progress_bar
            fi
        else
            WAITING_ON_IBD="false"
            local btc_chain=""
            local blocks_processed="--"
            local headers_seen="--"
            local -i block_headers_seen=0
            local sync_progress_txt=""
            text_center_pad "((PB_WIDTH+4))" "false" "$blocks_processed / $headers_seen" sync_progress_txt

            local sync_progress_bar=""
            calc_block_sync_progress_ui 0 0 0.0 sync_progress_bar
        fi

        # ───── NETWORK INFO ─────
        if (( NODE_RUNNING )) && [[ -n "${BTC_NETINFO_JSON:+x}" ]]; then
            if (( BTC_NETINFO_NEED_PARSE )); then
                BTC_NETINFO_NEED_PARSE=0
                local netinfo=($(jq -r '
                        (.subversion | gsub("^/|/$"; "")),
                        .connections,
                        .connections_in,
                        .connections_out,
                        (.networks[] | select(.name=="ipv4") | .reachable // "false"),
                        (.networks[] | select(.name=="ipv6") | .reachable // "false"),
                        (.networks[] | select(.name=="onion") | .reachable // "false"),
                        (.networks[] | select(.name=="i2p") | .reachable // "false"),
                        (.networks[] | select(.name=="cjdns") | .reachable // "false"),
                        (.localaddresses[]? | select(.address | endswith(".onion")) | .address) // "none"
                    ' <<< "$BTC_NETINFO_JSON"))
                local btc_vers=$netinfo[1]
                local peers_connected=$netinfo[2]
                local peers_inbound=$netinfo[3]
                local peers_outbound=$netinfo[4]
                local ipv4_reachable=$netinfo[5]
                local ipv6_reachable=$netinfo[6]
                local tor_reachable=$netinfo[7]
                local i2p_reachable=$netinfo[8]
                local cjdns_reachable=$netinfo[9]
                local tor_addr=$netinfo[10]
                if [[ -n "$tor_addr" && "$tor_addr" != "none" ]]; then
                    tor_addr=${tor_addr%%$'\n'*}
                else
                    tor_addr=""
                fi

                text_bold "$peers_connected" peers_connected
                local peers_reachable=""
                if [[ $ipv4_reachable == "true" ]]; then
                    peers_reachable+="IPv4  "
                fi
                if [[ $ipv6_reachable == "true" ]]; then
                    peers_reachable+="IPv6  "
                fi
                if [[ $tor_reachable == "true" ]]; then
                    peers_reachable+="Tor  "
                fi
                if [[ $i2p_reachable == "true" ]]; then
                    peers_reachable+="I2P  "
                fi
                if [[ $cjdns_reachable == "true" ]]; then
                    peers_reachable+="CJDNS"
                fi
                if [[ -n $peers_reachable ]]; then
                    text_bold "$peers_reachable" peers_reachable
                else
                    peers_reachable="-- inbound connections disabled --"
                fi
            fi
        else
            local btc_vers=""
            local peers_connected="--"
            local peers_inbound="--"
            local peers_outbound="--"
            local peers_reachable="--"
            local tor_addr="--"
        fi
        if (( NODE_RUNNING )) && [[ -n "${BTC_NETTOTALS_JSON:+x}" ]]; then
            if (( BTC_NETTOTALS_NEED_PARSE )); then
                BTC_NETTOTALS_NEED_PARSE=0
                local net_totals=($(jq -r '
                        .totalbytesrecv,
                        .totalbytessent
                    ' <<< "$BTC_NETTOTALS_JSON"))
                # Could also parse out upload target info and show in a progress bar:
                #    "uploadtarget": {
                #       "timeframe": 86400,
                #       "target": 524288000,
                #       "target_reached": false,
                #       "serve_historical_blocks": false,
                #       "bytes_left_in_cycle": 519121124,
                #       "time_left_in_cycle": 82349
                #    }
                local rcvd_raw=$net_totals[1]
                local sent_raw=$net_totals[2]
                local btc_bytes_rcvd="" btc_bytes_sent=""
                format_bytes "$rcvd_raw" btc_bytes_rcvd
                format_bytes "$sent_raw" btc_bytes_sent
                text_bold "$btc_bytes_rcvd" btc_bytes_rcvd
                text_bold "$btc_bytes_sent" btc_bytes_sent
            fi
        else
            local btc_bytes_rcvd="0 B"
            local btc_bytes_sent="0 B"
        fi

        # ───── MEMPOOL INFO ─────
        if (( NODE_RUNNING )) && [[ -n "${BTC_MEMPOOLINFO_JSON:+x}" ]]; then
            if (( BTC_MEMPOOLINFO_NEED_PARSE )); then
                BTC_MEMPOOLINFO_NEED_PARSE=0
                local mempool_info=($(jq -r '
                        .size,
                        .bytes
                    ' <<< "$BTC_MEMPOOLINFO_JSON"))
                local mempool_tx=$mempool_info[1]
                local bytes_raw=$mempool_info[2]
                print -v mempool_tx -f "%'d" "$mempool_tx"; text_bold "$mempool_tx" mempool_tx
                format_bytes "$bytes_raw" mempool_bytes
            fi
        else
            local mempool_tx="--"
            local mempool_bytes="-- B"
        fi

        # ───── DISK USAGE ─────
        (( ${CALL_COUNTERS[disk_usage]:=999} >= ${CALL_INTERVALS[disk_usage]} )) && {
            CALL_COUNTERS[disk_usage]=0
            local btc_disk_progress_bar=""
            local btc_disk_progress_desc="" btc_disk_progress_ctr=""
            if [[ -d "$BTC_TARGET_PATH" ]]; then
                if (( DEBUG_BENCHMARK_FUNCS )); then
                    benchmark 'du -ks "$BTC_TARGET_PATH" &>/dev/null'
                    benchmark 'df -kP "$BTC_TARGET_PATH" &>/dev/null'
                    benchmark 'process_uptime "$BTC_PROCESS_PID" &>/dev/null'
                    benchmark 'process_cpu_load "$BTC_PROCESS_PID" &>/dev/null'
                    benchmark 'process_rss_memory "$BTC_PROCESS_PID" &>/dev/null'
                    benchmark 'process_footprint_memory "$BTC_PROCESS_PID" &>/dev/null'
                    exit 1
                fi
                calc_disc_usage_progress_ui "$BTC_TARGET_PATH" "bitcoin" btc_disk_progress_bar btc_disk_progress_desc
            else
                calc_disc_usage_progress_ui "" "bitcoin" btc_disk_progress_bar btc_disk_progress_desc
            fi
            text_center_pad "((COL2_WIDTH))" "false" "$btc_disk_progress_desc" btc_disk_progress_ctr

            local electrs_disk_progress_bar=""
            local electrs_disk_progress_desc="" electrs_disk_progress_ctr=""
            if (( ELECTRS_ENABLED )); then
                if [[ -d "$ELECTRS_TARGET_PATH/db" ]]; then
                    calc_disc_usage_progress_ui "$ELECTRS_TARGET_PATH" "electrs" electrs_disk_progress_bar electrs_disk_progress_desc
                else
                    calc_disc_usage_progress_ui "" "electrs" electrs_disk_progress_bar electrs_disk_progress_desc
                fi
                text_center_pad "((COL2_WIDTH))" "false" "$electrs_disk_progress_desc" electrs_disk_progress_ctr
            fi
        }
        (( CALL_COUNTERS[disk_usage]++ ))

        # ───── CPU AND MEMORY USAGE ─────
        (( ${CALL_COUNTERS[cpu_usage]:=999} >= ${CALL_INTERVALS[cpu_usage]} )) && {
            CALL_COUNTERS[cpu_usage]=0
            local btc_uptime="" btc_cpu_load=""
            process_uptime "$BTC_PROCESS_PID" btc_uptime
            text_bold "$btc_uptime" btc_uptime
            process_cpu_load "$BTC_PROCESS_PID" btc_cpu_load
            local btc_cpu_adjstd=$((btc_cpu_load / CORE_COUNT))
            print -v btc_cpu_load -f "%.1f%%" "$btc_cpu_load";  text_bold "$btc_cpu_load" btc_cpu_load
            print -v btc_cpu_adjstd -f  "%.1f%%" "$btc_cpu_adjstd"
            if (( ELECTRS_ENABLED )); then
                local electrs_uptime="" electrs_cpu_load=""
                process_uptime "$ELECTRS_PROCESS_PID" electrs_uptime
                text_bold "$electrs_uptime" electrs_uptime
                process_cpu_load "$ELECTRS_PROCESS_PID" electrs_cpu_load
                local electrs_cpu_adjstd=$((electrs_cpu_load / CORE_COUNT))
                print -v electrs_cpu_load -f "%.1f%%" "$electrs_cpu_load";   text_bold "$electrs_cpu_load" electrs_cpu_load
                print -v electrs_cpu_adjstd -f "%.1f%%" "$electrs_cpu_adjstd"
            fi
        }
        (( CALL_COUNTERS[cpu_usage]++ ))
        (( ${CALL_COUNTERS[mem_usage]:=999} >= ${CALL_INTERVALS[mem_usage]} )) && {
            CALL_COUNTERS[mem_usage]=0
            local btc_mem_rss="" btc_mem_ftprnt=""
            process_rss_memory "$BTC_PROCESS_PID" btc_mem_rss
            process_footprint_memory "$BTC_PROCESS_PID" btc_mem_ftprnt
            text_bold "$btc_mem_ftprnt" btc_mem_ftprnt
            if (( ELECTRS_ENABLED )); then
                local electrs_mem_rss="" electrs_mem_ftprnt=""
                process_rss_memory "$ELECTRS_PROCESS_PID" electrs_mem_rss
                process_footprint_memory "$ELECTRS_PROCESS_PID" electrs_mem_ftprnt
                text_bold "$electrs_mem_ftprnt" electrs_mem_ftprnt
            fi
        }
        (( CALL_COUNTERS[mem_usage]++ ))

        if (( NODE_RUNNING )); then
            local title_color=$TITLE_COLOR
            local title_status="✅ Bitcoin Node"
            if [[ -n $btc_vers ]]; then
                title_status+=" $btc_vers"
            fi
            title_status+=" running"
            if [[ -n $btc_chain ]]; then
                title_status+=" on $btc_chain chain"
            fi
        elif [[ ! -d "$BTC_TARGET_PATH" ]]; then
            local title_color=$TITLE_COLOR_ERR
            local title_status="❌ Bitcoin Node not installed"
        else
            local title_color=$TITLE_COLOR_ERR
            local title_status="❌ Bitcoin Node not running – press 'B' to start"
        fi

        ##############################
        my_start_buffered_update
        (( RESIZE_PENDING )) && {
            my_tput_clear
            my_get_term_width TERM_WIDTH; my_get_term_height TERM_HEIGHT
            RESIZE_PENDING=0
        }

        local json_err_trunc="$FETCH_JSON_ERROR"
        local tor_addr_trunc="$tor_addr"
        text_trunc "((COL2_WIDTH))" "false" "$json_err_trunc" json_err_trunc
        text_trunc "((COL2_WIDTH))" "false" "$tor_addr_trunc" tor_addr_trunc

        local -i ypos=0
        local -i xpos_stats=1
        local -i stats_maxwidth=$((TERM_WIDTH - xpos_stats))
        local -i stats_maxheight=$((TERM_HEIGHT - ypos))
        local -i table_width=0 table_height=0

        local -i log_views_visible=$((TERM_WIDTH > xpos_stats + STATS_VIEW_WIDTH + LOGVIEW_MIN_WIDTH + 1))
        if (( !log_views_visible && TERM_WIDTH > xpos_stats + STATS_VIEW_WIDTH )); then
            # Not enough space for the log view tables, but more than enough for the stat
            # views so add some padding to center them.
            ((xpos_stats += (TERM_WIDTH - xpos_stats - STATS_VIEW_WIDTH) / 2))
        fi

        draw_stats_table $xpos_stats $ypos $stats_maxwidth $stats_maxheight "$title_color" "$title_status" table_width table_height \
            "Reachable Via"             "$peers_reachable" \
            "Peers Connected"           "$peers_connected ($peers_inbound inbound + $peers_outbound outbound)" \
            "Mempool Txs"               "$mempool_tx ($mempool_bytes)" \
            "Blocks Verified"           "$sync_progress_bar" \
            ""                          "$sync_progress_txt" \
            ""                          "" \
            "Process Uptime"            "$btc_uptime" \
            "CPU Load"                  "$btc_cpu_load ($btc_cpu_adjstd of $CORE_COUNT cores)" \
            "Network I/O"               "$btc_bytes_rcvd ↓RX    $btc_bytes_sent ↑TX" \
            "Memory Footprint"          "$btc_mem_ftprnt ($btc_mem_rss RSS)" \
            "Disk Usage"                "$btc_disk_progress_bar" \
            ""                          "$btc_disk_progress_ctr"

        local -i xpos_log=$((xpos_stats + table_width + 1))
        local -i ypos_next=$((ypos + table_height))
        # Only render secondary stats/log views (Electrs, etc.) If after rendering
        # the main bitcoind stats/log views there is at least a height of 9 left.
        local -i secondary_visible=$((secondary_exists && TERM_HEIGHT >= ypos_next + SECONDARY_MIN_HEIGHT))
        if (( log_views_visible )); then
            local -i log_width=$((TERM_WIDTH - xpos_log))
            if (( DEBUG_SHOW )); then
                local -i log_height=table_height
            elif (( secondary_visible )); then
                # Prefer to give the secondary log a height of SECONDARY_PREFERRED_HEIGHT,
                # after which point let the main log_height (calc'd here) grow to expand
                # the leftover vertical space.
                local -i log_height=$((TERM_HEIGHT - SECONDARY_PREFERRED_HEIGHT))
                ((log_height < table_height)) && log_height=$table_height
                ypos_next=$((ypos + log_height))
            else
                local -i log_height=TERM_HEIGHT
            fi
            draw_log_file $xpos_log $ypos $log_width $log_height "🧾 Bitcoin Node" "$BTC_LOG_PATH"
        else
            process_log_file 10 "$BTC_LOG_PATH"
        fi

        if (( secondary_visible )); then
            if (( ELECTRS_ENABLED )); then
                if [[ -n "$ELECTRS_PROCESS_PID" ]] && kill -0 "$ELECTRS_PROCESS_PID" 2>/dev/null; then
                    # (note calling "kill -0" above is way faster than using "ps -p")
                    local title_color=$TITLE_COLOR
                    local title_status="✅ Electrs Server running"
                elif [[ ! -d "$ELECTRS_TARGET_PATH" ]]; then
                    local title_color=$TITLE_COLOR_ERR
                    local title_status="❌ Electrs Server not installed"
                    ELECTRS_CHAIN_HEIGHT="--"
                else
                    local title_color=$TITLE_COLOR_ERR
                    local title_status="❌ Electrs Server not running – press 'E' to start"
                    ELECTRS_CHAIN_HEIGHT="--"
                fi
                local blocks_indexed="$ELECTRS_CHAIN_HEIGHT"
                if (( block_headers_seen != 0 )) && [[ $blocks_indexed == (|[+-])<-> ]]; then
                    local progress_float=$(( blocks_indexed * 100.0 / block_headers_seen ))
                    print -v blocks_indexed -f "%'d" "$blocks_indexed";     text_bold "$blocks_indexed" blocks_indexed
                    print -v headers_seen -f "%'d" "$block_headers_seen";   text_bold "$headers_seen" headers_seen
                    local index_progress_txt=""
                    text_center_pad "((PB_WIDTH+4))" "false" "$blocks_indexed / $headers_seen" index_progress_txt

                    # ───── BLOCK INDEX PROGRESS BAR ─────
                    local index_progress_bar=""
                    calc_block_sync_progress_ui $blocks_indexed $headers_seen $progress_float index_progress_bar
                else
                    local blocks_indexed="--"
                    local headers_seen="--"
                    if (( block_headers_seen != 0 )); then
                        print -v headers_seen -f "%'d" "$block_headers_seen";   text_bold "$headers_seen" headers_seen
                    fi
                    local index_progress_txt=""
                    text_center_pad "((PB_WIDTH+4))" "false" "$blocks_indexed / $headers_seen" index_progress_txt

                    local index_progress_bar=""
                    calc_block_sync_progress_ui 0 0 0.0 index_progress_bar
                fi

                local -i stats_maxwidth=$((TERM_WIDTH - xpos_stats))
                local -i stats_maxheight=$((TERM_HEIGHT - ypos_next))
                draw_stats_table $xpos_stats $ypos_next $stats_maxwidth $stats_maxheight "$title_color" "$title_status" table_width table_height \
                    "Blocks Indexed"            "$index_progress_bar" \
                    ""                          "$index_progress_txt" \
                    ""                          "" \
                    "Process Uptime"            "$electrs_uptime" \
                    "CPU Load"                  "$electrs_cpu_load ($electrs_cpu_adjstd of $CORE_COUNT cores)" \
                    "Memory Footprint"          "$electrs_mem_ftprnt ($electrs_mem_rss RSS)" \
                    "Disk Usage"                "$electrs_disk_progress_bar" \
                    ""                          "$electrs_disk_progress_ctr"

                if (( log_views_visible )); then
                    local -i log_width=$((TERM_WIDTH - xpos_log))
                    if (( DEBUG_SHOW )); then
                        local -i log_height=table_height
                    else
                        local -i log_height=$((TERM_HEIGHT - ypos_next))
                    fi
                    draw_log_file $xpos_log $ypos_next $log_width $log_height "🧾 Electrs Server" "$ELECTRS_LOG_PATH"
                else
                    process_log_file 10 "$ELECTRS_LOG_PATH"
                fi
                ypos_next=$((ypos_next + table_height))
            fi
        fi

        if (( DEBUG_SHOW && TERM_HEIGHT >= ypos_next + DEBUG_MIN_HEIGHT )); then
            (( debug_loop_index++ ))
            if (( debug_loop_index >= debug_loop_count )); then
                debug_loop_index=0
                print -v debug_loop_ts_delta_str -f "%.4fs per %d iterations" $((EPOCHREALTIME - debug_loop_ts_start)) $debug_loop_count
                debug_loop_ts_start=$EPOCHREALTIME
            fi
            local -i stats_maxwidth=$((TERM_WIDTH - xpos_stats))
            local -i stats_maxheight=$((TERM_HEIGHT - ypos_next))
            draw_stats_table $xpos_stats $ypos_next $stats_maxwidth $stats_maxheight "$TITLE_COLOR" "Debug Info" table_width table_height \
                "tor_addr"                  "$tor_addr_trunc" \
                "loop time delta"           "$debug_loop_ts_delta_str" \
                "FETCH_JSON_ERROR"          "$json_err_trunc" \
                "BTC_CLI_PID"               "$BTC_CLI_PID" \
                "BTC_CLI_CURCMD"            "$BTC_CLI_CURCMD" \
                "WAITING_ON_IBD"            "$WAITING_ON_IBD" \
                "CC[mem_usage]"             "$CALL_COUNTERS[mem_usage]" \
                "CC[cpu_usage]"             "$CALL_COUNTERS[cpu_usage]" \
                "CC[disk_usage]"            "$CALL_COUNTERS[disk_usage]"
            ypos_next=$((ypos_next + table_height))
        fi

        my_end_buffered_update
        handle_interactive_keys
    done
}

while [[ $# -gt 0 ]]; do
    case $1 in
    -h|--help)
        show_usage "${0:t}"
        exit 0
        ;;
    -d|--debug)
        DEBUG_SHOW=1
        shift
        ;;
    -v|--version)
        echo "Bitcoin Mac Node Monitor v$NODE_MONITOR_VERSION"
        exit 0
        ;;
    -*)
        print_error "Error: Unknown option '$1'"
        echo "Use '${0:t} --help' for usage information."
        exit 1
        ;;
    *)
        print_error "Error: Unexpected argument '$1'"
        echo "Use '${0:t} --help' for usage information."
        exit 1
        ;;
    esac
done

init_term_settings
run_dashboard
exit 0
