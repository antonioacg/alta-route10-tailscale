#!/bin/sh
# Tailscale for Alta Labs Route 10 — self-contained installer
# Usage: sh setup.sh [status|recover|uninstall]

VERSION="1.82.0"
BIN_DIR="/a/tailscale"
STATE_FILE="/cfg/tailscaled.state"
ENV_FILE="/cfg/tailscale.env"
POST_CFG="/cfg/tailscale-post-cfg.sh"
UPDATE_SCRIPT="/cfg/tailscale-update.sh"
INIT_SCRIPT="/etc/init.d/tailscale"
WAN_IFACE="eth3"
LAN_IFACE="br-lan"

OK()   { echo "  [OK] $1"; }
WARN() { echo "  [!!] $1"; }
INFO() { echo "  -> $1"; }
DIE()  { echo "  [FATAL] $1"; exit 1; }

check_internet() {
    ping -c1 -W3 8.8.8.8 >/dev/null 2>&1
}

wait_internet() {
    _limit="${1:-30}"
    n=0
    while [ $n -lt "$_limit" ]; do
        check_internet && return 0
        sleep 2
        n=$((n + 2))
    done
    return 1
}

cleanup_iptables() {
    iptables -D INPUT -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o "$LAN_IFACE" -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o "$WAN_IFACE" -j MASQUERADE 2>/dev/null
}

cleanup_ip_rules() {
    ip rule del fwmark 0x3d00/0x3f00 blackhole 2>/dev/null
    ip rule del fwmark 0x3e00/0x3f00 unreachable 2>/dev/null
    ip rule del fwmark 0x100/0x3f00 unreachable 2>/dev/null
}

add_iptables() {
    iptables -I INPUT -i tailscale0 -j ACCEPT
    iptables -I FORWARD -o tailscale0 -j ACCEPT
    iptables -I FORWARD -i tailscale0 -j ACCEPT
    iptables -t nat -I POSTROUTING -s 100.64.0.0/10 -o "$LAN_IFACE" -j MASQUERADE
    if [ "$MODE" = "exit" ] || [ "$MODE" = "both" ]; then
        iptables -t nat -I POSTROUTING -s 100.64.0.0/10 -o "$WAN_IFACE" -j MASQUERADE
    fi
}

write_init_script() {
    _target="${1:-$INIT_SCRIPT}"
    mkdir -p /var/run/tailscale
    cat > "$_target" << INITEOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=1

start_service() {
    mkdir -p /var/run/tailscale
    procd_open_instance
    procd_set_param name tailscaled
    procd_set_param command ${BIN_DIR}/tailscaled
    procd_append_param command --state ${STATE_FILE}
    procd_append_param command --socket /var/run/tailscale/tailscaled.sock
    procd_append_param command --port 41641
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    ${BIN_DIR}/tailscaled --cleanup >/dev/null 2>&1 || true
}
INITEOF
    chmod +x "$_target"
    [ "$_target" = "$INIT_SCRIPT" ] && /etc/init.d/tailscale enable 2>/dev/null
}

# ── Recovery mode ──────────────────────────────────────────

if [ "$1" = "recover" ]; then
    echo ""
    echo "  Tailscale Recovery Mode"
    echo "  Killing tailscaled and cleaning up..."
    echo ""

    kill "$(pidof tailscaled)" 2>/dev/null
    sleep 2
    cleanup_iptables
    cleanup_ip_rules

    if check_internet; then
        OK "Internet restored"
    else
        WARN "Internet still down. Try rebooting the router."
    fi
    exit 0
fi

# ── Uninstall mode ────────────────────────────────────────

