#!/bin/zsh
#
# Amor et tolerantia erga omnes oppressos.
#

emulate -L zsh

###############################################################################
# All files are installed into the path specified by bitcoin_core[target_path]
# inside global_config.yaml. Layout of this directory is shown below.
#
# Source files (if bitcoin_core[build_or_download] is build) for building:
#
#   TARGET_PATH/bitcoin-repo-VERSION/
#
# Or downloaded executables (if bitcoin_core[build_or_download] is download):
#
#   TARGET_PATH/bitcoin-download-VERSION/
#
# Binaries are then copied from those repo/download directories, along with some
# helper scripts, into:
#
#   TARGET_PATH/bin/
#
# Configuration file (based on global_config.yaml settings) is generated into:
#
#   TARGET_PATH/bitcoin.conf
#
# On launch Bitcoin Core then creates Blockchain data files in:
#
#   TARGET_PATH/blocks
#   TARGET_PATH/chainstate
#   TARGET_PATH/indexes
#
###############################################################################

########################################
LAUNCHCTRL_SERVICE="org.bitcoin.bitcoind"
LAUNCHCTRL_PLIST="$HOME/Library/LaunchAgents/${LAUNCHCTRL_SERVICE}.plist"

# Only used for creating symlinks to TARGET_PATH.
BITCOIN_APP_SUPPORT_PATH_ALIAS="$HOME/Library/Application Support/Bitcoin"

LAUNCHD_HELPER_STARTER_NAME="start-bitcoind"

typeset -i CLEAN_INSTALL=0
typeset -i FAST_INSTALL=0
typeset -i UNINSTALL=0
# By default uninstalling keeps the blocks, chainstate, and indexes directories
# because re-downloading the initial blockchain and indexing can take several
# days. The uninstall process instead directs the users to manually delete those
# directories (or use flag -uu) if they really want to nuke everything.
typeset -i PREVENT_BLOCKS_AND_INDEX_UNINSTALL=1

########################################
# Parse the settings out of global_config.yaml into $BITCOIN_CORE_CONFIG.
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
$script_name (v$NODE_BUILDER_VERSION) - Installs Bitcoin full node based on Bitcoin Core. For configuring download/build options edit $CONFIG_FILENAME file.

USAGE: $script_name [-h] [-v] [-c] [-f] [-u]

OPTIONS:
    -h, --help          Show this help message.
    -v, --version       Show version information.
    -c                  Clean install. Forces fresh download and complete rebuild.
    -f                  Fast install only source and config changes. Skips dependency and startup checks. A complete build must be done initially to install dependencies.
    -u                  Uninstall Bitcoin Core but leaves data directories: blocks, chainstate, indexes.
    -uu                 Uninstall Bitcoin Core including all data directories.

CONFIGURATION FILE:
    $CONFIG_FILENAME
EOF
}

