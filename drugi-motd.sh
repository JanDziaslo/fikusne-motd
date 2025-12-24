#!/bin/bash

# jak juz wiadomo kolorki sa super
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

# Wczytanie konfiguracji
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONFIG_FILE="$SCRIPT_DIR/motd.conf"

# Wartości domyślne (jeśli brak pliku konfiguracyjnego)
SHOW_HEADER=1
SHOW_SYSTEM_INFO=1
SHOW_IP_INFO=1
SHOW_LAST_SSH=1
SHOW_UPDATES=1
SHOW_MEMORY=1
SHOW_DISKS=1
SHOW_DOCKER=1

# Wczytaj konfigurację, jeśli istnieje
if [ -f "$CONFIG_FILE" ]; then
    source "$CONFIG_FILE"
fi

# --- Aktualizacje (best-effort, szybkie: timeout + cache, bez wymuszania sieci) ---
have() { command -v "$1" >/dev/null 2>&1; }

run_timed() {
    local seconds="$1"; shift
    if have timeout; then
        timeout "${seconds}" "$@"
    else
        "$@"
    fi
}

motd_updates_cache_file() {
    # /run jest preferowane (tmpfs), ale bywa niedostępne w chrootach/kontenerach
    if [ -w /run ]; then
        echo "/run/motd-updates.cache"
    else
        echo "/tmp/motd-updates.cache"
    fi
}

motd_updates_cache_get() {
    local ttl_seconds="$1"
    local f
    f="$(motd_updates_cache_file)"

    [ -r "$f" ] || return 1

    local now ts
    now=$(date +%s 2>/dev/null || echo 0)
    ts=$(awk -F'|' 'NR==1{print $1}' "$f" 2>/dev/null || true)

    if [[ -n "$now" && -n "$ts" && "$now" =~ ^[0-9]+$ && "$ts" =~ ^[0-9]+$ ]]; then
        if (( now - ts <= ttl_seconds )); then
            # zwróć resztę linii po pierwszym polu (status|count|backend|note)
            awk -F'|' 'NR==1{ $1=""; sub(/^\|/,""); print }' "$f" 2>/dev/null
            return 0
        fi
    fi

    return 1
}

motd_updates_cache_put() {
    local status="$1" count="$2" backend="$3" note="$4"
    local f
    f="$(motd_updates_cache_file)"

    local now
    now=$(date +%s 2>/dev/null || echo 0)

    # Format: ts|status|count|backend|note
    printf "%s|%s|%s|%s|%s\n" "$now" "$status" "$count" "$backend" "$note" >"$f" 2>/dev/null || true
}

count_updates_apt() {
    # Nie robimy `apt update` (żadnej sieci). Liczba bazuje na lokalnym cache.
    # `apt list --upgradable` wypisuje 1 linię nagłówka na stderr/stdout zależnie od wersji.
    # Wymuszamy C locale dla spójności.
    local out rc
    out=$(LC_ALL=C run_timed 2 apt list --upgradable 2>/dev/null)
    rc=$?

    # Jeśli komenda się udała, a brak danych, traktuj jako 0 aktualizacji.
    if [ "$rc" -eq 0 ] && [ -z "$out" ]; then
        echo "0"
        return 0
    fi

    if [ "$rc" -ne 0 ]; then
        # Typowy przypadek: brak lokalnych list APT (np. świeży system/kontener)
        # – wtedy nie strasz "Brak danych", tylko pokaż 0.
        if [ ! -d /var/lib/apt/lists ] || ! ls /var/lib/apt/lists/*_Packages >/dev/null 2>&1; then
            echo "0"
            return 0
        fi

        echo "unknown"
        return 0
    fi

    # Odfiltruj nagłówki "Listing..." niezależnie od wariantu
    local n
    n=$(printf "%s\n" "$out" | grep -vE '^Listing' | grep -cE '.*/.+' || true)

    if [[ "$n" =~ ^[0-9]+$ ]]; then
        echo "$n"
    else
        echo "unknown"
    fi
}