if [ "$1" = "uninstall" ]; then
    echo ""
    echo "  Tailscale Uninstall"
    echo "  ===================="
    echo ""

    if [ ! -f "$ENV_FILE" ] && [ ! -x "${BIN_DIR}/tailscaled" ]; then
        echo "  No Tailscale installation found."
        exit 0
    fi

    printf "  Remove all Tailscale configuration? [y/N]: "
    read -r CONFIRM
    [ "$CONFIRM" = "y" ] || [ "$CONFIRM" = "Y" ] || { echo "  Aborting."; exit 0; }

    echo ""
    [ -x "${BIN_DIR}/tailscale" ] && "${BIN_DIR}/tailscale" down 2>/dev/null || true

    if pidof tailscaled >/dev/null 2>&1; then
        INFO "Stopping tailscaled..."
        /etc/init.d/tailscale stop 2>/dev/null || true
        kill -9 "$(pidof tailscaled)" 2>/dev/null || true
        OK "tailscaled stopped"
    fi

    [ -f /etc/init.d/tailscale ] && { /etc/init.d/tailscale disable 2>/dev/null; rm -f /etc/init.d/tailscale; }
    OK "Init script removed"

    INFO "Removing iptables rules..."
    cleanup_iptables
    cleanup_ip_rules
    OK "iptables rules removed"

    INFO "Removing files..."
    rm -rf "$BIN_DIR"
    rm -f "$ENV_FILE" "$STATE_FILE" "$POST_CFG" "$UPDATE_SCRIPT"
    OK "Files removed"

    crontab -l 2>/dev/null | grep -v tailscale-update | crontab - 2>/dev/null
    OK "Auto-update cron removed"

    if [ -f /cfg/post-cfg.sh ]; then
        sed -i '/tailscale-post-cfg/d' /cfg/post-cfg.sh
        sed -i '/Tailscale boot hook/d' /cfg/post-cfg.sh
        OK "Boot hook removed"
    fi

    echo ""
    echo "  Uninstall complete. Reboot recommended."
    echo ""
    exit 0
fi

# ── Status mode ────────────────────────────────────────────

