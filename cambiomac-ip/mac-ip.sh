#!/usr/bin/env bash
set -euo pipefail

########################
# Variables por defecto
########################
IFACE="wlan0"
MANUAL_MAC=""
MANUAL_IP=""
GATEWAY=""
MODE=""
DHCP_TIMEOUT=15

########################
# Funciones
########################
check_deps() {
  local missing=()

  for cmd in ip macchanger timeout awk; do
    command -v "$cmd" >/dev/null 2>&1 || missing+=("$cmd")
  done

  if [[ "$MODE" == "RANDOM_IP" || "$MODE" == "RANDOM_ALL" ]] && ! command -v dhclient >/dev/null 2>&1; then
    missing+=("dhclient")
  fi

  if [[ ${#missing[@]} -ne 0 ]]; then
    echo "[!] Faltan dependencias necesarias:"
    for m in "${missing[@]}"; do
      echo "    - $m"
    done
    echo
    echo "Instálalas manualmente:"
    echo "    sudo apt install iproute2 macchanger isc-dhcp-client coreutils gawk"
    echo
    echo "    Arch Linux:"
    echo "    sudo pacman -S iproute2 macchanger dhclient coreutils gawk"
    exit 1
  fi
}

die() { echo "[!] $1" >&2; exit 1; }
info() { echo "[+] $1"; }

detect_gateway() {
  ip route show default 2>/dev/null | \
    awk -v iface="$IFACE" '$1=="default" && $0~iface {print $3; exit}'
}

show_status() {
  local mac ip gw method

  mac=$(ip link show "$IFACE" | awk '/link\/ether/ {print $2}')
  ip=$(ip -4 addr show "$IFACE" | awk '/inet / {print $2}')
  gw=$(ip route show default | awk -v iface="$IFACE" '$0 ~ iface {print $3}')
  
  if ip -4 addr show "$IFACE" | grep -q dynamic; then
    method="DHCP"
  elif [[ -n "$ip" ]]; then
    method="Estática"
  else
    method="Sin IP"
  fi

  echo "=============================="
  echo " Estado de la interfaz: $IFACE"
  echo "=============================="
  printf " Interfaz : %s\n" "$IFACE"
  printf " MAC       : %s\n" "${mac:-N/A}"
  printf " IP        : %s\n" "${ip:-No asignada}"
  printf " Gateway   : %s\n" "${gw:-No definido}"
  printf " Método IP : %s\n" "$method"
  echo "=============================="
  exit 0
}


usage() {
cat <<EOF

Uso: sudo $0 [modo] [opciones]

MODOS DISPONIBLES:
  -s,  --status
  -rm, --random-mac
  -ri, --random-ip
  -ra, --random-all
  -fa, --fixed-all

OPCIONES:
  -i IFACE
  -m MAC
  -a IP/MASK
  -g GATEWAY
  -h, --help
  
EJEMPLOS: 
    sudo $0 -s 
    sudo $0 -rm
    sudo $0 -ri 
    sudo $0 -ra 
    sudo $0 -fa -m 12:34:56:78:9A:BC -a 192.168.1.105/24
EOF
exit 0
}

########################
# Ayuda si no hay args
########################
[[ $# -eq 0 ]] && usage

########################
# Root
########################
[[ $EUID -eq 0 ]] || die "Ejecuta como root."

########################
# Parseo
########################
while [[ $# -gt 0 ]]; do
  case "$1" in
    -i) IFACE="$2"; shift 2 ;;
    -m) MANUAL_MAC="$2"; shift 2 ;;
    -a) MANUAL_IP="$2"; shift 2 ;;
    -g) GATEWAY="$2"; shift 2 ;;
    -s|--status) MODE="STATUS"; shift ;;
    -rm|--random-mac) MODE="RANDOM_MAC"; shift ;;
    -ri|--random-ip) MODE="RANDOM_IP"; shift ;;
    -ra|--random-all) MODE="RANDOM_ALL"; shift ;;
    -fa|--fixed-all) MODE="FIXED_ALL"; shift ;;
    -h|--help) usage ;;
    *) die "Opción desconocida: $1" ;;
  esac
done

check_deps
[[ -z "$MODE" ]] && die "Debes especificar un modo"

########################
# Validar interfaz
########################
ip link show "$IFACE" >/dev/null 2>&1 || die "Interfaz inválida: $IFACE"
[[ "$IFACE" == "lo" ]] && die "No se permite loopback"

if ! [[ "$IFACE" =~ ^(wl|en|eth) ]]; then
  die "Interfaz no permitida: $IFACE"
fi

[[ "$MODE" == "STATUS" ]] && show_status

########################
# Validaciones
########################
if [[ -n "$MANUAL_MAC" && ! "$MANUAL_MAC" =~ ^([0-9A-Fa-f]{2}:){5}[0-9A-Fa-f]{2}$ ]]; then
  die "MAC inválida"
fi

if [[ -n "$MANUAL_IP" && ! "$MANUAL_IP" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}/[0-9]{1,2}$ ]]; then
  die "IP inválida"
fi

########################
# Gateway automático
########################
if [[ -z "$GATEWAY" && "$MODE" == "FIXED_ALL" ]]; then
  GATEWAY=$(detect_gateway || true)
  [[ -n "$GATEWAY" ]] || die "No se pudo detectar gateway"
  info "Gateway detectado automáticamente: $GATEWAY"

  [[ "$GATEWAY" =~ ^([0-9]{1,3}\.){3}[0-9]{1,3}$ ]] || die "Gateway inválido"
fi

########################
# Apagar interfaz
########################
info "Apagando $IFACE"
ip link set "$IFACE" down

########################
# MAC
########################
case "$MODE" in
  RANDOM_MAC|RANDOM_ALL|FIXED_ALL)
    if [[ -n "$MANUAL_MAC" ]]; then
      macchanger -m "$MANUAL_MAC" "$IFACE"
    else
      macchanger -r "$IFACE"
    fi
    ;;
esac

########################
# Subir interfaz
########################
ip link set "$IFACE" up

########################
# IP
########################
case "$MODE" in
  RANDOM_IP|RANDOM_ALL)
    info "Renovando IP por DHCP"
    ip addr flush dev "$IFACE"        
    dhclient -r "$IFACE" 2>/dev/null || true
    timeout "$DHCP_TIMEOUT" dhclient "$IFACE" || die "DHCP falló"
    ;;
  FIXED_ALL)
    ip addr flush dev "$IFACE"
    ip addr add "$MANUAL_IP" dev "$IFACE"
    ip route replace default via "$GATEWAY"
    ;;
esac

########################
# Resultado
########################
echo
ip a show "$IFACE" | grep -E "link/ether|inet "
ip route show default | grep "$IFACE" || true
echo
info "Proceso completado ✔"
