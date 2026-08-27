#!/usr/bin/env bash
set -Eeuo pipefail
IFS=$'\n\t'

readonly SCRIPT_VERSION="2.0.0"
readonly GOST_VERSION="3.2.6"
readonly MAX_PORTS_PER_BATCH="50"
readonly GOST_BIN="${GOST_MANAGER_GOST_BIN:-/usr/local/bin/gost}"
readonly SERVICE_DIR="${GOST_MANAGER_SERVICE_DIR:-/etc/systemd/system}"
readonly CONFIG_DIR="${GOST_MANAGER_CONFIG_DIR:-/etc/gost-forward-manager}"
readonly SERVICE_PREFIX="gost-forward"
readonly GOST_RELEASE_BASE="https://github.com/go-gost/gost/releases/download/v${GOST_VERSION}"
readonly GOST_SHA256_AMD64="b39037b0380ea001fb3c0c28441c2e10bfc694f90682739a65b53e55dce5238b"
readonly GOST_SHA256_ARM64="f674c8f4a033dc1dfd4f0d5e9602fbe5b0d0f81307bf3794f44b5b5d6d622eae"

if [[ -t 1 ]]; then
    readonly RED=$'\033[0;31m'
    readonly GREEN=$'\033[0;32m'
    readonly YELLOW=$'\033[1;33m'
    readonly CYAN=$'\033[0;36m'
    readonly BOLD=$'\033[1m'
    readonly RESET=$'\033[0m'
else
    readonly RED=""
    readonly GREEN=""
    readonly YELLOW=""
    readonly CYAN=""
    readonly BOLD=""
    readonly RESET=""
fi

info() { printf '%s[INFO]%s %s\n' "$CYAN" "$RESET" "$*"; }
success() { printf '%s[OK]%s %s\n' "$GREEN" "$RESET" "$*"; }
warn() { printf '%s[WARN]%s %s\n' "$YELLOW" "$RESET" "$*" >&2; }
die() { printf '%s[ERROR]%s %s\n' "$RED" "$RESET" "$*" >&2; exit 1; }

on_error() {
    local exit_code=$?
    local line_number=${1:-unknown}
    printf '%s[ERROR]%s Operation stopped at line %s with exit code %s.\n' "$RED" "$RESET" "$line_number" "$exit_code" >&2
    exit "$exit_code"
}
trap 'on_error "$LINENO"' ERR

show_header() {
    printf '\n%sGOST v%s Automatic Direct Tunnel%s\n' "$BOLD" "$GOST_VERSION" "$RESET"
    printf 'Script version: %s | Same TCP ports on Iran and foreign servers\n\n' "$SCRIPT_VERSION"
}

show_setup_header() {
    printf '\n%sTunnel Configuration%s\n' "$BOLD" "$RESET"
    printf 'Enter only the foreign server IPv4 address and the TCP ports.\n\n'
}

show_help() {
    cat <<EOF
Usage:
  sudo bash $(basename "$0")

GOST v${GOST_VERSION} is installed or verified first. The setup then asks only for:
  1. Foreign server IPv4 address
  2. TCP ports separated by commas, for example: 443,8443,2053

Each port listens on the Iran server and forwards to the same port on the foreign server.
EOF
}

require_root() {
    [[ ${EUID:-$(id -u)} -eq 0 ]] || die "Run this script with sudo or as root."
}

command_exists() {
    command -v "$1" >/dev/null 2>&1
}