if [ "$1" = "status" ]; then
    echo ""
    echo "  Tailscale Status"
    echo "  ================"
    echo ""

    echo "  -- Files --"
    for f in "$ENV_FILE" "$STATE_FILE" "$POST_CFG" "$UPDATE_SCRIPT"; do
        if [ -f "$f" ]; then OK "$(basename "$f")"; else WARN "$(basename "$f") missing"; fi
    done
    for f in "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"; do
        if [ -f "$f" ]; then OK "$(basename "$f")"; else WARN "$(basename "$f") missing"; fi
    done

    echo ""
    echo "  -- Service --"
    TS_PID=$(pidof tailscaled 2>/dev/null)
    if [ -n "$TS_PID" ]; then OK "tailscaled running (PID $TS_PID)"; else WARN "tailscaled NOT running"; fi
    if [ -f /etc/init.d/tailscale ]; then OK "Init script present"; else WARN "Init script missing (normal after reboot)"; fi
    if ls /etc/rc.d/*tailscale >/dev/null 2>&1; then OK "Autostart enabled"; else WARN "Autostart not enabled"; fi

    echo ""
    echo "  -- Connection --"
    if [ -x "$BIN_DIR/tailscale" ]; then
        TS_STATUS=$("$BIN_DIR/tailscale" status 2>&1)
        if echo "$TS_STATUS" | grep -q "To authenticate"; then
            WARN "Not authenticated"
            echo "$TS_STATUS" | grep "https://login.tailscale.com" | sed 's/^/      /'
        elif echo "$TS_STATUS" | grep -q "stopped"; then
            WARN "Tailscale is stopped"
        else
            OK "Connected"
            echo "$TS_STATUS" | head -3 | sed 's/^/      /'
        fi
    fi

    echo ""
    echo "  -- Firewall --"
    if iptables -v -L INPUT -n 2>/dev/null | grep -q tailscale0; then OK "INPUT rule"; else WARN "INPUT rule missing"; fi
    FORWARD_COUNT=$(iptables -v -L FORWARD -n 2>/dev/null | grep -c tailscale0)
    if [ "$FORWARD_COUNT" -ge 2 ]; then OK "FORWARD rules ($FORWARD_COUNT)"; else WARN "FORWARD rules missing"; fi
    if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "100.64"; then OK "NAT MASQUERADE"; else WARN "NAT MASQUERADE missing"; fi

    echo ""
    echo "  -- Config --"
    if [ -f "$ENV_FILE" ]; then
        # shellcheck source=/dev/null
        . "$ENV_FILE"
        [ -n "$TAILSCALE_VERSION" ] && OK "Version: $TAILSCALE_VERSION"
        [ -n "$MODE" ] && OK "Mode: $MODE"
        [ -n "$SUBNET" ] && OK "Subnet: $SUBNET"
    fi

    echo ""
    if crontab -l 2>/dev/null | grep -q tailscale-update; then OK "Auto-update cron installed"; else WARN "No auto-update cron"; fi

    echo ""
    exit 0
fi

# ── Main Install ───────────────────────────────────────────

echo ""
echo "  ============================================"
echo "   Tailscale for Alta Labs Route 10"
echo "   Installer v${VERSION}"
echo "  ============================================"
echo ""

INFO "Running preflight checks..."

[ ! -d /cfg ] && DIE "/cfg/ not found. Is this an Alta Labs router?"
[ ! -c /dev/net/tun ] && DIE "/dev/net/tun not found. TUN support required."
[ ! -d /a ] && DIE "/a partition not found. Need /a for binary storage."

DF_A=$(df -m /a 2>/dev/null | tail -1 | awk '{print $4}')
[ -n "$DF_A" ] && [ "$DF_A" -lt 60 ] && DIE "Only ${DF_A}MB free on /a. Need at least 60MB."

check_internet || DIE "No internet. Fix WAN before running this."
OK "Preflight checks passed"

echo ""
echo "  Select a mode:"
echo ""
echo "  1) Subnet router"
echo "     Access your LAN devices (192.168.1.x) from anywhere via Tailscale."
echo "     Your phone on cell data can reach printers, servers, cameras, etc."
echo ""
echo "  2) Exit node"
echo "     Route all traffic from a remote device through your home internet."
echo "     Appears as if browsing from home."
echo ""
echo "  3) Both (recommended)"
echo "     Subnet routing + exit node. Full remote access."
echo ""
printf "  Mode [1/2/3]: "
read -r MODE_NUM

case "$MODE_NUM" in
    1) MODE="subnet";;
    2) MODE="exit";;
    *) MODE="both";;
esac

DEFAULT_SUBNET="192.168.1.0/24"
printf "  LAN subnet to advertise [%s]: " "$DEFAULT_SUBNET"
read -r SUBNET
SUBNET="${SUBNET:-$DEFAULT_SUBNET}"

echo ""
echo "  Configuration:"
echo "    Mode:   $MODE"
echo "    Subnet: $SUBNET"
echo ""

if [ ! -x "$BIN_DIR/tailscaled" ]; then
    INFO "Downloading Tailscale v${VERSION}..."
    mkdir -p "$BIN_DIR"
    wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${VERSION}_arm64.tgz" || {
        DIE "Download failed. Check internet connection."
    }
    tar xzf /tmp/tailscale.tgz -C /tmp
    mv "/tmp/tailscale_${VERSION}_arm64/tailscale" "$BIN_DIR/tailscale"
    mv "/tmp/tailscale_${VERSION}_arm64/tailscaled" "$BIN_DIR/tailscaled"
    chmod +x "$BIN_DIR/tailscale" "$BIN_DIR/tailscaled"
    rm -rf "/tmp/tailscale_${VERSION}_arm64" /tmp/tailscale.tgz
    OK "Binaries installed to $BIN_DIR"
else
    OK "Binaries already installed"
fi

cat > "$ENV_FILE" << EOF
TAILSCALE_VERSION=${VERSION}
MODE=${MODE}
SUBNET=${SUBNET}
BIN_DIR=${BIN_DIR}
EOF
OK "Config written"

kill "$(pidof tailscaled)" 2>/dev/null
sleep 1

INFO "Starting tailscaled..."
mkdir -p /var/run/tailscale
"$BIN_DIR/tailscaled" --state "$STATE_FILE" --socket /var/run/tailscale/tailscaled.sock --port 41641 >/tmp/tsd.log 2>&1 &

n=0
while [ $n -lt 15 ]; do
    pidof tailscaled >/dev/null 2>&1 && break
    sleep 1
    n=$((n + 1))
done
pidof tailscaled >/dev/null 2>&1 || DIE "tailscaled failed to start. Check /tmp/tsd.log"
OK "tailscaled started"

echo ""
echo "  You need to authenticate this device with Tailscale."
echo "  Choose a method:"
echo ""
echo "  1) Login URL (opens in your browser)"
echo "  2) Auth key (from https://login.tailscale.com/admin/settings/keys,"
echo "     or a Headscale pre-auth key when LOGIN_SERVER is set)"
echo ""
printf "  Method [1/2]: "
read -r AUTH_METHOD

UP_FLAGS="--netfilter-mode=off"

# Fork adaptation (EPIC-01): self-hosted control plane. Set LOGIN_SERVER to your
# Headscale URL before running (e.g. `LOGIN_SERVER=https://vpn.example.com sh setup.sh`).
# Empty = upstream behavior (Tailscale SaaS). A Headscale pre-auth key minted with
# --tags applies the node tag server-side — no extra flags needed here.
if [ -n "${LOGIN_SERVER:-}" ]; then
    UP_FLAGS="$UP_FLAGS --login-server=$LOGIN_SERVER"
    INFO "Using self-hosted control plane: $LOGIN_SERVER"
fi

if [ "$MODE" = "subnet" ] || [ "$MODE" = "both" ]; then
    UP_FLAGS="$UP_FLAGS --advertise-routes=$SUBNET"
fi
if [ "$MODE" = "exit" ] || [ "$MODE" = "both" ]; then
    UP_FLAGS="$UP_FLAGS --advertise-exit-node"
fi

if [ "$AUTH_METHOD" = "2" ]; then
    printf "  Enter auth key: "
    read -r AUTH_KEY
    UP_FLAGS="$UP_FLAGS --auth-key=$AUTH_KEY"
    INFO "Authenticating with auth key..."
    # shellcheck disable=SC2086
    "$BIN_DIR/tailscale" up $UP_FLAGS 2>&1 || {
        WARN "tailscale up failed. Killing tailscaled and restoring..."
        kill "$(pidof tailscaled)" 2>/dev/null
        sleep 2
        wait_internet || WARN "Internet did not recover. Reboot the router."
        DIE "tailscale up failed. Check your auth key and try again."
    }
else
    INFO "Starting login..."
    # shellcheck disable=SC2086
    "$BIN_DIR/tailscale" up $UP_FLAGS 2>&1 | while read -r line; do
        echo "  $line"
        # SaaS prints login.tailscale.com/a/…; Headscale prints <server>/register/…
        if echo "$line" | grep -qE "https://[^ ]+/(a|register)/"; then
            echo ""
            echo "  >>> Open this URL in your browser to log in <<<"
            echo ""
        fi
    done
fi

sleep 3
OK "Authenticated"

INFO "Verifying internet connectivity..."
if ! check_internet; then
    WARN "Internet is down! Running automatic recovery..."
    kill "$(pidof tailscaled)" 2>/dev/null
    sleep 3
    cleanup_iptables
    cleanup_ip_rules
    if wait_internet; then
        OK "Internet recovered after cleanup"
    else
        DIE "Internet did not recover. Reboot the router manually."
    fi
    echo ""
    echo "  Setup failed safely — your internet is still working."
    echo "  Run 'sh setup.sh recover' if needed, then try again."
    exit 1
fi
OK "Internet is working"

cleanup_ip_rules

INFO "Adding iptables rules..."
add_iptables
OK "iptables rules added"

write_init_script
OK "Init script installed"

cat > "$POST_CFG" << 'BOOTSCRIPT'
#!/bin/sh
[ -f /cfg/tailscale.env ] || exit 0
. /cfg/tailscale.env
BIN_DIR=${BIN_DIR:-/a/tailscale}
[ -x "$BIN_DIR/tailscaled" ] || exit 0

logger -t ts-boot "starting..."

wait_internet() {
    n=0
    while [ $n -lt 60 ]; do
        ping -c1 -W3 8.8.8.8 >/dev/null 2>&1 && return 0
        sleep 2
        n=$((n + 2))
    done
    return 1
}

wait_internet || { logger -t ts-boot "no internet, aborting"; exit 1; }

if [ ! -f /etc/init.d/tailscale ]; then
    cat > /etc/init.d/tailscale << INITEOF
#!/bin/sh /etc/rc.common
USE_PROCD=1
START=99
STOP=1

start_service() {
    mkdir -p /var/run/tailscale
    procd_open_instance
    procd_set_param name tailscaled
    procd_set_param command ${BIN_DIR}/tailscaled
    procd_append_param command --state /cfg/tailscaled.state
    procd_append_param command --socket /var/run/tailscale/tailscaled.sock
    procd_append_param command --port 41641
    procd_set_param respawn
    procd_set_param stdout 1
    procd_set_param stderr 1
    procd_close_instance
}

stop_service() {
    ${BIN_DIR}/tailscaled --cleanup >/dev/null 2>&1 || true
}
INITEOF
    chmod +x /etc/init.d/tailscale
    /etc/init.d/tailscale enable 2>/dev/null
    logger -t ts-boot "init script recreated"
fi

# Clean stale ip rules from old Tailscale versions that collide with mwan3
ip rule del fwmark 0x3d00/0x3f00 blackhole 2>/dev/null
ip rule del fwmark 0x3e00/0x3f00 unreachable 2>/dev/null
ip rule del fwmark 0x100/0x3f00 unreachable 2>/dev/null

if ! iptables -v -L INPUT -n 2>/dev/null | grep -q tailscale0; then
    iptables -I INPUT -i tailscale0 -j ACCEPT
    iptables -I FORWARD -o tailscale0 -j ACCEPT
    iptables -I FORWARD -i tailscale0 -j ACCEPT
    iptables -t nat -I POSTROUTING -s 100.64.0.0/10 -o br-lan -j MASQUERADE
    if [ "$MODE" = "exit" ] || [ "$MODE" = "both" ]; then
        iptables -t nat -I POSTROUTING -s 100.64.0.0/10 -o eth3 -j MASQUERADE
    fi
    logger -t ts-boot "iptables rules added"
fi

/etc/init.d/tailscale start 2>/dev/null || /etc/init.d/tailscale restart 2>/dev/null

sleep 5
if ! ping -c1 -W3 8.8.8.8 >/dev/null 2>&1; then
    logger -t ts-boot "INTERNET BROKEN after tailscaled, reverting"
    kill "$(pidof tailscaled)" 2>/dev/null
    sleep 2
    iptables -D INPUT -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -o tailscale0 -j ACCEPT 2>/dev/null
    iptables -D FORWARD -i tailscale0 -j ACCEPT 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o br-lan -j MASQUERADE 2>/dev/null
    iptables -t nat -D POSTROUTING -s 100.64.0.0/10 -o eth3 -j MASQUERADE 2>/dev/null
    exit 1
fi

logger -t ts-boot "running, internet OK"
BOOTSCRIPT
chmod +x "$POST_CFG"
OK "Boot script written"

if [ -f /cfg/post-cfg.sh ] && ! grep -q "tailscale-post-cfg" /cfg/post-cfg.sh; then
    sed -i "1a\\# Tailscale boot hook\n[ -x /cfg/tailscale-post-cfg.sh ] \&\& /cfg/tailscale-post-cfg.sh \&" /cfg/post-cfg.sh
    OK "Boot hook added to /cfg/post-cfg.sh"
fi

cat > "$UPDATE_SCRIPT" << 'UPDATESCRIPT'
#!/bin/sh
[ -f /cfg/tailscale.env ] || exit 0
. /cfg/tailscale.env
BIN_DIR=${BIN_DIR:-/a/tailscale}
LATEST=$(wget -qO- 'https://pkgs.tailscale.com/stable/' 2>/dev/null | grep -o 'tailscale_[0-9.]*_arm64\.tgz' | head -1 | grep -o '[0-9]\+\.[0-9]\+\.[0-9]\+')
[ -z "$LATEST" ] && exit 0
if [ "$LATEST" != "$TAILSCALE_VERSION" ]; then
    logger -t ts-update "Updating $TAILSCALE_VERSION -> $LATEST"
    wget -O /tmp/tailscale.tgz "https://pkgs.tailscale.com/stable/tailscale_${LATEST}_arm64.tgz" || exit 1
    tar xzf /tmp/tailscale.tgz -C /tmp || exit 1
    /etc/init.d/tailscale stop 2>/dev/null
    mv "/tmp/tailscale_${LATEST}_arm64/tailscale" "${BIN_DIR}/tailscale"
    mv "/tmp/tailscale_${LATEST}_arm64/tailscaled" "${BIN_DIR}/tailscaled"
    chmod +x "${BIN_DIR}/tailscale" "${BIN_DIR}/tailscaled"
    rm -rf "/tmp/tailscale_${LATEST}_arm64" /tmp/tailscale.tgz
    sed -i "s/TAILSCALE_VERSION=.*/TAILSCALE_VERSION=${LATEST}/" /cfg/tailscale.env
    /etc/init.d/tailscale start 2>/dev/null
    logger -t ts-update "Updated to ${LATEST}"
