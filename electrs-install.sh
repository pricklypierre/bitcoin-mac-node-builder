#!/bin/zsh
#
# Amor et tolerantia erga omnes oppressos.
#

emulate -L zsh

###############################################################################
# All files are installed into the path specified by electrs_server[target_path]
# inside global_config.yaml. Layout of this directory is shown below.
#
# Source files used for building:
#
#   TARGET_PATH/electrs-repo/
#
# Binaries are then copied from those repo directory, along with some
# helper scripts, into:
#
#   TARGET_PATH/bin/
#
# Configuration file (based on global_config.yaml settings) is generated into:
#
#   TARGET_PATH/config.toml
#
# On launch Electrs then creates its database/indexing files inside:
#
#   TARGET_PATH/db
#
###############################################################################

########################################
REPOT_DIR_NAME="electrs-repo"

LAUNCHCTRL_SERVICE="org.electrs"
LAUNCHCTRL_PLIST="$HOME/Library/LaunchAgents/${LAUNCHCTRL_SERVICE}.plist"

ELECTRS_LOG_NAME="electrs.log"

LAUNCHD_HELPER_STARTER_NAME="start-electrs"

BITCOIND_PROCESS_NAME="bitcoind"

typeset -i CLEAN_INSTALL=0
typeset -i FAST_INSTALL=0
typeset -i UNINSTALL=0
# By default uninstalling keeps the Electrs db directory because re-indexing
# its database can be slow. The uninstall process instead directs the users
# to manually delete that directory (or use flag -uu) if they really want
# to nuke everything.
typeset -i PREVENT_DB_UNINSTALL=1

########################################
# Parse the settings out of global_config.yaml into $ELECTRS_SERVER_CONFIG.
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
show_usage() {
    local script_name=$1
    cat <<EOF
$script_name (v$NODE_BUILDER_VERSION) - Installs Electrs Electrum Server. For configuring download/build options edit $CONFIG_FILENAME file.

USAGE: $script_name [-h] [-v] [-c] [-f] [-u]

OPTIONS:
    -h, --help          Show this help message.
    -v, --version       Show version information.
    -c                  Clean install. Forces fresh download and complete rebuild.
    -f                  Fast install only source and config changes. Skips dependency and startup checks. A complete build must be done initially to install dependencies.
    -u                  Uninstall Electrs Electrum Server but leaves 'db' data directory.
    -uu                 Uninstall Electrs Electrum Server including all data directories.

CONFIGURATION FILE:
    $CONFIG_FILENAME
EOF
}

