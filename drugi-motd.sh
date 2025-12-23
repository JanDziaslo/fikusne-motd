#!/bin/bash

# jak juz wiadomo kolorki sa super
RED='\033[1;31m'
GREEN='\033[1;32m'
YELLOW='\033[1;33m'
BLUE='\033[1;34m'
PURPLE='\033[1;35m'
CYAN='\033[1;36m'
NC='\033[0m'

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
echo -e "${BLUE}┏━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┓${NC}"
toilet -f small -F metal "                  $(hostname)"
echo ""
echo -e "${BLUE}┗━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━┛${NC}"

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

echo ""
echo -e " ${CYAN}System:${PURPLE}                     $(lsb_release -d | cut -f2)"
echo -e " ${CYAN}Czas działania:${NC}             $UPTIME"
echo -e " ${CYAN}IP Prywatne:${NC}                $IP_LOC"
if [ -n "$IP_PUB" ]; then
    echo -e " ${CYAN}IP Publiczne:${NC}               ${PURPLE}$IP_PUB${NC}"
else
    echo -e " ${CYAN}IP Publiczne:${NC}               ${YELLOW}Brak (curl/wget lub brak sieci)${NC}"
fi

echo ""
# (opcjonalnie) loadavg, jak chcesz zostawić:
# echo -e " ${CYAN}Load (1m):${NC}       $LOAD"

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

# Punkty montowania
dyski=( "/" "/dysk2" "/dysk3" )

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

# spawdzanie ile kontenerow dziala i ile jest wszytkich
if command -v docker >/dev/null 2>&1; then
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