fi
UPDATESCRIPT
chmod +x "$UPDATE_SCRIPT"

crontab -l 2>/dev/null | grep -v tailscale-update | crontab -
(crontab -l 2>/dev/null; echo '0 4 * * 1 /cfg/tailscale-update.sh') | crontab - 2>/dev/null
OK "Auto-update cron (weekly Monday 4AM)"

echo ""
echo "  ============================================"
echo "   Verifying Installation"
echo "  ============================================"
echo ""

if check_internet; then OK "Internet is working"; else WARN "Internet is DOWN"; fi

TS_STATUS=$("$BIN_DIR/tailscale" status 2>&1 || true)
if echo "$TS_STATUS" | grep -q "100\."; then
    TS_IP=$(echo "$TS_STATUS" | head -1 | awk '{print $1}')
    OK "Tailscale connected at $TS_IP"
else
    WARN "Tailscale not connected"
fi

if iptables -v -L INPUT -n 2>/dev/null | grep -q tailscale0; then OK "INPUT rule active"; else WARN "INPUT rule missing"; fi
FORWARD_COUNT=$(iptables -v -L FORWARD -n 2>/dev/null | grep -c tailscale0)
if [ "$FORWARD_COUNT" -ge 2 ]; then OK "FORWARD rules active"; else WARN "FORWARD rules missing"; fi
if iptables -t nat -L POSTROUTING -n 2>/dev/null | grep -q "100.64"; then OK "NAT MASQUERADE active"; else WARN "NAT MASQUERADE missing"; fi

