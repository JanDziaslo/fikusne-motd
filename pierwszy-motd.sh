#!/bin/bash
# Kolorki bo po co pisac kilka razy to samo?
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
BLUE='\033[0;34m'
NC='\033[0m'

echo -e "${BLUE}=================================================${NC}"
echo -e " "
toilet -f big -F metal "       $(hostname)"
echo -e " "
echo -e " "
echo -e "${BLUE}=================================================${NC}"
echo " "
if [ "$SHOW_SYSTEM_INFO" = "1" ]; then
    echo -e " ${RED}System:    ${NC} $(lsb_release -d | cut -f2)"
    echo -e " ${RED}Kernel:    ${NC} $(uname -r)"
    echo -e " ${RED}Czas pracy:${NC} $(uptime -p)"
    echo " "
    echo -e "${BLUE}=================================================${NC}"
    echo " "
fi
if [ "$SHOW_MEMORY" = "1" ]; then
    echo -e " ${GREEN}RAM:${NC}        $(free -h | awk '/^Mem/ {print $3 "/" $2}')"
fi
if [ "$SHOW_DISKS" = "1" ]; then
    echo -e " ${GREEN}Dysk:${NC}       $(df -h / | awk '/\// {print $4 " free (" $5 " used)"}')"
    echo -e " ${GREEN}Obciążenie:${NC} $(cat /proc/loadavg | awk '{print $1 ", " $2 ", " $3}')"
fi
if [ "$SHOW_MEMORY" = "1" ] || [ "$SHOW_DISKS" = "1" ]; then
    echo " "
    echo -e "${BLUE}=================================================${NC}"
fi