########################################
generate_readme() {
    cat > "$TARGET_PATH/README.md" <<EOF
# Bitcoin Mac Node Builder

## Bitcoin Core Installed

Bitcoin Core ($VERSION) was installed using the Bitcoin Mac Node Builder ([available on Github](https://github.com/pricklypierre/bitcoin-mac-node-builder)) into:

&nbsp;&nbsp;&nbsp;&nbsp;**$TARGET_PATH/**

Bitcoin Core is configured as a launchd service to automatically start on macOS user login, and will be automatically restarted after crashes. Bitcoin Core may take several hours/days to download a full copy of the blockchain.

## Start/Stop Bitcoin Core using the installed helper scripts:

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

## To uninstall Bitcoin Core:

\`\`\`shell
cd "$SCRIPT_DIR"
./bitcoin-core-install.sh -u
\`\`\`
EOF
    glow -w 90 "$TARGET_PATH/README.md" || return $?
    return 0
}

########################################
# Exits script on any fatal install or configure errors.
install_tor() {
    echo
    print_info_bold "Configuring Tor service and settings..."
    my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
        tor \
    || exit $?

    # Configure Tor to use CookieAuthentication and ControlPort.
    for test_path in "/opt/homebrew/etc/tor" "/usr/local/etc/tor"
    do
        if [[ -f "$test_path/torrc" ]]; then
            torrc_path="$test_path/torrc"
            print_info "✓ Checking $torrc_path"
            break
        elif [[ -f "$test_path/torrc.sample" ]]; then
            torrc_path="$test_path/torrc"
            print_info "✓ Copying torrc.sample to $torrc_path"
            cp "$test_path/torrc.sample" "$torrc_path"
            break
        fi
    done
    if [[ -z "$torrc_path" ]]; then
        print_error "Could not find torrc or torrc.sample files"
        exit 1
    fi

    # Ensure ControlPort 9051 is set
    grep -E '^ControlPort[[:space:]]+9051' "$torrc_path" &>/dev/null
    if (( $? == 0 )); then
        print_info "✓ Torrc already has 'ControlPort 9051' set"
    else
        print_info "✓ Adding 'ControlPort 9051' to torrc"
        echo "ControlPort 9051" >> "$torrc_path"
    fi

    # Ensure CookieAuthentication 1 is set
    grep -E '^CookieAuthentication[[:space:]]+1' "$torrc_path" &>/dev/null
    if (( $? == 0 )); then
        print_info "✓ Torrc already has 'CookieAuthentication 1' set"
    else
        print_info "✓ Adding 'CookieAuthentication 1' to torrc"
        echo "CookieAuthentication 1" >> "$torrc_path"
    fi
    print_info "✓ (to check Tor control port: nc -z 127.0.0.1 9051)"

    # Might also want to set CookieAuthFileGroupReadable and DataDirectoryGroupReadable to 1.
    return 0
}

# Exits script on any fatal errors trying to re/start tor.
start_tor() {
    # Start or restart Tor via Homebrew
    if [[ "$ENABLE_TOR_CONN" != (#i)true ]]; then
        return 0
    fi
    if [[ "$(brew services list | awk '$1 == "tor" { print $2 }')" == "started" ]]; then
        my_brew_services_restart tor || exit $?
    else
        my_brew_services_start tor || exit $?
        : > "$NODE_BUILDER_APP_SUPPORT_PATH/.torStartedByNodeBuilder"
    fi
    return 0
}

# Never exits script (failure to stop Tor is non-fatal).
stop_tor() {
    # Only stop tor if we started it originally.
    if [[ -f "$NODE_BUILDER_APP_SUPPORT_PATH/.torStartedByNodeBuilder" ]]; then
        rm -f "$NODE_BUILDER_APP_SUPPORT_PATH/.torStartedByNodeBuilder"
        if [[ "$(brew services list | awk '$1 == "tor" { print $2 }')" == "started" ]]; then
            my_brew_services_stop tor  # intentional non-fatal if failure
        fi
    fi
    return 0
}

########################################
# Exits script on any fatal install or configure errors.
install_main_dependencies() {
    echo
    print_info_bold "Checking required system packages for installing..."

    my_brew_prep  # intentional non-fatal if failure
    my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
        coreutils \
        glow \
    || exit $?
    if [[ "$ENABLE_TOR_CONN" == (#i)true ]]; then
        install_tor
    fi
    return 0
}

# Exits script on any fatal install or configure errors.
install_build_dependencies() {
    echo
    print_info_bold "Checking required system packages for building..."

    my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
        automake \
        boost \
        cmake \
        libtool \
        miniupnpc \
        pkg-config \
    || exit $?

    if (( VERSION_GTE_30 )); then
        my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
            capnp \
        || exit $?
    fi

    if [[ ${INCLUDE_GUI_APP} == "ON" ]]; then
        if (( VERSION_GTE_30 )); then
            my_brew_uninstall_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
                qt@5  # intentional non-fatal if failure
            my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
                qrencode \
                qt@6 \
            || exit $?
        else
            my_brew_uninstall_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
                qt@6  # intentional non-fatal if failure
            my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
                qrencode \
                qt@5 \
            || exit $?
        fi
    fi

    if [[ "$ENABLE_WALLET" == (#i)true ]]; then
        my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
            berkeley-db@5 \
            sqlite \
        || exit $?
    fi

    my_brew_install_withlog "$BUILD_LOGS_DIR/bitcoind-brew-install.log" \
        openssl \
        libevent \
    || exit $?

    my_brew_cleanup  # intentional non-fatal if failure
    return 0
}

########################################
# Exits script on any fatal build or configure errors.
build_bitcoin_core() {
    cd "$TARGET_PATH" || exit $?

    # Note we build in version specific folder (bitcoin-repo-$VERSION).
    if (( CLEAN_INSTALL )) && [[ -d "bitcoin-repo-$VERSION" ]]; then
        echo
        print_info_bold "Performing clean install (deleting existing build)..."
        rm -rf "bitcoin-repo-$VERSION"      || { print_error "rm bitcoin-repo-$VERSION failed"; exit 1; }
    fi
    if [[ ! -d "bitcoin-repo-$VERSION" ]]; then
        echo
        print_info_bold "Downloading Bitcoin Core source files (git clone)..."
        mkdir -p "bitcoin-repo-$VERSION"    || { print_error "mkdir bitcoin-repo-$VERSION failed"; exit 1; }
        cd "bitcoin-repo-$VERSION"          || { print_error "cd bitcoin-repo-$VERSION failed"; exit 1; }
        local -i success=1
        exec_with_popview \
            "Running git clone..." \
            "$BUILD_LOGS_DIR/bitcoind-git-commands.log" \
            git clone "$1" "$(pwd)" \
        || success=0
        if (( ! success )); then
            print_error "Git clone failed."
            cd "$TARGET_PATH" || exit $?
            rm -rf "bitcoin-repo-$VERSION"  # Remove to force a git clone/checkout on next run.
            exit 1
        fi
        if (( VERSION_IS_BRANCH )); then
            exec_with_popview \
                "Running git checkout..." \
                "$BUILD_LOGS_DIR/bitcoind-git-commands.log" \
                git checkout -b "my-branch" "origin/$VERSION" \
            || success=0
        else
            exec_with_popview \
                "Running git checkout..." \
                "$BUILD_LOGS_DIR/bitcoind-git-commands.log" \
                git checkout -b "my-branch" "$VERSION" \
            || success=0
        fi
        if (( ! success )); then
            print_error "Git checkout failed."
            cd "$TARGET_PATH" || exit $?
            rm -rf "bitcoin-repo-$VERSION"  # Remove to force a git clone/checkout on next run.
            exit 1
        fi
    else
        cd "bitcoin-repo-$VERSION"          || { print_error "cd bitcoin-repo-$VERSION failed"; exit 1; }
        echo
        if (( VERSION_IS_BRANCH )); then
            print_info_bold "Downloading Bitcoin Core changes (git pull on branch $VERSION)..."
            local -i success=1
            exec_with_popview \
                "Running git pull..." \
                "$BUILD_LOGS_DIR/bitcoind-git-commands.log" \
                git pull \
            || success=0
            if (( ! success )); then
                print_error "Git pull failed."
                exit 1
            fi
        else
            # No point in doing 'git pull' because we did a checkout on a version (not branch)
            # so there cannot be any changes (head is detached).
            print_info_bold "Skipping download of Bitcoin Core source files (already exists)..."
        fi
    fi

    echo
    print_info_bold "Building Bitcoin Core ($VERSION) via cmake..."

    # We optionally build: GUI, wallets, tests, and .zip.
    setopt null_glob
    rm -rf "$TARGET_PATH/bin/"*
    rm -rf build/Bitcoin-Core.zip
    rm -rf build/Bitcoin-Qt.app
    rm -rf build/bin/*
    unsetopt null_glob

    local build_enable_wallet=OFF
    if [[ "$ENABLE_WALLET" == (#i)true ]]; then
        build_enable_wallet=ON
        export PKG_CONFIG_PATH="$(brew --prefix berkeley-db@5)/lib/pkgconfig:$(brew --prefix sqlite)/lib/pkgconfig"
        : > "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreBuiltWithWalletEnabled"
    else
        rm -f "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreBuiltWithWalletEnabled"
    fi

    local -i core_count=0
    get_cpu_core_count core_count
    local -i n_jobs=$((core_count - 2))
    ((n_jobs < 1)) && n_jobs=1

    local -i success=1
    exec_with_popview \
        "Running cmake configure..." \
        "$BUILD_LOGS_DIR/bitcoind-cmake-config.log" \
        cmake -B build \
        -DBUILD_GUI=$INCLUDE_GUI_APP \
        -DBUILD_TESTS=$INCLUDE_TESTS \
        -DENABLE_WALLET=$build_enable_wallet \
        -DWITH_QRENCODE=$INCLUDE_GUI_APP \
    || success=0
    if (( success )); then
        exec_with_popview \
            "Running cmake build..." \
            "$BUILD_LOGS_DIR/bitcoind-cmake-build.log" \
            cmake --build build -j $n_jobs \
        || success=0
    fi
    if (( success )) && [[ $INCLUDE_TESTS == ON ]]; then
        exec_with_popview \
            "Running ctest..." \
            "$BUILD_LOGS_DIR/bitcoind-ctest-run.log" \
            ctest --test-dir build -j $n_jobs \
        || success=0
    fi
    if (( success )) && [[ $INCLUDE_GUI_APP == ON ]]; then
        exec_with_popview \
            "Running cmake deploy..." \
            "$BUILD_LOGS_DIR/bitcoind-cmake-deploy.log" \
            cmake --build build --target deploy \
        || success=0
    fi
    if (( success )) && [[ -f "$TARGET_PATH/bitcoin-repo-$VERSION/build/bin/bitcoind" ]]; then
        print_success "Build logs available in: $BUILD_LOGS_DIR"
        return 0
    fi
    print_error "Build failed. See build logs in:"
    echo
    print_error "   $BUILD_LOGS_DIR"
    exit 1
}

# Exits script on any fatal download errors.
download_bin_and_app() {
    cd "$TARGET_PATH" || exit $?

    # Downloaded binaries are in $TARGET_PATH/bitcoin-download-$VERSION/bin/.
    if (( CLEAN_INSTALL )) && [[ -d "bitcoin-download-$VERSION" ]]; then
        echo
        print_info_bold "Performing clean install (deleting existing downloaded binaries)..."
        rm -rf "bitcoin-download-$VERSION" || { print_error "rm bitcoin-download-$VERSION failed"; exit 1; }
    fi

    echo
    print_info_bold "Downloading Bitcoin Core binaries..."
    mkdir -p "bitcoin-download-$VERSION"    || { print_error "mkdir bitcoin-download-$VERSION failed"; exit 1; }
    rm -f bitcoin-download-$VERSION.tar.gz bitcoin-download-$VERSION.zip checksum.asc
    if ! program_exists "curl"; then
        print_error "curl program not found but is required."
        exit 1
    fi
    if ! program_exists "shasum"; then
        print_error "shasum program not found but is required."
        exit 1
    fi
    if [[ -f "bitcoin-download-$VERSION/bin/bitcoind" ]]; then
        print_info "✓ Bitcoin Core binaries previously downloaded"
        # Assuming the binaries are good/valid. Caller can use clean install flag (-c) if they
        # need a fresh download.
    else
        if [[ ! -f "checksum.asc" ]]; then
            curl -s "$3" -o checksum.asc    || { print_error "Download failed: $3"; exit 1; }
        fi
        curl --progress-bar "$1" -o bitcoin-download-$VERSION.tar.gz &&
        checksum_targz=$(shasum -a 256 bitcoin-download-$VERSION.tar.gz | awk '{ print $1 }')
        if [ $? -ne 0 ]; then
            print_error "Download failed: $1"
            exit 1
        fi
        print_info "✓ Bitcoin Core binaries downloaded"
        if grep -q "$checksum_targz" checksum.asc; then
            print_success "Checksum passed: bitcoin-download-$VERSION.tar.gz ($checksum_targz)"
            tar xzf bitcoin-download-$VERSION.tar.gz -C bitcoin-download-$VERSION --strip-components=1
        else
            print_error "Checksum failed: bitcoin-download-$VERSION.tar.gz ($checksum_targz). Do not use until validation is fixed."
            exit 1
        fi
    fi

    if [[ ${INCLUDE_GUI_APP} == "ON" ]]; then
        if [[ -e "bitcoin-download-$VERSION/bin/Bitcoin-Qt.app" ]]; then
            print_info "✓ Bitcoin Core app (GUI) previously downloaded"
            # Caller can use clean install flag (-c) if they need a fresh download.
        else
            if [[ ! -f "checksum.asc" ]]; then
                curl -s "$3" -o checksum.asc    || { print_error "Download failed: $3"; exit 1; }
            fi
            curl --progress-bar "$2" -o bitcoin-download-$VERSION.zip &&
            checksum_zip=$(shasum -a 256 bitcoin-download-$VERSION.zip | awk '{ print $1 }')
            if [ $? -ne 0 ]; then
                print_error "Download failed: $2"
                exit 1
            fi
            print_info "✓ Bitcoin Core app (GUI) downloaded"
            if grep -q "$checksum_zip" checksum.asc; then
                print_success "Checksum passed: bitcoin-download-$VERSION.zip    ($checksum_zip)"
                unzip -oq bitcoin-download-$VERSION.zip -d bitcoin-download-$VERSION/bin
            else
                print_error "Checksum failed: bitcoin-download-$VERSION.zip    ($checksum_zip). Do not use until validation is fixed."
                exit 1
            fi
        fi
    fi

    rm -f bitcoin-download-$VERSION.tar.gz bitcoin-download-$VERSION.zip checksum.asc
    return 0
}

# Exits script on any fatal install or configure errors.
install_config() {
    echo
    if [[ "$OVERRIDE_EXISTING_CONFIG_FILE" == (#i)false && -f "$TARGET_PATH/bitcoin.conf" ]]; then
        print_info_bold "Skipping generation of configuration file (already exists and generate_config_file is false)..."
        return 0
    elif [[ -f "$TARGET_PATH/bitcoin.conf" ]]; then
        print_info_bold "Generating configuration file (overriding existing)..."
    else
        print_info_bold "Generating configuration file..."
    fi

    # Construct the configuration file (bitcoin.conf).
    local -i config_listen=0
    if [[ "$ENABLE_INBOUND" == (#i)true ]]; then
        config_listen=1
    fi
    local -i config_disablewallet=1
    if [[ "$ENABLE_WALLET" == (#i)true ]]; then
        config_disablewallet=0
    fi
    local -i config_rpcserver=0
    if [[ "${BITCOIN_CORE_CONFIG[enable_local_rpc]:-false}" == (#i)true ]]; then
        config_rpcserver=1
        # Enables the RPC server (sets server=1). Required for bitcoin-cli, Electrs, Sparrow, Specter, etc.
        # Note only local cookie authentication is supported for RPC currently, which is automatically handled
        # for Electrs server (if enabled). This requires using the default values for rpccookiefile, rpcbind,
        # rpcallowip, rpcport.
        #
        # Usage of remote machine RPC via rpcuser/rpcpassword or rpcauth is not currently supported.
    fi

    cd "$TARGET_PATH" || exit $?
    : > "bitcoin.conf"
    cat > "bitcoin.conf" <<EOF
###################################################################################################
#                                  ** DO NOT EDIT THIS FILE **
# It was machine generated by Bitcoin Mac Node Builder and any manual edits will be overwritten the
# next time the bitcoin-core-install.sh script is executed. To change any configuration settings,
# edit the file:
#
#  ${CONFIG_FILE}
#
# And then re-run the script: ${BITCOIN_CORE_INSTALL_SH_FILE}
#
############################
# Inbound and outbound connection settings.
server=${config_rpcserver}              # enables RPC server; required for bitcoin-cli and 3rd party wallets (Sparrow, Specter, Electrum, etc.)
listen=${config_listen}              # enables accepting incoming connections from peers
port=${CONFIG_LISTENPORT}
EOF
    if [[ "$ENABLE_IPV4_CONN" == (#i)true ]]; then
        echo "onlynet=ipv4" >> "bitcoin.conf"
    fi
    if [[ "$ENABLE_IPV6_CONN" == (#i)true ]]; then
        echo "onlynet=ipv6" >> "bitcoin.conf"
    fi
    cat >> "bitcoin.conf" <<EOF

# Address discovery settings for incoming IPv4/IPv6 peer connections.
discover=${CONFIG_DISCOVER}
natpmp=${CONFIG_NATPMP}
upnp=${CONFIG_UPNP}
EOF
    if [[ "$EXT_IPV4_DISCOVERY_METHOD" == (#i)(static) ]] && [[ -n $CONFIG_EXTERNALIPV4 ]]; then
        cat >> "bitcoin.conf" <<EOF

# Instead of IPv4 address auto discovery and NAT-PMP / UPnP, this configuration uses a static IPv4 address and port.
externalip=${CONFIG_EXTERNALIPV4}:${CONFIG_EXTERNALPORT}
EOF
    fi
    if [[ "$EXT_IPV6_DISCOVERY_METHOD" == (#i)(static) ]] && [[ -n $CONFIG_EXTERNALIPV6 ]]; then
        cat >> "bitcoin.conf" <<EOF

# Instead of IPv6 address auto discovery, this configuration uses a static IPv6 address and port.
externalip=${CONFIG_EXTERNALIPV6}:${CONFIG_EXTERNALPORT}
EOF
    fi
    if [[ "$ENABLE_TOR_CONN" == (#i)true ]]; then
        cat >> "bitcoin.conf" <<EOF

# Tor connections are via the local Tor SOCKS5 proxy on port 9050. Inbound connections are handled automatically (even
# over NAT/VPN) via a Tor hidden service so setting externalip, upnp, or natpmp for discovery is not needed (unless
# IPv4 or IPv6 connections are enabled).
listenonion=${config_listen}
onlynet=onion
proxy=127.0.0.1:9050
EOF
    fi
    cat >> "bitcoin.conf" <<EOF

whitelist=${BITCOIN_CORE_RAW[whitelist]}   # required so that Electrs server doesn't get dropped when maxuploadtarget cap is hit
maxconnections=${BITCOIN_CORE_RAW[maxconnections]}     # allow up to ${BITCOIN_CORE_RAW[maxconnections]} inbound + outbound connections (default is 125)
maxuploadtarget=${BITCOIN_CORE_RAW[maxuploadtarget]}   # bandwidth cap (in MB) per day (default is 0 which is uncapped)
EOF
    if [[ "$PRIVACY_LOCKDOWN" == (#i)true ]]; then
        cat >> "bitcoin.conf" <<EOF

############################
# Privacy settings. Having all of these set to 0 might prevent finding any nodes if peers.dat hasn't been populated yet,
# in which case you can manually addnodes or temporarily set dnsseed=1.
dnsseed=0
dns=0
peerbloomfilters=0
EOF
    fi
    cat >> "bitcoin.conf" <<EOF

############################
disablewallet=${config_disablewallet}       # only enable if you need it; not needed for 3rd party wallets (Sparrow, Specter, Electrum, etc.)
blockfilterindex=${BITCOIN_CORE_RAW[blockfilterindex]}    # required to be 1 for Electrs server
txindex=${BITCOIN_CORE_RAW[txindex]}             # required to be 1 for older Electrs server versions
prune=${BITCOIN_CORE_RAW[prune]}               # required to be 0 for Electrs server

par=${BITCOIN_CORE_RAW[par]}                 # use N threads/cores for script verfifications
dbcache=${BITCOIN_CORE_RAW[dbcache]}          # larger value here will help prevent drive thrashing during IBD; can change to 450 after IDB.
checkblocks=${BITCOIN_CORE_RAW[checkblocks]}         # number of blocks to check on startup
EOF
    # Lastly, directly include all key/value pairs that start with an underscore, except ones already handled above.
    echo >> "bitcoin.conf"
    local exclude_keys="(whitelist|maxconnections|maxuploadtarget|blockfilterindex|txindex|prune|par|dbcache|checkblocks)"
    for key in "${(@k)BITCOIN_CORE_RAW}"; do
        [[ "$key" = ${~exclude_keys} ]] && continue   # Skip pairs we already manually handled above.
        echo "$key=${BITCOIN_CORE_RAW[$key]}" >> "bitcoin.conf"
    done
    chmod go-rw "bitcoin.conf"
    print_success "Generated: $TARGET_PATH/bitcoin.conf"
    return 0
}

# Exits script on any fatal install or configure errors.
install_launchd_plist() {
    # Construct the launchd .plist file (org.bitcoin.bitcoind.plist).
    echo
    print_info_bold "Installing launchd .plist service files..."

    # Note instead of using ProgramArguments:
    #
    #    <key>ProgramArguments</key>
    #    <array>
    #        <string>$TARGET_PATH/bin/bitcoind</string>
    #        <string>-conf=$TARGET_PATH/bitcoin.conf</string>
    #        <string>-datadir=$TARGET_PATH</string>
    #        <string>-debug=tor</string>
    #    </array>
    #
    # below zsh exec is used to start bitcoind if it exists. This is because the volume may not
    # yet be mounted and if launchd cannot find the executable to launch then it indefinitely
    # suspends the service and never tries to relaunch it (even with our KeepAlive PathState
    # settings). We bypass this problem by having launchd start a zsh script (which always exists).
    cat > "$LAUNCHCTRL_PLIST" <<EOF
<?xml version="1.0" encoding="UTF-8"?>
<!DOCTYPE plist PUBLIC "-//Apple//DTD PLIST 1.0//EN" "http://www.apple.com/DTDs/PropertyList-1.0.dtd">
<plist version="1.0">
<dict>
    <key>Label</key>
    <string>org.bitcoin.bitcoind</string>
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
            <key>$TARGET_PATH/bin/bitcoind</key>
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

# Loop waiting for bitcoind to be mounted (needed if it is on an external volume).
# Launchd will put our service in the penalty box forever if the executable
# doesn't exist (volume not mounted) so we handle this logic here ourselves.
while true; do
    if [ -x "$TARGET_PATH/bin/bitcoind" ]; then
        exec "$TARGET_PATH/bin/bitcoind" -conf="$TARGET_PATH/bitcoin.conf" -datadir="$TARGET_PATH" -debug=tor -daemon=0
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
GUI_APP_NAME="Bitcoin-Qt"
PROCESS_NAME="bitcoind"
PROCESS_PATH="$TARGET_PATH/bin/bitcoind"
GUI_USERID=\$(id -u)

RED="$RED"; GREEN="$GREEN"; BLUE="$BLUE"; YELLOW="$YELLOW"; RESET="$RESET"

if pgrep -x "\$GUI_APP_NAME" > /dev/null; then
    printf "\${BLUE}%s (GUI app) is already running. The bitcoind process cannot be started until it is stopped.\${RESET}\n" "\$GUI_APP_NAME"
    exit 0
fi
if pgrep -x "\$PROCESS_NAME" > /dev/null; then
    printf "\${BLUE}%s is already running.\${RESET}\n" "\$PROCESS_PATH"
    exit 0
fi
if [ ! -f "\$PROCESS_PATH" ]; then
    printf "\${RED}Unable to launch %s. Executable not found.\${RESET}\n" "\$PROCESS_PATH"
    exit 1
fi

if launchctl list "\$SERVICE" &>/dev/null; then
    printf "\${YELLOW}Using launchd bootout to remove service before starting.\${RESET}\n"
    launchctl bootout gui/\$GUI_USERID "\$PLIST" &>/dev/null
fi

printf "\${BLUE}Starting %s via launchctl.\${RESET}\n" "\$PROCESS_PATH"
if ! launchctl bootstrap gui/\$GUI_USERID "\$PLIST"; then
    printf "\${RED}Launchctl bootstrap of %s failed.\${RESET}\n" "\$PROCESS_PATH"
    printf "\${RED}Attempting direct shell launch for debugging using:\${RESET}\n\n"
    ARG1="-conf=$TARGET_PATH/bitcoin.conf"
    ARG2="-datadir=$TARGET_PATH"
    ARG3="-debug=tor"
    printf "\${BLUE}\"\${PROCESS_PATH}\" \"\${ARG1}\" \"\${ARG2}\" \"\${ARG3}\"\${RESET}\n\n"
    "\${PROCESS_PATH}" "\${ARG1}" "\${ARG2}" "\${ARG3}"
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
PROCESS_NAME="bitcoind"
PROCESS_PATH="$TARGET_PATH/bin/bitcoind"
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
        rm -f "$TARGET_PATH/bitcoind.pid"
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
    : > "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreInstallSuccessful"
    return 0
}

# Exits script on any fatal install or configure errors.
install_bitcoin_core() {
    cd "$TARGET_PATH" || exit $?
    echo

    if [[ ! -d "bin" ]]; then
        mkdir -p "bin" || exit $?
    fi

    print_info_bold "Creating symbolic link to target directory..."
    if [[ -e "$BITCOIN_APP_SUPPORT_PATH_ALIAS" ]]; then
        # We need to always refresh the symbolic link because $TARGET_PATH might have changed
        # from when it was created, so first delete the existing symbolic link file.
        if [[ ! -L "$BITCOIN_APP_SUPPORT_PATH_ALIAS" ]]; then
            # File wasn't a symbolic link (probably is folder from a previous install not related
            # to our script). Deleting the folder (especially if it has the blockchain download)
            # would be uncool, so bail out.
            print_error "Folder $BITCOIN_APP_SUPPORT_PATH_ALIAS already exists, preventing symbolic link to target directory from being created."
            print_error "Delete or rename $BITCOIN_APP_SUPPORT_PATH_ALIAS and re-run this script to continue."
            exit 1
        fi
        rm -f "$BITCOIN_APP_SUPPORT_PATH_ALIAS" || exit $?
    fi
    ln -s "$TARGET_PATH" "$BITCOIN_APP_SUPPORT_PATH_ALIAS" || exit $?
    print_success "Created: $BITCOIN_APP_SUPPORT_PATH_ALIAS -> $TARGET_PATH"
    echo

    # Note we copy over all binaries not just bitcoind.
    if [[ "$1" == "build" ]]; then
        # Compiled binaries are in $TARGET_PATH/bitcoin-repo-$VERSION/build/bin/.
        print_info_bold "Installing Bitcoin Core ($VERSION) from compiled binaries..."
        if [[ -f "bitcoin-repo-$VERSION/build/bin/bitcoind" ]]; then
            # Install compiled binaries.
            setopt null_glob
            cp "bitcoin-repo-$VERSION/build/bin/bitcoin"* "bin/" \
            && print_success "Installed: $TARGET_PATH/bin/bitcoind"
            if [[ ${INCLUDE_TESTS} == "ON" ]]; then
                cp "bitcoin-repo-$VERSION/build/bin/test_bitcoin"* "bin/"
            fi
            if [[ ${INCLUDE_GUI_APP} == "ON" ]]; then
                cp -R "bitcoin-repo-$VERSION/build/Bitcoin-Qt.app" "bin/" \
                && print_success "Installed: $TARGET_PATH/bin/Bitcoin-Qt.app"
            fi
            unsetopt null_glob
        else
            print_error "Cannot find compiled binaries to install."
            exit 1
        fi
    elif [[ "$1" == "download" ]]; then
        # Downloaded binaries are in $TARGET_PATH/bitcoin-download-$VERSION/bin/.
        print_info_bold "Installing Bitcoin Core ($VERSION) from downloaded binaries..."
        if [[ -f "bitcoin-download-$VERSION/bin/bitcoind" ]]; then
            # Install downloaded binaries.
            setopt null_glob
            cp "bitcoin-download-$VERSION/bin/bitcoin"* "bin/" \
            && print_success "Installed: $TARGET_PATH/bin/bitcoind"
            if [[ ${INCLUDE_TESTS} == "ON" ]]; then
                cp "bitcoin-download-$VERSION/bin/test_bitcoin"* "bin/"
            fi
            if [[ ${INCLUDE_GUI_APP} == "ON" ]]; then
                cp -R "bitcoin-download-$VERSION/bin/Bitcoin-Qt.app" "bin/" \
                && print_success "Installed: $TARGET_PATH/bin/Bitcoin-Qt.app"
            fi
            unsetopt null_glob
        else
            print_error "Cannot find downloaded binaries to install."
            exit 1
        fi
    else
        exit 1
    fi
    return 0
}

########################################
# Exits script if unable to start bitcoind.
start_bitcoin_core() {
    if ! pgrep -x bitcoind > /dev/null; then
        local -i success=1
        exec_with_popview \
            "Starting Bitcoin Core..." \
            "" \
            "$TARGET_PATH/bin/start.sh" \
        || success=0
        if (( success )); then
            print_success "Bitcoin Core is running."
        else
            print_error "Failed to start Bitcoin Core."
            exit 1
        fi
    fi
    return 0
}

# Exits script if unable to stop bitcoind.
stop_bitcoin_core() {
    if pgrep -x bitcoind > /dev/null || pgrep -f "launchd/$LAUNCHD_HELPER_STARTER_NAME" > /dev/null; then
        local -i success=1
        exec_with_popview \
            "Stopping Bitcoin Core..." \
            "" \
            "$TARGET_PATH/bin/stop.sh" \
        || success=0
        if (( ! success )); then
            print_error "Failed to stop Bitcoin Core."
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
uninstall_bitcoin_core() {
    echo
    print_info_bold "Stopping services and server..."
    stop_bitcoin_core; stop_tor

    # Remove launchd service
    local -i launchctrl_userid=$(id -u)
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
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-brew-install.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-git-commands.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-cmake-config.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-cmake-build.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-cmake-deploy.log"
        delete_file_if_exists "$BUILD_LOGS_DIR/bitcoind-ctest-run.log"
        delete_dir_if_empty "$BUILD_LOGS_DIR"
    fi

    if [[ -d "$NODE_BUILDER_APP_SUPPORT_PATH" ]]; then
        echo
        print_info_bold "Removing Node Builder support files..."
        delete_file_if_exists "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreBuiltWithWalletEnabled"
        delete_file_if_exists "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreInstallSuccessful"
        delete_file_if_exists "$NODE_BUILDER_APP_SUPPORT_PATH/.torStartedByNodeBuilder"
        delete_dir_if_empty "$NODE_BUILDER_APP_SUPPORT_PATH"
    fi

    if [[ -d "$TARGET_PATH" ]]; then
        echo
        print_info_bold "Removing Bitcoin Core and configuration files from $TARGET_PATH..."

        # Remove binaries and helper scripts
        if [[ -d "$TARGET_PATH/bin" ]]; then
            rm -rf "$TARGET_PATH/bin" \
            && print_success "Removed: $TARGET_PATH/bin"
        fi

        # Remove build/download directories (wildcard needed since there can be multiple versions)
        for dir in "$TARGET_PATH/bitcoin-repo-"*(/N); do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir" \
                && print_success "Removed: $dir"
            fi
        done
        for dir in "$TARGET_PATH/bitcoin-download-"*(/N); do
            if [[ -d "$dir" ]]; then
                rm -rf "$dir" \
                && print_success "Removed: $dir"
            fi
        done

        delete_file_if_exists "$TARGET_PATH/bitcoin.conf"
        delete_file_if_exists "$TARGET_PATH/bitcoind.pid"
        delete_file_if_exists "$TARGET_PATH/fee_estimates.dat"
        delete_file_if_exists "$TARGET_PATH/anchors.dat"
        delete_file_if_exists "$TARGET_PATH/mempool.dat"
        delete_file_if_exists "$TARGET_PATH/peers.dat"
        delete_file_if_exists "$TARGET_PATH/banlist.json"
        delete_file_if_exists "$TARGET_PATH/settings.json"
        delete_file_if_exists "$TARGET_PATH/onion_v3_private_key"
        delete_file_if_exists "$TARGET_PATH/debug.log"
        delete_file_if_exists "$TARGET_PATH/README.md"

        if [[ -L "$BITCOIN_APP_SUPPORT_PATH_ALIAS" ]]; then
            rm -f "$BITCOIN_APP_SUPPORT_PATH_ALIAS" \
            && print_success "Removed: $BITCOIN_APP_SUPPORT_PATH_ALIAS"
        fi

        # Remove blockchain data files
        if [[ -d "$TARGET_PATH/blocks" ]] || [[ -d "$TARGET_PATH/chainstate" ]] || \
        [[ -d "$TARGET_PATH/indexes" ]] || [[ -d "$TARGET_PATH/wallets" ]]; then
            if (( PREVENT_BLOCKS_AND_INDEX_UNINSTALL )); then
                echo
                print_warning "Blockchain and indexes can take several days to download so the following directories were not removed:"
                echo
                print_warning "    $TARGET_PATH/blocks     (skipped)"
                print_warning "    $TARGET_PATH/chainstate (skipped)"
                print_warning "    $TARGET_PATH/indexes    (skipped)"
                print_warning "    $TARGET_PATH/wallets    (skipped)"
                echo
                print_warning "Re-run this script with the -uu flag (or manually delete) if you never intend on reinstalling."
            else
                echo
                print_info_bold "Removing blockchain and indexes..."
                if [[ -d "$TARGET_PATH/blocks" ]]; then
                    rm -rf "$TARGET_PATH/blocks" \
                    && print_success "Removed: $TARGET_PATH/blocks"
                fi
                if [[ -d "$TARGET_PATH/chainstate" ]]; then
                    rm -rf "$TARGET_PATH/chainstate" \
                    && print_success "Removed: $TARGET_PATH/chainstate"
                fi
                if [[ -d "$TARGET_PATH/indexes" ]]; then
                    rm -rf "$TARGET_PATH/indexes" \
                    && print_success "Removed: $TARGET_PATH/indexes"
                fi
                if [[ -d "$TARGET_PATH/wallets" ]]; then
                    # Force user to manually delete wallets folder.
                    print_warning "Skipped: $TARGET_PATH/wallets    (must be manually deleted)"
                    #   rm -rf "$TARGET_PATH/wallets" \
                    #   && print_success "Removed: $TARGET_PATH/wallets"
                fi
            fi
        fi
        delete_dir_if_empty "$TARGET_PATH"
    else
        echo
        print_warning "Bitcoin Core not installed."
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
        PREVENT_BLOCKS_AND_INDEX_UNINSTALL=0
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
VERSION=${BITCOIN_CORE_CONFIG[version]}
VERSION_CLEAN=${VERSION#v}  # Strip 'v' prefix character used for specifing tags.
typeset -i VERSION_IS_NUMERICAL=0
typeset -i VERSION_GTE_29=0
typeset -i VERSION_GTE_30=0
typeset -i VERSION_GTE_31=0
typeset -i VERSION_GTE_32=0
if [[ "$VERSION_CLEAN" == [0-9]* ]]; then
    VERSION_IS_NUMERICAL=1
    autoload is-at-least
    if is-at-least 29.0 "$VERSION_CLEAN"; then
        VERSION_GTE_29=1
    fi
    if is-at-least 30.0 "$VERSION_CLEAN"; then
        VERSION_GTE_30=1
    fi
    if is-at-least 31.0 "$VERSION_CLEAN"; then
        VERSION_GTE_31=1
    fi
    if is-at-least 32.0 "$VERSION_CLEAN"; then
        VERSION_GTE_32=1
    fi
else
    # If version is a branch label (likely "master"), then assume it is at least v30.
    VERSION_GTE_29=1
    VERSION_GTE_30=1
    # Uncomment as master branch development progresses:
    # VERSION_GTE_31=1
    # VERSION_GTE_32=1
fi
typeset -i VERSION_IS_BRANCH=0
if [[ "$VERSION" == "$VERSION_CLEAN" ]]; then
    VERSION_IS_BRANCH=1   # If it did not have 'v' prefix, then version specified is a branch (not a tag)
fi
TARGET_PATH=${BITCOIN_CORE_CONFIG[target_path]}
OVERRIDE_EXISTING_CONFIG_FILE=${BITCOIN_CORE_CONFIG[generate_config_file]:-true}

ENABLE_WALLET=${BITCOIN_CORE_CONFIG[enable_wallet]:-false}
PRIVACY_LOCKDOWN=${BITCOIN_CORE_CONFIG[privacy_lockdown]:-false}

BUILD_OR_DOWNLOAD=${BITCOIN_CORE_CONFIG[build_or_download]}

if [[ "${BITCOIN_CORE_CONFIG[enable_install]:-false}" == (#i)false ]]; then
    print_error "Configuration error. enable_install is not set for Bitcoin Core. To enable building/installing edit the ${CONFIG_FILENAME} file:"
    echo
    print_error "  ${CONFIG_FILE}"
    exit 1
fi

if [[ -z "$TARGET_PATH" || "${TARGET_PATH:u}" == *"YOUR_SSD_DRIVE"* ]]; then
    print_error "Configuration error. target_path is not set for Bitcoin Core (or is using the placeholder value). To fix edit the ${CONFIG_FILENAME} file:"
    echo
    print_error "  ${CONFIG_FILE}"
    exit 1
fi

autoload is-at-least
if (( VERSION_GTE_29 != 1 )); then
    print_error "Configuration error. Bitcoin core version must be 29.0 or newer because this script depends on cmake build execution."
    exit 1
fi
if (( VERSION_IS_BRANCH )) && [[ $BUILD_OR_DOWNLOAD == "download" ]]; then
    print_error "Configuration error. When using download option Bitcoin core version specified must be a version tag (starting with 'v' prefix) and not a branch identifier."
    exit 1
fi

if (( FAST_INSTALL )) && [[ ! -f "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreInstallSuccessful" ]]; then
    print_error "Configuration error. Fast install flag (-f) requires first successfully completing a full install."
    exit 1
fi

if [[ "$OVERRIDE_EXISTING_CONFIG_FILE" == (#i)true && -f "$TARGET_PATH/bitcoin.conf" && \
$(<"$TARGET_PATH/bitcoin.conf") != *"DO NOT EDIT THIS FILE"* ]]; then
    print_error "The configuration file already exists:"
    echo
    print_error "  $TARGET_PATH/bitcoin.conf"
    echo
    print_error "and either was not generated by this script or was manually edited."
    print_error "Delete the existing bitcoin.conf file (or set generate_config_file to false) and re-run this script to continue."
    exit 1
fi

if [[ $BUILD_OR_DOWNLOAD == "build" ]] && (( !CLEAN_INSTALL )) && \
[[ "$ENABLE_WALLET" == (#i)true ]] && [[ ! -f "$NODE_BUILDER_APP_SUPPORT_PATH/.bitcoinCoreBuiltWithWalletEnabled" ]]; then
    # Need to do a clean rebuild if build option ENABLE_WALLET is on and previous build didn't
    # have it enabled. Otherwise, there will be build errors.
    print_warning "enable_wallet set to true -- forcing clean install to avoid build errors (overriding)"
    CLEAN_INSTALL=1
fi

########################################
# Sanity check and update configuration dependencies.
INCLUDE_GUI_APP=OFF
if [[ "${BITCOIN_CORE_CONFIG[include_gui_app]:-false}" == (#i)true ]]; then
    INCLUDE_GUI_APP=ON
fi

INCLUDE_TESTS=OFF
if [[ "${BITCOIN_CORE_CONFIG[include_run_tests]:-false}" == (#i)true ]]; then
    INCLUDE_TESTS=ON
fi

ENABLE_INBOUND=${BITCOIN_CORE_CONFIG[enable_inbound_connections]:-false}
CONFIG_LISTENPORT=${BITCOIN_CORE_CONFIG[listen_port]:-8333}

ENABLE_IPV4_CONN=${BITCOIN_CORE_CONFIG[enable_ipv4_connections]:-false}
ENABLE_IPV6_CONN=${BITCOIN_CORE_CONFIG[enable_ipv6_connections]:-false}
ENABLE_TOR_CONN=${BITCOIN_CORE_CONFIG[enable_tor_connections]:-false}
if [[ "$ENABLE_IPV4_CONN" == (#i)false ]] && [[ "$ENABLE_IPV6_CONN" == (#i)false ]] && [[ "$ENABLE_TOR_CONN" == (#i)false ]]; then
    print_error "Configuration error. One or more of these must be enabled: enable_ipv4_connections, enable_ipv6_connections, enable_tor_connections"
    exit 1
fi

EXT_IPV4_DISCOVERY_METHOD=${BITCOIN_CORE_CONFIG[external_ipv4_discovery_method]:-undefined}
if [[ "$EXT_IPV4_DISCOVERY_METHOD" != (#i)(natpmp|upnp|natpmp\+upnp|upnp\+natpmp|static) ]]; then
    print_error "Configuration error. external_ipv4_discovery_method must be: natpmp, upnp, natpmp+upnp, or static"
    exit 1
fi
EXT_IPV6_DISCOVERY_METHOD=${BITCOIN_CORE_CONFIG[external_ipv6_discovery_method]:-undefined}
if [[ "$EXT_IPV6_DISCOVERY_METHOD" != (#i)(auto|static) ]]; then
    print_error "Configuration error. external_ipv6_discovery_method must be: auto or static"
    exit 1
fi

# Force IP discovery methods to internal disable selection if inbound connections aren't enabled. Note
# inbound Tor connections are automatically discovered via the Tor hidden service.
if [[ "$ENABLE_INBOUND" == (#i)false ]]; then
    EXT_IPV4_DISCOVERY_METHOD="disable"
    EXT_IPV6_DISCOVERY_METHOD="disable"
else
    if [[ "$ENABLE_IPV4_CONN" == (#i)false ]]; then
        EXT_IPV4_DISCOVERY_METHOD="disable"
    fi
    if [[ "$ENABLE_IPV6_CONN" == (#i)false ]]; then
        EXT_IPV6_DISCOVERY_METHOD="disable"
    fi
fi

typeset -i CONFIG_DNS=0
typeset -i CONFIG_DNSSEED=0
typeset -i CONFIG_PEERBLOOMFILTERS=0

typeset -i CONFIG_DISCOVER=0
typeset -i CONFIG_NATPMP=0
typeset -i CONFIG_UPNP=0
typeset -i CONFIG_EXTERNALIPV4=""
typeset -i CONFIG_EXTERNALIPV6=""
typeset -i CONFIG_EXTERNALPORT=${BITCOIN_CORE_CONFIG[external_port]:-8333}

if [[ "$EXT_IPV4_DISCOVERY_METHOD" == (#i)(natpmp) ]]; then
    CONFIG_DISCOVER=1
    CONFIG_NATPMP=1
elif [[ "$EXT_IPV4_DISCOVERY_METHOD" == (#i)(upnp) ]]; then
    CONFIG_DISCOVER=1
    CONFIG_UPNP=1
elif [[ "$EXT_IPV4_DISCOVERY_METHOD" == (#i)(natpmp\+upnp|upnp\+natpmp) ]]; then
    CONFIG_DISCOVER=1
    CONFIG_NATPMP=1
    CONFIG_UPNP=1
elif [[ "$EXT_IPV4_DISCOVERY_METHOD" == (#i)(static) ]]; then
    CONFIG_EXTERNALIPV4=${BITCOIN_CORE_CONFIG[external_ipv4_addr]:-}
    if [[ "$CONFIG_EXTERNALIPV4" == "203.0.113.1" ]]; then
        print_error "Configuration error. external_ipv4_addr must be the publicly accessible IP address (placeholder value of 203.0.113.1 not valid)"
        exit 1
    fi
fi

if [[ "$EXT_IPV6_DISCOVERY_METHOD" == (#i)(auto) ]]; then
    CONFIG_DISCOVER=1
elif [[ "$EXT_IPV6_DISCOVERY_METHOD" == (#i)(static) ]]; then
    CONFIG_EXTERNALIPV6=${BITCOIN_CORE_CONFIG[external_ipv6_addr]:-}
    if [[ "$CONFIG_EXTERNALIPV6" == "[2001:db8::1]" ]]; then
        print_error "Configuration error. external_ipv6_addr must be the publicly accessible IP address (placeholder value of [2001:db8::1] not valid)"
        exit 1
    fi
fi

# Electrs server requires Bitcoin Core to be configured with:
#
#   server=1
#   blockfilterindex=1
#   txindex=1
#   prune=0
#   whitelist=127.0.0.1
#
# so we force/override those config values if Electrs server building is enabled.
if [[ "${ELECTRS_SERVER_CONFIG[enable_install]:-false}" == (#i)true ]]; then
    if [[ "${BITCOIN_CORE_CONFIG[enable_local_rpc]:-false}" != (#i)true ]]; then
        print_warning "Electrs server compatibility requires Bitcoin Core to be configured with enable_local_rpc (overriding)"
        BITCOIN_CORE_CONFIG[enable_local_rpc]="true"
    fi
    if [[ "${BITCOIN_CORE_RAW[blockfilterindex]:-0}" != "1" ]]; then
        print_warning "Electrs server compatibility requires Bitcoin Core to be configured with blockfilterindex=1 (overriding)"
        BITCOIN_CORE_RAW[blockfilterindex]="1"
    fi
    if [[ "${BITCOIN_CORE_RAW[txindex]:-0}" != "1" ]]; then
        print_warning "Electrs server compatibility requires Bitcoin Core to be configured with txindex=1 (overriding)"
        BITCOIN_CORE_RAW[txindex]="1"
    fi
    if [[ "${BITCOIN_CORE_RAW[prune]:-0}" != "0" ]]; then
        print_warning "Electrs server compatibility requires Bitcoin Core to be configured with prune=0 (overriding)"
        BITCOIN_CORE_RAW[prune]="0"
    fi
    if [[ "${BITCOIN_CORE_RAW[whitelist]:-0}" != "127.0.0.1" ]]; then
        print_warning "Electrs server compatibility requires Bitcoin Core to be configured with whitelist=127.0.0.1 (overriding)"
        BITCOIN_CORE_RAW[whitelist]="127.0.0.1"
    fi
fi

########################################
if [[ $BUILD_OR_DOWNLOAD == "download" ]]; then
    DOWNLOAD_URL=${BITCOIN_CORE_CONFIG[download_url]}
    ARCH=$(uname -m)
    DOWNLOAD_BIN_URL="$DOWNLOAD_URL/bitcoin-core-$VERSION_CLEAN/bitcoin-$VERSION_CLEAN-$ARCH-apple-darwin.tar.gz"
    DOWNLOAD_APP_URL="$DOWNLOAD_URL/bitcoin-core-$VERSION_CLEAN/bitcoin-$VERSION_CLEAN-$ARCH-apple-darwin.zip"
    CHECKSUM_URL="$DOWNLOAD_URL/bitcoin-core-$VERSION_CLEAN/SHA256SUMS"

    STARTUP_TXT=$(cat <<EOF

This script will download the Bitcoin Core v$VERSION_CLEAN executables from:

  ${DOWNLOAD_BIN_URL}
  ${DOWNLOAD_APP_URL}

and install them into:

  ${TARGET_PATH}/

EOF
)
elif [[ $BUILD_OR_DOWNLOAD == "build" ]]; then
    REPO_URL=${BITCOIN_CORE_CONFIG[repo_url]}
    if (( VERSION_IS_BRANCH )); then
        VERBOSE_VERSION="branch $VERSION"
    else
        VERBOSE_VERSION="tag $VERSION"
    fi
    STARTUP_TXT=$(cat <<EOF

This script will git clone the Bitcoin Core project $VERBOSE_VERSION from:

  ${REPO_URL}

and then build, install, and start the executables from:

  ${TARGET_PATH}/

EOF
)
else
    print_error "Configuration error. build_or_download must be: build or download"
    exit 1
fi

if (( UNINSTALL )); then
    echo
    read "REPLY?This will stop Bitcoin Core and uninstall it from your Mac. Uninstall? (y/n) "
    if [[ "$REPLY" == (#i)y ]]; then
        uninstall_bitcoin_core
    fi
elif (( FAST_INSTALL )); then
    # Skips: install_main_dependencies and install_build_dependencies.
    echo
    echo "Fast installing changes only for $TARGET_PATH ($VERSION)."
    echo
    print_info_bold "Stopping services and server..."
    stop_bitcoin_core; stop_tor
    create_target_dirs "$TARGET_PATH" "$NODE_BUILDER_APP_SUPPORT_PATH" "$BUILD_LOGS_DIR" || exit $?

    if [[ $BUILD_OR_DOWNLOAD == "download" ]]; then
        download_bin_and_app "$DOWNLOAD_BIN_URL" "$DOWNLOAD_APP_URL" "$CHECKSUM_URL"
    elif [[ $BUILD_OR_DOWNLOAD == "build" ]]; then
        build_bitcoin_core "$REPO_URL"
    else
        exit 1
    fi
    install_bitcoin_core "$BUILD_OR_DOWNLOAD"
    install_config; install_launchd_plist; install_helper_scripts
    print_success "Fast build/download installation completed."
    echo
    print_info_bold "Starting services and server..."
    start_tor; start_bitcoin_core
    generate_readme
else
    my_tput_clear
    echo "$STARTUP_TXT"
    if [ -t 0 ]; then   # if invoked from tty, then prompt first.
        echo
        read "REPLY?Install and start? (y/n) "
    else                # else (invoked via pipe, etc.) wait a few seconds.
        REPLY="y"
        echo "Starting installation in 5 seconds..."
        my_sleep 5
    fi
    if [[ "$REPLY" == (#i)y ]]; then
        echo
        print_info_bold "Stopping services and server..."
        stop_bitcoin_core; stop_tor
        create_target_dirs "$TARGET_PATH" "$NODE_BUILDER_APP_SUPPORT_PATH" "$BUILD_LOGS_DIR" || exit $?
        install_main_dependencies

        if [[ $BUILD_OR_DOWNLOAD == "download" ]]; then
            download_bin_and_app "$DOWNLOAD_BIN_URL" "$DOWNLOAD_APP_URL" "$CHECKSUM_URL"
        elif [[ $BUILD_OR_DOWNLOAD == "build" ]]; then
            install_build_dependencies; build_bitcoin_core "$REPO_URL"
        else
            exit 1
        fi
        install_bitcoin_core "$BUILD_OR_DOWNLOAD"
        install_config; install_launchd_plist; install_helper_scripts
        print_success "Installation completed."
        echo
        print_info_bold "Starting services and server..."
        start_tor; start_bitcoin_core
        generate_readme
    fi
fi
exit 0