echo ""
echo "  ============================================"
echo "   Setup Complete!"
echo "  ============================================"
echo ""
echo "  Mode: $MODE"
echo "  Subnet: $SUBNET"
echo ""

if [ "$MODE" = "subnet" ] || [ "$MODE" = "both" ]; then
    echo "  Next steps for subnet routing:"
    echo "  1. Go to https://login.tailscale.com/admin/machines"
    echo "  2. Find this router and approve the subnet route ($SUBNET)"
    echo "  3. On your phone/laptop, enable 'Use subnet routes' in Tailscale"
    echo ""
fi

if [ "$MODE" = "exit" ] || [ "$MODE" = "both" ]; then
    echo "  Next steps for exit node:"
    echo "  1. Go to https://login.tailscale.com/admin/machines"
    echo "  2. Find this router and approve the exit node"
    echo "  3. On your phone/laptop, select this router as exit node"
    echo ""
fi

echo "  Commands:"
echo "    sh setup.sh status     — Check Tailscale status"
echo "    sh setup.sh recover    — Fix broken internet after failed setup"
echo "    sh setup.sh uninstall  — Remove Tailscale completely"
echo ""
echo "  WARNING: Devices already on $SUBNET should NOT"
echo "  accept subnet routes or they'll lose direct LAN access."
echo ""
