#!/usr/bin/env zsh
#
# Amor et potentia oppressis.
#

########################################
NODE_BUILDER_VERSION="1.0.1"

NODE_BUILDER_APP_SUPPORT_PATH="$HOME/Library/Application Support/Bitcoin Mac Node Builder"
# Directory for launchd helper scripts (must reside on internal drive, not external volume).
LAUNCHD_HELPER_DIR="$NODE_BUILDER_APP_SUPPORT_PATH/launchd"
BUILD_LOGS_DIR="$NODE_BUILDER_APP_SUPPORT_PATH/build-logs"

########################################
typeset -g _SCRIPT_DIR="${0:A:h}"
if [[ -f "$_SCRIPT_DIR/_utils.zsh" ]]; then
    source "$_SCRIPT_DIR/_utils.zsh"
else
    echo "Error: _utils.zsh not found (should be in same directory as this script)"
    exit 1
fi

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
    pv_exec -l "Updating brew and all formulae..." \
        brew update \
    || return $?
    return 0
}

my_brew_cleanup() {
    emulate -L zsh
    local -x HOMEBREW_NO_AUTO_UPDATE=1
    pv_exec -l "Cleaning up brew..." \
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
            pv_exec -l "Installing $formula via brew..." -o "$outfile" \
                brew install --formula "$formula" \
            || return $?
        elif [[ " ${outdated[@]} " == *" $formula "* ]]; then
            pv_exec -l "Upgrading $formula via brew..." -o "$outfile" \
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
            pv_exec -l "Uninstalling $formula via brew..." -o "$outfile" \
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
    pv_exec -l "Starting $service service..." \
        brew services start "$service" \
    || return $?
    return 0
}

my_brew_services_restart() {
    emulate -L zsh
    local service=$1
    pv_exec -l "Restarting $service service..." \
        brew services restart "$service" \
    || return $?
    return 0
}

my_brew_services_stop() {
    emulate -L zsh
    local service=$1
    pv_exec -l "Stopping $service service..." \
        brew services stop "$service" \
    || return $?
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
        pv_exec -l "Installing homebrew..." \
            /bin/bash -c "$(curl -fsSL https://raw.githubusercontent.com/Homebrew/install/HEAD/install.sh)" \
        || exit $?
        # Direct technique if pv_exec is failing for some reason:
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

    local config_file="$1"
    if [[ ! -f "$config_file" ]]; then
        print_error "Error: $config_file not found"
        exit 1
    fi
    typeset -g CONFIG_YAML=$(<"$config_file")

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