count_updates_dnf() {
    # Bez --refresh, żeby dnf nie próbował iść do sieci.
    # dnf zwraca kod 100 gdy są aktualizacje.
    local out rc
    out=$(LC_ALL=C run_timed 3 dnf -q check-update 2>/dev/null)
    rc=$?

    # 0 = brak, 100 = są, inne = błąd
    if [ "$rc" -ne 0 ] && [ "$rc" -ne 100 ]; then
        # Jeśli dnf nie ma metadanych/cache (częste w kontenerach/offline), pokaż 0 zamiast "Brak danych".
        if [ ! -d /var/cache/dnf ] || ! find /var/cache/dnf -maxdepth 3 -type f -name repomd.xml -print -quit 2>/dev/null | grep -q .; then
            echo "0"
            return 0
        fi

        echo "unknown"
        return 0
    fi

    # Zlicz linie pakietów: zaczynają się od nazwy pakietu (nie spacje), 3 kolumny.
    # Pomijamy metadane i puste linie.
    local n
    n=$(printf "%s\n" "$out" | awk 'NF>=3 && $1 !~ /^Last/ && $1 !~ /^Obsoleting/ {print}' | wc -l | tr -d ' ')

    if [[ "$n" =~ ^[0-9]+$ ]]; then
        echo "$n"
    else
        echo "unknown"
    fi
}

count_updates_arch() {
    local out rc
    if have checkupdates; then
        out=$(run_timed 3 checkupdates 2>/dev/null)
        rc=$?
    else
        out=$(run_timed 3 pacman -Qu 2>/dev/null)
        rc=$?
    fi

    if [ -z "$out" ]; then
        # Puste wyjście przy rc=0 to najczęściej „0 aktualizacji”.
        # Gdy rc!=0, to raczej lock/błąd bazy – wtedy sygnalizuj unknown.
        if [ "$rc" -eq 0 ]; then
            echo "0"
        else
            echo "unknown"
        fi
        return 0
    fi

    local n
    n=$(printf "%s\n" "$out" | wc -l | tr -d ' ')
    if [[ "$n" =~ ^[0-9]+$ ]]; then
        echo "$n"
    else
        echo "unknown"
    fi
}

get_updates_info() {
    # output: status|count|backend|note
    # status: ok|unknown
    # count: liczba lub -
    local cached
    cached=$(motd_updates_cache_get 600 2>/dev/null || true)
    if [ -n "$cached" ]; then
        echo "$cached"
        return 0
    fi

    local backend="" count="unknown" note=""

    if have apt; then
        backend="apt"
        count=$(count_updates_apt)
    elif have dnf; then
        backend="dnf"
        count=$(count_updates_dnf)
    elif have pacman; then
        backend="pacman"
        count=$(count_updates_arch)
    else
        backend="-"
        count="unknown"
        note="Brak obsługi (apt/dnf/pacman)"
    fi

    if [[ "$count" =~ ^[0-9]+$ ]]; then
        motd_updates_cache_put "ok" "$count" "$backend" "$note"
        echo "ok|$count|$backend|$note"
    else
        # Nie cache'uj "unknown", żeby nie przyklejać "Brak danych" na 10 minut.
        echo "unknown|-|$backend|Brak danych (timeout/cache)"
    fi
}

# --- Ostatnie logowanie SSH (IP + opcjonalnie nazwa z Tailscale) ---
is_tailscale_ip() {
    # 100.64.0.0/10 => 100.(64-127).x.x
    local ip="$1"
    [[ "$ip" =~ ^100\.(6[4-9]|[7-9][0-9]|1[01][0-9]|12[0-7])\.[0-9]{1,3}\.[0-9]{1,3}$ ]]
}

tailscale_name_for_ip() {
    local ip="$1"
    command -v tailscale >/dev/null 2>&1 || return 1
    # `tailscale status` zwykle: "100.x.y.z  nazwa  user  os  ..."
    tailscale status 2>/dev/null | awk -v ip="$ip" '$1==ip {print $2; exit}'
}

