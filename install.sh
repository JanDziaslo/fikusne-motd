#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
DEFAULT_MOTD="drugi-motd"
TARGET="/etc/update-motd.d/10-motd-custom"
CONFIG_SOURCE="$SCRIPT_DIR/motd.conf"
CONFIG_TARGET="/etc/update-motd.d/motd.conf"
DEPS=(toilet lsb-release)

usage() {
    cat <<'EOF'
Użycie: ./install.sh [--motd plik_motd] [--install-deps]

  --motd           wybór pliku motd (domyślnie drugi-motd)
  --install-deps   doinstaluj zależności: toilet, lsb-release
  -h, --help       pokaż pomoc
EOF
}

MOTD="$DEFAULT_MOTD"
INSTALL_DEPS=false

while [[ $# -gt 0 ]]; do
    case "$1" in
        --motd)
            MOTD="$2"
            shift 2
            ;;
        --install-deps)
            INSTALL_DEPS=true
            shift
            ;;
        -h|--help)
            usage
            exit 0
            ;;
        *)
            echo "Nieznana opcja: $1" >&2
            usage
            exit 1
            ;;
    esac
done

if [[ $EUID -ne 0 ]]; then
    echo "Uruchom skrypt jako root (np. sudo ./install.sh ...)" >&2
    exit 1
fi

SOURCE="$SCRIPT_DIR/$MOTD"
if [[ ! -f "$SOURCE" ]]; then
    echo "Nie znaleziono pliku MOTD: $SOURCE" >&2
    exit 1
fi

if $INSTALL_DEPS; then
    if command -v apt-get >/dev/null 2>&1; then
        apt-get update
        apt-get install -y "${DEPS[@]}"
    else
        echo "Brak apt-get. Zainstaluj ręcznie: ${DEPS[*]}" >&2
    fi
fi

if [[ -e "$TARGET" ]]; then
    ts="$(date +%Y%m%d%H%M%S)"
    cp "$TARGET" "${TARGET}.bak.$ts"
fi

cp "$SOURCE" "$TARGET"
chmod +x "$TARGET"

# Kopiuj plik konfiguracyjny (jeśli istnieje)
if [[ -f "$CONFIG_SOURCE" ]]; then
    if [[ -e "$CONFIG_TARGET" ]]; then
        echo "Plik konfiguracyjny już istnieje: $CONFIG_TARGET (nie nadpisuję)"
    else
        cp "$CONFIG_SOURCE" "$CONFIG_TARGET"
        chmod 644 "$CONFIG_TARGET"
        echo "Skopiowano plik konfiguracyjny do $CONFIG_TARGET"
    fi
else
    echo "UWAGA: Brak pliku konfiguracyjnego motd.conf w katalogu źródłowym"
fi

echo "Zainstalowano MOTD z pliku $MOTD do $TARGET"