validate_ipv4() {
    local ip=${1:-}
    local octet
    local -a octets=()
    IFS='.' read -r -a octets <<< "$ip"
    [[ ${#octets[@]} -eq 4 ]] || return 1
    for octet in "${octets[@]}"; do
        [[ $octet =~ ^[0-9]{1,3}$ ]] || return 1
        (( 10#$octet <= 255 )) || return 1
    done
}

validate_port() {
    local port=${1:-}
    [[ $port =~ ^[0-9]{1,5}$ ]] && (( 10#$port >= 1 && 10#$port <= 65535 ))
}

parse_port_list() {
    local raw_input=${1:-}
    local output_var=$2
    local -n output_ref=$output_var
    local compact_input=${raw_input//[[:space:]]/}
    local -a raw_ports=()
    local -A seen_ports=()
    local raw_port normalized_port
    output_ref=()
    [[ $compact_input =~ ^[0-9]+(,[0-9]+)*$ ]] || return 1
    IFS=',' read -r -a raw_ports <<< "$compact_input"
    (( ${#raw_ports[@]} >= 1 && ${#raw_ports[@]} <= MAX_PORTS_PER_BATCH )) || return 1
    for raw_port in "${raw_ports[@]}"; do
        validate_port "$raw_port" || return 1
        normalized_port=$((10#$raw_port))
        [[ ! ${seen_ports[$normalized_port]+exists} ]] || return 2
        seen_ports[$normalized_port]=1
        output_ref+=("$normalized_port")
    done
}

prompt_foreign_ip() {
    local output_var=$1
    local value=""
    while true; do
        read -r -p "Foreign server IPv4 address: " value
        if validate_ipv4 "$value"; then
            printf -v "$output_var" '%s' "$value"
            return 0
        fi
        warn "Enter a valid IPv4 address."
    done
}

prompt_ports() {
    local output_var=$1
    local value=""
    local parse_status
    while true; do
        read -r -p "TCP ports on both servers (comma-separated): " value
        if parse_port_list "$value" "$output_var"; then
            return 0
        else
            parse_status=$?
        fi
        if (( parse_status == 2 )); then
            warn "A port number is duplicated. Enter each port only once."
        else
            warn "Enter up to ${MAX_PORTS_PER_BATCH} ports from 1 to 65535. Example: 443,8443,2053"
        fi
    done
}

ports_to_csv() {
    local old_ifs=$IFS
    IFS=','
    printf '%s' "$*"
    IFS=$old_ifs
}

ensure_dependencies() {
    local -a required_commands=(curl tar sha256sum install systemctl ss timeout grep head journalctl)
    local -a missing_commands=()
    local cmd
    for cmd in "${required_commands[@]}"; do
        command_exists "$cmd" || missing_commands+=("$cmd")
    done
    if (( ${#missing_commands[@]} == 0 )); then
        return 0
    fi
    command_exists apt-get || die "Required commands are missing and apt-get was not found: ${missing_commands[*]}"
    info "Installing dependencies..."
    apt-get update
    DEBIAN_FRONTEND=noninteractive apt-get install -y curl ca-certificates tar coreutils iproute2 systemd
    for cmd in "${required_commands[@]}"; do
        command_exists "$cmd" || die "Command $cmd was not found after installing dependencies."
    done
}

detect_gost_artifact() {
    local output_arch_var=$1
    local output_sha_var=$2
    local machine
    local selected_arch=""
    local selected_sha=""
    machine=$(uname -m)
    case "$machine" in
        x86_64|amd64)
            selected_arch="amd64"
            selected_sha="$GOST_SHA256_AMD64"
            ;;
        aarch64|arm64)
            selected_arch="arm64"
            selected_sha="$GOST_SHA256_ARM64"
            ;;
        *)
            die "Architecture $machine is not supported. Only AMD64 and ARM64 are supported."
            ;;
    esac
    printf -v "$output_arch_var" '%s' "$selected_arch"
    printf -v "$output_sha_var" '%s' "$selected_sha"
}

current_gost_version() {
    [[ -x $GOST_BIN ]] || return 1
    "$GOST_BIN" -V 2>&1 | head -n 1
}

install_gost() {
    ensure_dependencies
    local current_version=""
    current_version=$(current_gost_version 2>/dev/null || true)
    if [[ $current_version == *"gost v${GOST_VERSION}"* ]]; then
        success "GOST v${GOST_VERSION} is already installed."
        return 0
    fi
    local gost_arch=""
    local gost_sha=""
    detect_gost_artifact gost_arch gost_sha
    local temp_dir archive_path extracted_binary download_url
    temp_dir=$(mktemp -d -t gost-v3-install.XXXXXX)
    archive_path="$temp_dir/gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz"
    extracted_binary="$temp_dir/gost"
    download_url="${GOST_RELEASE_BASE}/gost_${GOST_VERSION}_linux_${gost_arch}.tar.gz"
    info "Downloading GOST v${GOST_VERSION} for ${gost_arch}..."
    curl --fail --location --silent --show-error --retry 3 --retry-delay 2 "$download_url" -o "$archive_path"
    printf '%s  %s\n' "$gost_sha" "$archive_path" | sha256sum -c -
    tar --no-same-owner -xzf "$archive_path" -C "$temp_dir" gost
    [[ -x $extracted_binary ]] || chmod 0755 "$extracted_binary"
    if [[ -e $GOST_BIN ]]; then
        local backup_path="${GOST_BIN}.backup.$(date +%Y%m%d%H%M%S)"
        cp -a "$GOST_BIN" "$backup_path"
        warn "The previous binary was backed up to $backup_path."
    fi
    install -D -m 0755 "$extracted_binary" "$GOST_BIN"
    rm -f "$archive_path" "$extracted_binary"
    rmdir "$temp_dir" 2>/dev/null || true
    current_version=$(current_gost_version 2>/dev/null || true)
    [[ $current_version == *"gost v${GOST_VERSION}"* ]] || die "The installed version could not be verified: $current_version"
    success "$current_version was installed."
}

service_name_for_port() {
    printf '%s-%s.service' "$SERVICE_PREFIX" "$1"
}

service_path_for_port() {
    printf '%s/%s' "$SERVICE_DIR" "$(service_name_for_port "$1")"
}

config_path_for_port() {
    printf '%s/%s.conf' "$CONFIG_DIR" "$1"
}

port_is_listening() {
    local port=$1
    ss -H -ltn "sport = :$port" 2>/dev/null | grep -q .
}

test_foreign_target() {
    local foreign_ip=$1
    local port=$2
    if timeout 5 bash -c "exec 3<>/dev/tcp/${foreign_ip}/${port}" 2>/dev/null; then
        success "Foreign target ${foreign_ip}:${port} is reachable."
    else
        warn "Could not reach ${foreign_ip}:${port}. The service will still be created; check the foreign firewall and Xray listener."
    fi
}

write_service_metadata() {
    local port=$1
    local foreign_ip=$2
    install -d -m 0700 "$CONFIG_DIR" || return 1
    local metadata_path temp_metadata
    metadata_path=$(config_path_for_port "$port")
    temp_metadata=$(mktemp "${CONFIG_DIR}/.${port}.conf.XXXXXX") || return 1
    if ! {
        printf 'LISTEN_PORT=%q\n' "$port"
        printf 'FOREIGN_HOST=%q\n' "$foreign_ip"
        printf 'FOREIGN_PORT=%q\n' "$port"
    } > "$temp_metadata"; then
        rm -f "$temp_metadata" || true
        return 1
    fi
    if ! install -m 0600 "$temp_metadata" "$metadata_path"; then
        rm -f "$temp_metadata" || true
        return 1
    fi
    rm -f "$temp_metadata" || return 1
}

write_service_file() {
    local port=$1
    local foreign_ip=$2
    local service_name service_path temp_service
    service_name=$(service_name_for_port "$port")
    service_path=$(service_path_for_port "$port")
    install -d -m 0755 "$SERVICE_DIR" || return 1
    temp_service=$(mktemp "${SERVICE_DIR}/.${service_name}.XXXXXX") || return 1
    if ! {
        cat > "$temp_service" <<EOF
[Unit]
Description=GOST TCP Forward :${port} to ${foreign_ip}:${port}
After=network-online.target
Wants=network-online.target
[Service]
Type=simple
User=root
ExecStart=${GOST_BIN} -L tcp://0.0.0.0:${port}/${foreign_ip}:${port}
Restart=always
RestartSec=3s
LimitNOFILE=1048576
NoNewPrivileges=true
PrivateTmp=true
ProtectHome=true
ProtectSystem=strict
ProtectKernelTunables=true
ProtectKernelModules=true
ProtectControlGroups=true
RestrictSUIDSGID=true
LockPersonality=true
RestrictRealtime=true
RestrictAddressFamilies=AF_INET AF_INET6 AF_UNIX
CapabilityBoundingSet=CAP_NET_BIND_SERVICE
AmbientCapabilities=CAP_NET_BIND_SERVICE
[Install]
WantedBy=multi-user.target
EOF
    }; then
        rm -f "$temp_service" || true
        return 1
    fi
    if ! install -m 0644 "$temp_service" "$service_path"; then
        rm -f "$temp_service" || true
        return 1
    fi
    rm -f "$temp_service" || return 1
}

backup_current_configuration() {
    local transaction_dir=$1
    shift
    local -a ports=("$@")
    install -d -m 0700 "$transaction_dir/services" "$transaction_dir/configs" "$transaction_dir/active" "$transaction_dir/enabled"
    local port service_name service_path config_path
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        service_path=$(service_path_for_port "$port")
        config_path=$(config_path_for_port "$port")
        if [[ -f $service_path ]]; then
            cp -a "$service_path" "$transaction_dir/services/$service_name"
            systemctl is-active --quiet "$service_name" && touch "$transaction_dir/active/$service_name" || true
            systemctl is-enabled --quiet "$service_name" && touch "$transaction_dir/enabled/$service_name" || true
        fi
        [[ ! -f $config_path ]] || cp -a "$config_path" "$transaction_dir/configs/${port}.conf"
    done
}

rollback_configuration() {
    local transaction_dir=$1
    shift
    local -a ports=("$@")
    local port service_name service_path config_path
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        service_path=$(service_path_for_port "$port")
        config_path=$(config_path_for_port "$port")
        systemctl disable --now "$service_name" >/dev/null 2>&1 || true
        if [[ -f $transaction_dir/services/$service_name ]]; then
            install -m 0644 "$transaction_dir/services/$service_name" "$service_path" || true
            if [[ -f $transaction_dir/configs/${port}.conf ]]; then
                install -d -m 0700 "$CONFIG_DIR" || true
                install -m 0600 "$transaction_dir/configs/${port}.conf" "$config_path" || true
            else
                rm -f "$config_path" || true
            fi
        else
            rm -f "$service_path" "$config_path" || true
        fi
    done
    systemctl daemon-reload >/dev/null 2>&1 || true
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        [[ ! -f $transaction_dir/enabled/$service_name ]] || systemctl enable "$service_name" >/dev/null 2>&1 || true
        [[ ! -f $transaction_dir/active/$service_name ]] || systemctl start "$service_name" >/dev/null 2>&1 || true
    done
    rm -rf -- "$transaction_dir"
}

open_ufw_ports() {
    local -a ports=("$@")
    if ! command_exists ufw; then
        info "UFW is not installed. No firewall changes were made."
        return 0
    fi
    if ! ufw status 2>/dev/null | head -n 1 | grep -qi 'active'; then
        info "UFW is inactive. No firewall changes were made."
        return 0
    fi
    local port
    for port in "${ports[@]}"; do
        if ufw allow "${port}/tcp" >/dev/null; then
            success "Allowed TCP port ${port} in UFW."
        else
            warn "Failed to allow TCP port ${port} in UFW. Check it manually."
        fi
    done
}

configure_forwards() {
    local foreign_ip=$1
    shift
    local -a ports=("$@")
    local port service_name service_path
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        service_path=$(service_path_for_port "$port")
        if [[ -f $service_path ]]; then
            grep -q '^Description=GOST TCP Forward ' "$service_path" || die "Service file $service_path exists but is not managed by this script."
        elif port_is_listening "$port"; then
            die "TCP port $port is already in use on the Iran server. No changes were made."
        fi
    done
    info "Checking foreign targets..."
    for port in "${ports[@]}"; do
        test_foreign_target "$foreign_ip" "$port" &
    done
    wait || true
    local transaction_dir
    transaction_dir=$(mktemp -d -t gost-forward-transaction.XXXXXX)
    backup_current_configuration "$transaction_dir" "${ports[@]}"
    for port in "${ports[@]}"; do
        if ! write_service_file "$port" "$foreign_ip" || ! write_service_metadata "$port" "$foreign_ip"; then
            rollback_configuration "$transaction_dir" "${ports[@]}"
            die "Failed to write service files. The previous configuration was restored."
        fi
    done
    if ! systemctl daemon-reload; then
        rollback_configuration "$transaction_dir" "${ports[@]}"
        die "Failed to reload systemd. The previous configuration was restored."
    fi
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        if ! systemctl enable "$service_name" >/dev/null || ! systemctl restart "$service_name"; then
            journalctl -u "$service_name" -n 50 --no-pager || true
            rollback_configuration "$transaction_dir" "${ports[@]}"
            die "Service $service_name failed to start. The previous configuration was restored."
        fi
    done
    sleep 1
    for port in "${ports[@]}"; do
        service_name=$(service_name_for_port "$port")
        if ! systemctl is-active --quiet "$service_name"; then
            journalctl -u "$service_name" -n 50 --no-pager || true
            rollback_configuration "$transaction_dir" "${ports[@]}"
            die "Service $service_name is not active. The previous configuration was restored."
        fi
    done
    rm -rf -- "$transaction_dir"
    open_ufw_ports "${ports[@]}"
    printf '\n%-12s %-22s %s\n' "IRAN PORT" "FOREIGN TARGET" "SERVICE"
    for port in "${ports[@]}"; do
        printf '%-12s %-22s %s\n' "$port" "${foreign_ip}:${port}" "$(service_name_for_port "$port")"
    done
    success "Configured ${#ports[@]} direct TCP forward(s): $(ports_to_csv "${ports[@]}")"
    printf '\nThe foreign server must allow TCP connections from the Iran server IP on the same ports.\n'
    printf 'Existing managed ports not included in this run were left unchanged.\n'
}

main() {
    case "${1:-}" in
        "") ;;
        -h|--help|help)
            show_help
            return 0
            ;;
        -v|--version)
            printf '%s\n' "$SCRIPT_VERSION"
            return 0
            ;;
        *)
            show_help
            die "Unknown option: $1"
            ;;
    esac
    require_root
    show_header
    install_gost
    show_setup_header
    local foreign_ip=""
    local -a ports=()
    prompt_foreign_ip foreign_ip
    prompt_ports ports
    configure_forwards "$foreign_ip" "${ports[@]}"
}

if [[ ${BASH_SOURCE[0]} == "$0" ]]; then
    main "$@"
fi