get_last_ssh_ip() {
    local ip=""

    # 1) journald (najlepsze źródło, jeśli działa)
    if command -v journalctl >/dev/null 2>&1; then
        # Weź przedostatnie połączenie (pomiń ostatnie, które jest obecnym)
        # tail -n 2 | head -n 1 = drugie od końca
        ip=$(journalctl -q --no-pager -u ssh -u sshd 2>/dev/null \
            | grep -E 'Accepted (password|publickey|keyboard-interactive/pam) for ' \
            | sed -nE 's/.* from ([^ ]+).*/\1/p' \
            | tail -n 2 | head -n 1)
    fi

    # 2) /var/log/auth.log (Debian/Ubuntu) – fallback
    if [ -z "$ip" ] && [ -r /var/log/auth.log ]; then
        # Weź przedostatnie połączenie
        ip=$(grep -E 'Accepted (password|publickey|keyboard-interactive/pam) for ' /var/log/auth.log \
            | sed -nE 's/.* from ([^ ]+).*/\1/p' \
            | tail -n 2 | head -n 1)
    fi

    # filtrowanie: na razie tylko IPv4 (żeby nie śmiecić dziwnymi formatami)
    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    fi
}

get_public_ip() {
    # ipinfo.io/ip zwraca samo IP w treści
    local ip=""

    if command -v curl >/dev/null 2>&1; then
        ip=$(curl -fsS --max-time 2 https://ipinfo.io/ip 2>/dev/null | tr -d '\r\n') || true
    elif command -v wget >/dev/null 2>&1; then
        ip=$(wget -qO- --timeout=2 https://ipinfo.io/ip 2>/dev/null | tr -d '\r\n') || true
    fi

    if [[ "$ip" =~ ^[0-9]+\.[0-9]+\.[0-9]+\.[0-9]+$ ]]; then
        echo "$ip"
    fi
}

# pasek
draw_bar() {
    local perc=$1
    local size=20
    local filled=$(( perc * size / 100 ))
    local empty=$(( size - filled ))
    printf "["
    printf "${GREEN}%0.s#${NC}" $(seq 1 $filled)
    printf "%0.s-" $(seq 1 $empty)
    printf "] %d%%" "$perc"
}

clear
if [ "$SHOW_HEADER" = "1" ]; then
    echo -e "${BLUE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
    toilet -f small -F metal "                  $(hostname)"
    echo ""
    echo -e "${BLUE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"
fi

# podstawowe informacje o systemie
format_uptime_pl() {
    # `uptime -p` zwykle zwraca np. "up 2 days, 3 hours, 1 minute"
    # Zamieniamy to na PL: "2 dni, 3 godzin, 1 minut" (+ sensowne singular).
    local s="$1"
    s=${s#up }

    # liczba + jednostka (przykrywa hours/hours, minutes/minute, days/day)
    s=$(echo "$s" \
        | sed -E \
            -e 's/\b([0-9]+)\s+days?\b/\1 dni/g' \
            -e 's/\b1\s+dni\b/1 dzień/g' \
            -e 's/\b([0-9]+)\s+hours?\b/\1 godzin/g' \
            -e 's/\b1\s+godzin\b/1 godzina/g' \
            -e 's/\b([0-9]+)\s+minutes?\b/\1 minut/g' \
            -e 's/\b1\s+minut\b/1 minuta/g'
    )

    echo "$s"
}

UPTIME_RAW=$(uptime -p 2>/dev/null || true)
UPTIME=${PURPLE}$(format_uptime_pl "$UPTIME_RAW")
LOAD=${PURPLE}$(cat /proc/loadavg | awk '{print $1}')
IP_LOC=${PURPLE}$(hostname -I | awk '{print $1}')
IP_PUB=$(get_public_ip)

if [ "$SHOW_SYSTEM_INFO" = "1" ] || [ "$SHOW_IP_INFO" = "1" ] || [ "$SHOW_LAST_SSH" = "1" ] || [ "$SHOW_UPDATES" = "1" ]; then
    echo ""
fi

if [ "$SHOW_SYSTEM_INFO" = "1" ]; then
    echo -e " ${CYAN}System:${PURPLE}                     $(lsb_release -d | cut -f2)"
    echo -e " ${CYAN}Czas działania:${NC}             $UPTIME"
fi

if [ "$SHOW_IP_INFO" = "1" ]; then
    echo -e " ${CYAN}IP Prywatne:${NC}                $IP_LOC"
    if [ -n "$IP_PUB" ]; then
        echo -e " ${CYAN}IP Publiczne:${NC}               ${PURPLE}$IP_PUB${NC}"
    else
        echo -e " ${CYAN}IP Publiczne:${NC}               ${YELLOW}Brak (curl/wget lub brak sieci)${NC}"
    fi
fi

if [ "$SHOW_SYSTEM_INFO" = "1" ] || [ "$SHOW_IP_INFO" = "1" ] || [ "$SHOW_LAST_SSH" = "1" ] || [ "$SHOW_UPDATES" = "1" ]; then
    echo ""
fi
# (opcjonalnie) loadavg, jak chcesz zostawić:
# echo -e " ${CYAN}Load (1m):${NC}       $LOAD"

if [ "$SHOW_LAST_SSH" = "1" ]; then
    LAST_IP=$(get_last_ssh_ip)
    if [ -n "$LAST_IP" ]; then
        LAST_LOGIN_INFO="$LAST_IP"

        if is_tailscale_ip "$LAST_IP"; then
            TS_NAME=$(tailscale_name_for_ip "$LAST_IP")
            if [ -n "$TS_NAME" ]; then
                LAST_LOGIN_INFO="$LAST_IP ($TS_NAME)"
            fi
        fi

        echo -e " ${CYAN}Ostatnie połączenie SSH:${NC}    ${PURPLE}$LAST_LOGIN_INFO${NC}"
    fi
fi

# Aktualizacje
if [ "$SHOW_UPDATES" = "1" ]; then
    UPD_INFO=$(get_updates_info)
    UPD_STATUS=$(echo "$UPD_INFO" | awk -F'|' '{print $1}')
    UPD_COUNT=$(echo "$UPD_INFO" | awk -F'|' '{print $2}')
    UPD_BACKEND=$(echo "$UPD_INFO" | awk -F'|' '{print $3}')
    UPD_NOTE=$(echo "$UPD_INFO" | awk -F'|' '{print $4}')

    if [ "$UPD_STATUS" = "ok" ] && [[ "$UPD_COUNT" =~ ^[0-9]+$ ]]; then
        if [ "$UPD_COUNT" -eq 0 ]; then
            echo -e " ${CYAN}Aktualizacje:${NC}               ${GREEN}0${NC} (brak)${PURPLE} [$UPD_BACKEND]${NC}"
        else
            echo -e " ${CYAN}Aktualizacje:${NC}               ${YELLOW}$UPD_COUNT${NC} dostępnych ${PURPLE}[$UPD_BACKEND]${NC}"
        fi
    else
        if [ -n "$UPD_NOTE" ]; then
            echo -e " ${CYAN}Aktualizacje:${NC}               ${YELLOW}Brak danych${NC} ${PURPLE}[$UPD_BACKEND]${NC} - $UPD_NOTE"
        else
            echo -e " ${CYAN}Aktualizacje:${NC}               ${YELLOW}Brak danych${NC} ${PURPLE}[$UPD_BACKEND]${NC}"
        fi
    fi
fi

if [ "$SHOW_MEMORY" = "1" ]; then
    echo -e "\n${BLUE}── RAM ────────────────────────────────────────────────────────${NC}"

    # RAM (defensywnie: niektóre systemy/kontenery mogą zwrócić 0/puste)
    MEM_USED=$(free -b 2>/dev/null | awk '/^Mem:/ {print $3; exit}')
    MEM_TOTAL=$(free -b 2>/dev/null | awk '/^Mem:/ {print $2; exit}')

    if [[ -n "$MEM_TOTAL" && "$MEM_TOTAL" =~ ^[0-9]+$ && "$MEM_TOTAL" -gt 0 && -n "$MEM_USED" && "$MEM_USED" =~ ^[0-9]+$ ]]; then
        MEM_PERC=$(( MEM_USED * 100 / MEM_TOTAL ))
        MEM_HUMAN=$(free -h 2>/dev/null | awk '/^Mem:/ {print $3 "/" $2; exit}')
        echo ""
        printf " ${GREEN}RAM:${NC}  %-15s "
        draw_bar "$MEM_PERC"
        echo -e " (${MEM_HUMAN})"
    else
        echo -e "\n ${GREEN}RAM:${NC}  ${YELLOW}Brak danych o pamięci${NC}"
    fi

    # SWAP (bez błędów gdy brak swap albo free zwraca pusto)
    SWAP_USED=$(free -b 2>/dev/null | awk '/^Swap:/ {print $3; exit}')
    SWAP_TOTAL=$(free -b 2>/dev/null | awk '/^Swap:/ {print $2; exit}')

    if [[ -n "$SWAP_TOTAL" && "$SWAP_TOTAL" =~ ^[0-9]+$ && "$SWAP_TOTAL" -gt 0 && -n "$SWAP_USED" && "$SWAP_USED" =~ ^[0-9]+$ ]]; then
        SWAP_PERC=$(( SWAP_USED * 100 / SWAP_TOTAL ))
        SWAP_HUMAN=$(free -h 2>/dev/null | awk '/^Swap:/ {print $3 "/" $2; exit}')
        printf " ${GREEN}SWAP:${NC} %-15s "
        draw_bar "$SWAP_PERC"
        echo -e " (${SWAP_HUMAN})"
    elif [[ -n "$SWAP_TOTAL" && "$SWAP_TOTAL" =~ ^[0-9]+$ && "$SWAP_TOTAL" -eq 0 ]]; then
        echo -e " ${GREEN}SWAP:${NC} ${YELLOW}Brak SWAP${NC}"
    else
        echo -e " ${GREEN}SWAP:${NC} ${YELLOW}Brak danych o SWAP${NC}"
    fi
fi

# Punkty montowania
dyski=( "/" "/dysk2" "/dysk3" )

if [ "$SHOW_DISKS" = "1" ]; then
    echo -e "\n${BLUE}── Dyski ──────────────────────────────────────────────────────${NC}"

    echo ""

    for MOUNT in "${dyski[@]}"; do
        if [ -d "$MOUNT" ]; then
            INFO=$(df -h "$MOUNT" | tail -n 1)
            PERC=$(echo "$INFO" | awk '{print $(NF-1)}' | sed 's/%//')
            FREE=$(echo "$INFO" | awk '{print $(NF-2)}')

            # Skracanie ścieżki
            DISPLAY_NAME=$(echo "$MOUNT" | sed "s|$HOME|~|")

            printf " ${GREEN}Dysk:${NC} %-15s " "$DISPLAY_NAME"
            draw_bar "$PERC"
            echo -e " ($FREE wolne)"
        fi
    done
fi

# spawdzanie ile kontenerow dziala i ile jest wszytkich
if [ "$SHOW_DOCKER" = "1" ] && command -v docker >/dev/null 2>&1; then
    echo -e "\n${BLUE}── Kontenery Docker ───────────────────────────────────────────${NC}"
    echo ""
    D_RUNNING=$(docker ps --format "{{.ID}}" 2>/dev/null | wc -l)
    D_TOTAL=$(docker ps -a --format "{{.ID}}" 2>/dev/null | wc -l)
    D_STOPPED_COUNT=$(docker ps -a --filter "status=exited" --filter "status=created" --format "{{.ID}}" 2>/dev/null | wc -l)

    echo -e " ${PURPLE}Docker:${NC}               $D_RUNNING aktywnych / $D_TOTAL wszystkich"

    # Wyświetl wyłączone kontenery (tylko te zatrzymane, nie usunięte)
    if [ "$D_STOPPED_COUNT" -gt 0 ]; then
        D_STOPPED=$(docker ps -a --filter "status=exited" --filter "status=created" --format "{{.Names}}" 2>/dev/null)
        echo -e " ${YELLOW}Wyłączone kontenery ($D_STOPPED_COUNT):${NC}"
        echo "$D_STOPPED" | while read -r container; do
            echo -e "   ${RED}●${NC} $container"
        done
    fi
fi

echo -e "\n${BLUE}───────────────────────────────────────────────────────────────${NC}"