########################################
generate_readme() {
    cat > "$TARGET_PATH/README.md" <<EOF
# Bitcoin Mac Node Builder

## Electrs Electrum Server Installed

Electrs was installed using the Bitcoin Mac Node Builder ([available on Github](https://github.com/pricklypierre/bitcoin-mac-node-builder)) into:

&nbsp;&nbsp;&nbsp;&nbsp;**$TARGET_PATH/**

Electrs is configured as a launchd service to automatically start on macOS user login after bitcoind starts, and will be automatically restarted after crashes.

## Start/Stop Electrs using the installed helper scripts:

\`\`\`shell
cd "$TARGET_PATH/bin"
./start.sh
./stop.sh
\`\`\`

## Monitor the server status and its log file with the node-monitor.sh dashboard:

\`\`\`shell
cd "$SCRIPT_DIR"
./node-monitor.sh
\`\`\`

## To uninstall Electrs:

\`\`\`shell
cd "$SCRIPT_DIR"
./electrs-install.sh -u
\`\`\`
EOF
    # macOS doesn't support markdown in Quickview or TextEdit so convert to RTF.
    glow -w 90 "$TARGET_PATH/README.md" || return $?
    return 0
}

########################################
# Exits script on any fatal install or configure errors.
install_main_dependencies() {
    echo
    print_info_bold "Checking required system packages for installing..."

    my_brew_prep
    my_brew_install_withlog "$BUILD_LOGS_DIR/electrs-brew-install.log" \
        coreutils \
        glow \
    || exit $?
    return 0
}

# Exits script on any fatal install or configure errors.
install_build_dependencies() {
    echo
    print_info_bold "Checking required system packages for building..."

    if ((1)); then
        # Much simpler rust install is to just use brew.
        my_brew_install_withlog "$BUILD_LOGS_DIR/electrs-brew-install.log" \
            rust \
        || exit $?
    else
        # Previous technique that manually installed rustup.
        if [[ -f "$HOME/.cargo/env" ]]; then
            # Need to source .cargo/env for cargo/rustc/etc to be available.
            . "$HOME/.cargo/env"
        fi
        if ! program_exists "rustup"; then
            # Install rust for building Electrs.
            curl --tlsv1.2 -sSf --proto '=https' https://sh.rustup.rs | sh -s -- -y
            . "$HOME/.cargo/env"
        else
            exec_with_popview \
                "Running rustup update..." \
                "" \
                rustup update \
            || exit $?
        fi
    fi

    my_brew_install_withlog "$BUILD_LOGS_DIR/electrs-brew-install.log" \
        rocksdb \
    || exit $?
    my_brew_cleanup  # intentional non-fatal if failure
    return 0
}

########################################
# Exits script on any fatal build or configure errors.
build_electrs() {
    cd "$TARGET_PATH" || exit $?

    if (( CLEAN_INSTALL )) && [[ -d "$REPOT_DIR_NAME" ]]; then
        echo
        print_info_bold "Performing clean install (deleting existing build)..."
        rm -rf "$REPOT_DIR_NAME"        || { print_error "rm $REPOT_DIR_NAME failed"; exit 1; }
    fi
    if [[ ! -d "$REPOT_DIR_NAME" ]]; then
        echo
        print_info_bold "Downloading Electrs source files (git clone)..."
        mkdir -p "$REPOT_DIR_NAME"      || { print_error "mkdir $REPOT_DIR_NAME failed"; exit 1; }
        cd "$REPOT_DIR_NAME"            || { print_error "cd $REPOT_DIR_NAME failed"; exit 1; }
        local -i success=1
        exec_with_popview \
            "Running git clone..." \
            "$BUILD_LOGS_DIR/electrs-git-commands.log" \
            git clone "$1" "$(pwd)" \
        || success=0
        if (( ! success )); then
            print_error "Git clone failed."
            cd "$TARGET_PATH" || exit $?
            rm -rf "$REPOT_DIR_NAME"  # Remove to force a git clone/checkout on next run.
            exit 1
        fi
        exec_with_popview \
            "Running git checkout..." \
            "$BUILD_LOGS_DIR/electrs-git-commands.log" \
            git checkout -b "my-branch" origin/master \
        || success=0
        if (( ! success )); then
            print_error "Git checkout failed."
            cd "$TARGET_PATH" || exit $?
            rm -rf "$REPOT_DIR_NAME"  # Remove to force a git clone/checkout on next run.
            exit 1
        fi
    else
        echo
        print_info_bold "Downloading Electrs changes (git pull)..."
        cd "$REPOT_DIR_NAME"            || { print_error "cd $REPOT_DIR_NAME failed"; exit 1; }
        local -i success=1
        exec_with_popview \
            "Running git pull..." \
            "$BUILD_LOGS_DIR/electrs-git-commands.log" \
            git pull \
        || success=0
        if (( ! success )); then
            print_error "Git pull failed."
            exit 1
        fi
    fi

    echo
    print_info_bold "Building Electrs via cargo..."
    setopt null_glob
    rm -rf "$TARGET_PATH/bin/"*
    rm -f target/release/electrs target/release/electrs.d
    unsetopt null_glob

    local -i success=1
    # Cargo build has a hard time finding libclang.dylib without setting DYLD_FALLBACK_LIBRARY_PATH.
    DYLD_FALLBACK_LIBRARY_PATH="$(xcode-select --print-path)/usr/lib/"
    if [[ ! -f "$DYLD_FALLBACK_LIBRARY_PATH/libclang.dylib" ]]; then
        DYLD_FALLBACK_LIBRARY_PATH="$(xcode-select --print-path)/Toolchains/XcodeDefault.xctoolchain/usr/lib/"
    fi
    if [[ ! -f "$DYLD_FALLBACK_LIBRARY_PATH/libclang.dylib" ]]; then
        print_warning "Warning: libclang.dylib not found ($DYLD_FALLBACK_LIBRARY_PATH/libclang.dylib)"
        print_warning "(cargo build will likely fail but trying regardless)"
    fi
    export DYLD_FALLBACK_LIBRARY_PATH
    if ((0)); then
        # If we need to do cargo clean or cargo update in the future:
        exec_with_popview \
            "Running cargo clean..." \
            "" \
            cargo clean \
        || success=0
        if (( success )); then
            exec_with_popview \
                "Running cargo update..." \
                "" \
                cargo update \
            || success=0
        fi
    fi
    if (( success )); then
        export RUSTFLAGS="-A unused-attributes"
        exec_with_popview \
            "Running cargo build..." \
            "$BUILD_LOGS_DIR/electrs-cargo-build.log" \
            cargo build --locked --release \
        || success=0
    fi
    if (( success )) && [[ -f "target/release/electrs" ]]; then
        print_success "Build logs available in: $BUILD_LOGS_DIR"
        return 0
    fi
    print_error "Build failed. See build logs in:"
    echo
    print_error "   $BUILD_LOGS_DIR"
    exit 1
}

########################################
# Exits script on any fatal install or configure errors.
install_config() {
    echo
    if [[ "$OVERRIDE_EXISTING_CONFIG_FILE" == (#i)false && -f "$TARGET_PATH/config.toml" ]]; then
        print_info_bold "Skipping generation of configuration file (already exists and generate_config_file is false)..."
        return 0
    elif [[ -f "$TARGET_PATH/config.toml" ]]; then
        print_info_bold "Generating configuration file (overriding existing)..."
    else
        print_info_bold "Generating configuration file..."
    fi

    # Construct the configuration file (config.toml).
    CONFIG_RPC_ADDR="127.0.0.1"
    CONFIG_RPC_PORT="50001"
    if [[ "${ELECTRS_SERVER_CONFIG[allow_remote_access]:-false}" == (#i)true ]]; then
        CONFIG_RPC_ADDR="0.0.0.0"
    fi

    cd "$TARGET_PATH" || exit $?
    : > "config.toml"
    cat > "config.toml" <<EOF
###################################################################################################
#                                  ** DO NOT EDIT THIS FILE **
# It was machine generated by Bitcoin Mac Node Builder and any manual edits will be overwritten the
# next time the electrs-install.sh script is executed. To change any configuration settings, edit
# the file:
#
#  ${CONFIG_FILE}
#
# And then re-run the script: ${ELECTRS_INSTALL_SH_FILE}
#
############################
db_dir = "$TARGET_PATH/db"
electrum_rpc_addr = "$CONFIG_RPC_ADDR:$CONFIG_RPC_PORT"
daemon_dir = "${BITCOIN_CORE_CONFIG[target_path]}"
cookie = "${BITCOIN_CORE_CONFIG[target_path]}/.cookie"
EOF
    if [[ -n "${ELECTRS_SERVER_CONFIG[server_banner]:-}" ]]; then
        echo "server_banner = \"${ELECTRS_SERVER_CONFIG[server_banner]}\"" >> "config.toml"
    fi
    chmod go-rw "config.toml"
    print_success "Generated: $TARGET_PATH/config.toml"
    return 0
}

# Exits script on any fatal install or configure errors.
install_launchd_plist() {
    # Construct the launchd .plist file (org.electrs.plist).
    echo
    print_info_bold "Installing launchd .plist service files..."

    # Note instead of using ProgramArguments:
    #
    #    <key>ProgramArguments</key>
    #    <array>
    #        <string>$TARGET_PATH/bin/electrs</string>
    #        <string>--conf=$TARGET_PATH/config.toml</string>
    #    </array>
    #
    # below zsh exec is used to start electrs if it exists. This is because the volume may not
    # yet be mounted and if launchd cannot find the executable to launch then it indefinitely
    # suspends the service and never tries to relaunch it (even with our KeepAlive PathState
    # settings). We bypass this problem by having launchd start a zsh script (which always exists).
    cat > "$LAUNCHCTRL_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.electrs</string>
    <key>ProgramArguments</key>
    <array>
        <string>$LAUNCHD_HELPER_DIR/$LAUNCHD_HELPER_STARTER_NAME</string>
        <string>caller_is_launchd</string>
    </array>
    <key>RunAtLoad</key>
    <true/>
    <key>KeepAlive</key>
    <dict>
        <key>PathState</key>
        <dict>
            <key>$TARGET_PATH/bin/electrs</key>
            <true/>
        </dict>
        <key>SuccessfulExit</key>
        <false/>
    </dict>
    <key>ExitTimeOut</key>
    <integer>1200</integer>
    <key>SoftResourceLimits</key>
    <dict>
      <key>NumberOfFiles</key>
      <integer>65536</integer>
    </dict>
    <key>HardResourceLimits</key>
    <dict>
      <key>NumberOfFiles</key>
      <integer>65536</integer>
    </dict>
    <key>EnvironmentVariables</key>
    <dict>
        <key>RUST_BACKTRACE</key>
        <string>1</string>
        <key>RUST_LOG</key>
        <string>info</string>
    </dict>
    <key>StandardErrorPath</key>
    <string>$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME</string>
    <key>StandardOutPath</key>
    <string>$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME</string>
</dict>
</plist>
EOF
    print_success "Installed: $LAUNCHCTRL_PLIST"

    if [[ ! -d "$LAUNCHD_HELPER_DIR" ]]; then
        mkdir -p "$LAUNCHD_HELPER_DIR" || exit $?
    fi
    cat > "$LAUNCHD_HELPER_DIR/$LAUNCHD_HELPER_STARTER_NAME" <<EOF
#!/bin/zsh

RED="$RED"; GREEN="$GREEN"; BLUE="$BLUE"; YELLOW="$YELLOW"; RESET="$RESET"

if [[ "\$1" != "caller_is_launchd" ]]; then
    printf "\${RED}This script should only be called internally by launchd. To manually start use:\${RESET}\n\n"
    printf "\${BLUE}cd \"$TARGET_PATH/bin\" && ./start.sh\${RESET}\n"
    exit 1
fi

# Loop waiting for electrs to be mounted (needed if it is on an external volume).
# Launchd will put our service in the penalty box forever if the executable
# doesn't exist (volume not mounted) so we handle this logic here ourselves.
# We also wait for bitcoind to start since electrs fails if it isn't running.
while true; do
    if pgrep -x "$BITCOIND_PROCESS_NAME" > /dev/null && \\
    [ -x "$TARGET_PATH/bin/electrs" ]; then
        sleep 3   # small sleep in case $BITCOIND_PROCESS_NAME just started
        exec "$TARGET_PATH/bin/electrs" --conf="$TARGET_PATH/config.toml"
    fi
    sleep 5
done
EOF
    chmod ug+x "$LAUNCHD_HELPER_DIR/$LAUNCHD_HELPER_STARTER_NAME"
    print_success "Installed: $LAUNCHD_HELPER_DIR/$LAUNCHD_HELPER_STARTER_NAME"
    return 0
}

# Exits script on any fatal install or configure errors.
install_helper_scripts() {
    # Construct the helper bin/start.sh and bin/stop.sh files.
    # (useful for manually starting and stopping)
    cd "$TARGET_PATH" || exit $?
    echo
    print_info_bold "Installing helper scripts..."

    cat > "bin/start.sh" <<EOF
#!/bin/sh
SERVICE="$LAUNCHCTRL_SERVICE"
PLIST="$LAUNCHCTRL_PLIST"
PROCESS_NAME="electrs"
BTCPROCESS_NAME="$BITCOIND_PROCESS_NAME"
PROCESS_PATH="$TARGET_PATH/bin/electrs"
GUI_USERID=\$(id -u)

RED="$RED"; GREEN="$GREEN"; BLUE="$BLUE"; YELLOW="$YELLOW"; RESET="$RESET"

if pgrep -x "\$PROCESS_NAME" > /dev/null; then
    printf "\${BLUE}%s is already running.\${RESET}\n" "\$PROCESS_PATH"
    exit 0
fi
if [ ! -f "\$PROCESS_PATH" ]; then
    printf "\${RED}Unable to launch %s. Executable not found.\${RESET}\n" "\$PROCESS_PATH"
    exit 1
fi
if ! pgrep -x "\$BTCPROCESS_NAME" > /dev/null; then
    printf "\${RED}Unable to launch %s. %s must first be started.\${RESET}\n" "\$PROCESS_PATH" "\$BTCPROCESS_NAME"
    exit 1
fi
# launchctl always fails if the .plist has StandardErrorPath or StandardOutPath targetting an external
# volume, which might be the case. To avoid this Apple sandbox annoyance, we'll always target the output
# to Library/Application Support/Bitcoin Mac Node Builder/electrs.log and then create a symbolic link
# in $TARGET_PATH.
if [ ! -f "$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME" ]; then
    touch "$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME"
fi
if [ ! -e "$TARGET_PATH/$ELECTRS_LOG_NAME" ]; then
    ln -s "$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME" "$TARGET_PATH/$ELECTRS_LOG_NAME"
fi

if launchctl list "\$SERVICE" &>/dev/null; then
    printf "\${YELLOW}Using launchd bootout to remove service before starting.\${RESET}\n"
    launchctl bootout gui/\$GUI_USERID "\$PLIST" &>/dev/null
fi

printf "\${BLUE}Starting %s via launchctl.\${RESET}\n" "\$PROCESS_PATH"
if ! launchctl bootstrap gui/\$GUI_USERID "\$PLIST"; then
    printf "\${RED}Launchctl bootstrap of %s failed.\${RESET}\n" "\$PROCESS_PATH"
    printf "\${RED}Attempting direct shell launch for debugging using:\${RESET}\n\n"
    ARG1="--conf=$TARGET_PATH/config.toml"
    printf "\${BLUE}RUST_BACKTRACE=1 RUST_LOG=debug \"\${PROCESS_PATH}\" \"\${ARG1}\"\${RESET}\n\n"
    RUST_BACKTRACE=1 RUST_LOG=debug "\${PROCESS_PATH}" "\${ARG1}"
    exit 1
fi

for i in \$(seq 1 16); do
    if pgrep -x "\$PROCESS_NAME" > /dev/null; then
        printf "\${GREEN}Started %s successfully.\${RESET}\n" "\$PROCESS_PATH"
        exit 0
    fi
    sleep 0.5
done

printf "\${RED}%s is not running after launchctl bootstrap attempt.\${RESET}\n" "\$PROCESS_PATH"
exit 1
EOF
    chmod ug+x "bin/start.sh"
    print_success "Installed: $TARGET_PATH/bin/start.sh"

    cat > "bin/stop.sh" <<EOF
#!/bin/sh
SERVICE="$LAUNCHCTRL_SERVICE"
PLIST="$LAUNCHCTRL_PLIST"
PROCESS_NAME="electrs"
PROCESS_PATH="$TARGET_PATH/bin/electrs"
LAUNCHD_HELPER_NAME="launchd/$LAUNCHD_HELPER_STARTER_NAME"
GUI_USERID=\$(id -u)

RED="$RED"; GREEN="$GREEN"; BLUE="$BLUE"; YELLOW="$YELLOW"; RESET="$RESET"

if launchctl list "\$SERVICE" &>/dev/null; then
    printf "\${BLUE}Stopping %s via launchctl.\${RESET}\n" "\$PROCESS_PATH"
    if ! launchctl bootout gui/\$GUI_USERID "\$PLIST"; then
        printf "\${RED}launchctl bootout of %s failed.\${RESET}\n" "\$PROCESS_PATH"
        exit 1
    fi
elif pgrep -x "\$PROCESS_NAME" > /dev/null; then
    printf "\${BLUE}Stopping %s via pkill.\${RESET}\n" "\$PROCESS_PATH"
    if ! pkill -x "\$PROCESS_NAME"; then
        printf "\${RED}pkill of %s failed.\${RESET}\n" "\$PROCESS_PATH"
        exit 1
    fi
else
    printf "\${BLUE}%s is not currently running.\${RESET}\n" "\$PROCESS_PATH"
    exit 0
fi

for i in \$(seq 1 16); do
    if ! pgrep -x "\$PROCESS_NAME" > /dev/null; then
        printf "\${GREEN}Stopped %s successfully.\${RESET}\n" "\$PROCESS_PATH"
        exit 0
    fi
    sleep 0.5
done

printf "\${RED}%s is still running after launchctl bootout and pkill attempts.\${RESET}\n" "\$PROCESS_PATH"
exit 1
EOF
    chmod ug+x "bin/stop.sh"
    print_success "Installed: $TARGET_PATH/bin/stop.sh"

    # We got far enough into the build/install process we can now set the flag
    # that allows for fast installs (-f option).
    : > "$NODE_BUILDER_APP_SUPPORT_PATH/.electrsInstallSuccessful"
    return 0
}

# Exits script on any fatal install or configure errors.
install_electrs() {
    cd "$TARGET_PATH" || exit $?
    echo
    print_info_bold "Installing Electrs from compiled binary..."

    if [[ ! -d "bin" ]]; then
        mkdir -p "bin" || exit $?
    fi

    if [[ -f "$REPOT_DIR_NAME/target/release/electrs" ]]; then
        # Install compiled binary.
        cp "$REPOT_DIR_NAME/target/release/electrs" "bin/" \
        && print_success "Installed: $TARGET_PATH/bin/electrs"
    else
        print_error "Cannot find files to install."
        exit 1
    fi
    return 0
}

########################################
# Exits script if unable to start bitcoind.
start_electrs() {
    if ! pgrep -x electrs > /dev/null; then
        local -i success=1
        exec_with_popview \
            "Starting Electrs..." \
            "" \
            "$TARGET_PATH/bin/start.sh" \
        || success=0
        if (( success )); then
            print_success "Electrs is running."
        else
            print_error "Failed to start Electrs."
            exit 1
        fi
    fi
    return 0
}

# Exits script if unable to stop bitcoind.
stop_electrs() {
    if pgrep -x electrs > /dev/null || pgrep -f "launchd/$LAUNCHD_HELPER_STARTER_NAME" > /dev/null; then
        local -i success=1
        exec_with_popview \
            "Stopping Electrs..." \
            "" \
            "$TARGET_PATH/bin/stop.sh" \
        || success=0
        if (( ! success )); then
            print_error "Failed to stop Electrs."
            exit 1
        fi
    fi
    return 0
}

########################################
# The uninstall process here is explicit about deleting installed files
# first then deleting folders once they are empty. A simpler approach
# would be to just nuke folders (and their contents), but our approach
# here explicitly specifies the known installed files providing a more
# complete registry of what is installed (and what needs to be deleted).
uninstall_electrs() {
    echo
    print_info_bold "Stopping services and server..."
    stop_electrs

    # Remove launchd service
    local launchctrl_userid=$(id -u)
    if [[ -f "$LAUNCHCTRL_PLIST" ]]; then
        echo
        print_info_bold "Removing launchd service..."
        # bootout probably already happened, but won't hurt to force it again.
        if launchctl list "$LAUNCHCTRL_SERVICE" &>/dev/null; then
            launchctl bootout gui/$launchctrl_userid "$LAUNCHCTRL_PLIST" &>/dev/null
        fi
        delete_file_if_exists "$LAUNCHCTRL_PLIST"
    fi

    # Remove launchd helper scripts, logs, and directories.
    if [[ -d "$LAUNCHD_HELPER_DIR" ]]; then
        echo
        print_info_bold "Removing launchd helper scripts..."
        delete_file_if_exists "$LAUNCHD_HELPER_DIR/$LAUNCHD_HELPER_STARTER_NAME"
        delete_dir_if_empty "$LAUNCHD_HELPER_DIR"
    fi

    if [[ -d "$BUILD_LOGS_DIR" ]]; then
        echo
        print_info_bold "Removing build log files..."
        delete_file_if_exists "$BUILD_LOGS_DIR/electrs-brew-install.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/electrs-git-commands.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/electrs-cargo-build.log"
        delete_dir_if_empty "$BUILD_LOGS_DIR"
    fi

    # Remove log file
    if [[ -d "$NODE_BUILDER_APP_SUPPORT_PATH" ]]; then
        echo
        print_info_bold "Removing Node Builder support files..."
        delete_file_if_exists "$NODE_BUILDER_APP_SUPPORT_PATH/$ELECTRS_LOG_NAME"
        delete_file_if_exists "$NODE_BUILDER_APP_SUPPORT_PATH/.electrsInstallSuccessful"
        delete_dir_if_empty "$NODE_BUILDER_APP_SUPPORT_PATH"
    fi

    if [[ -d "$TARGET_PATH" ]]; then
        echo
        print_info_bold "Removing Electrs and configuration files from $TARGET_PATH..."

        # Remove binaries and helper scripts
        if [[ -d "$TARGET_PATH/bin" ]]; then
            rm -rf "$TARGET_PATH/bin" \
            && print_success "Removed: $TARGET_PATH/bin"
        fi

        # Remove repo build directory
        if [[ -d "$TARGET_PATH/electrs-repo" ]]; then
            rm -rf "$TARGET_PATH/electrs-repo" \
            && print_success "Removed: $TARGET_PATH/electrs-repo"
        fi

        delete_file_if_exists "$TARGET_PATH/config.toml"
        delete_file_if_exists "$TARGET_PATH/$ELECTRS_LOG_NAME"
        delete_file_if_exists "$TARGET_PATH/README.md"

        # Remove blockchain data files
        if [[ -d "$TARGET_PATH/db" ]]; then
            if (( PREVENT_DB_UNINSTALL )); then
                echo
                print_warning "Electrs indexing can be slow so the following directory was not removed:"
                echo
                print_warning "    $TARGET_PATH/db (skipped)"
                echo
                print_warning "Re-run this script with the -uu flag (or manually delete) if you never intend on reinstalling."
            else
                echo
                print_info_bold "Removing database of indexes..."
                rm -rf "$TARGET_PATH/db" \
                && print_success "Removed: $TARGET_PATH/db"
            fi
        fi
        delete_dir_if_empty "$TARGET_PATH"
    else
        echo
        print_warning "Electrs not installed."
        exit 1
    fi
    echo
    print_success "Uninstall complete."
    return 0
}

########################################
while [[ $# -gt 0 ]]; do
    case $1 in
    -h|--help)
        show_usage "${0:t}"
        exit 0
        ;;
    -v|--version)
        echo "Bitcoin Mac Node Builder v$NODE_BUILDER_VERSION"
        exit 0
        ;;
    -c)
        CLEAN_INSTALL=1
        shift
        ;;
    -f)
        FAST_INSTALL=1
        shift
        ;;
    -u)
        UNINSTALL=1
        shift
        ;;
    -uu)
        UNINSTALL=1
        PREVENT_DB_UNINSTALL=0
        shift
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

########################################
# Sanity check main configuration and build flag options.
TARGET_PATH=${ELECTRS_SERVER_CONFIG[target_path]}
OVERRIDE_EXISTING_CONFIG_FILE=${BITCOIN_CORE_CONFIG[generate_config_file]:-true}

if [[ "${ELECTRS_SERVER_CONFIG[enable_install]:-false}" == (#i)false ]]; then
    print_error "Configuration error. enable_install is not set for Electrs Electrum Server. To enable building/installing edit the ${CONFIG_FILENAME} file:"
    echo
    print_error "  ${CONFIG_FILE}"
    exit 1
fi

if [[ -z "$TARGET_PATH" || "${TARGET_PATH:u}" == *"YOUR_SSD_DRIVE"* ]]; then
    print_error "Configuration error. target_path is not set for Electrs Electrum Server (or is using the placeholder value). To fix edit the ${CONFIG_FILENAME} file:"
    echo
    print_error "  ${CONFIG_FILE}"
    exit 1
fi

if (( FAST_INSTALL )) && [[ ! -f "$NODE_BUILDER_APP_SUPPORT_PATH/.electrsInstallSuccessful" ]]; then
    print_error "Configuration error. Fast install flag (-f) requires first successfully completing a full install."
    exit 1
fi

if [[ "$OVERRIDE_EXISTING_CONFIG_FILE" == (#i)true && -f "$TARGET_PATH/config.toml" && \
$(<"$TARGET_PATH/config.toml") != *"DO NOT EDIT THIS FILE"* ]]; then
    print_error "The configuration file already exists:"
    echo
    print_error "  $TARGET_PATH/config.toml"
    echo
    print_error "and either was not generated by this script or was manually edited."
    print_error "Delete the existing config.toml file (or set generate_config_file to false) and re-run this script to continue."
    exit 1
fi

########################################
REPO_URL=${ELECTRS_SERVER_CONFIG[repo_url]}
STARTUP_TXT=$(cat <<EOF

This script will git clone the Electrs Electrum Server project from:

  ${REPO_URL}

and then build, install, and start the executable from:

  ${TARGET_PATH}/

EOF
)

if (( UNINSTALL )); then
    echo
    read "REPLY?This will stop Electrs and uninstall it from your Mac. Uninstall? (y/n) "
    if [[ "$REPLY" == (#i)y ]]; then
        uninstall_electrs
    fi
elif (( FAST_INSTALL )); then
    # Skips: install_main_dependencies, install_build_dependencies.
    echo
    echo "Fast installing changes only for $TARGET_PATH."
    echo
    print_info_bold "Stopping services and server..."
    stop_electrs
    create_target_dirs "$TARGET_PATH" "$NODE_BUILDER_APP_SUPPORT_PATH" "$BUILD_LOGS_DIR" || exit $?

    build_electrs "$REPO_URL"
    install_electrs
    install_config; install_launchd_plist; install_helper_scripts
    print_success "Fast build/download installation completed."
    echo
    print_info_bold "Starting services and server..."
    start_electrs
    generate_readme
else
    my_tput_clear
    echo "$STARTUP_TXT"
    if [ -t 0 ]; then   # if invoked from tty, then prompt first.
        echo
        read "REPLY?Install and start (y/n) "
    else                # else (invoked via pipe, etc.) wait a few seconds.
        REPLY="y"
        echo "Starting installation in 5 seconds..."
        my_sleep 5
    fi
    if [[ "$REPLY" == (#i)y ]]; then
        echo
        print_info_bold "Stopping services and server..."
        stop_electrs
        create_target_dirs "$TARGET_PATH" "$NODE_BUILDER_APP_SUPPORT_PATH" "$BUILD_LOGS_DIR" || exit $?
        install_main_dependencies
        install_build_dependencies; build_electrs "$REPO_URL"
        install_electrs
        install_config; install_launchd_plist; install_helper_scripts
        print_success "Installation completed."
        echo
        print_info_bold "Starting services and server..."
        start_electrs
        generate_readme
    fi
fi
exit 0
