#!/bin/bash

# Valores
IFACE="wlan0"
MANUAL_MAC=""
MANUAL_IP=""
GATEWAY=""
USE_DHCP=false

# Muestra ayuda
usage() {
  echo "Uso: $0 [-i interfaz] [-m nueva_mac] [--dhcp] [-a ip/máscara] [-g gateway]"
  echo ""
  echo "  -i INTERFAZ     Interfaz de red Wi-Fi (por defecto: wlan0)"
  echo "  -m NUEVA_MAC    Dirección MAC personalizada (ej: 12:34:56:78:9A:BC)"
  echo "  --dhcp          Forzar renovación de IP por DHCP"
  echo "  -a IP/MÁSCARA   Asignar IP manual (ej: 192.168.1.100/24)"
  echo "  -g GATEWAY      Establecer puerta de enlace (solo si usas -a)"
  echo ""
  echo "Ejemplos:"
  echo "  $0 -i wlan0 --dhcp                     # MAC aleatoria y renovar IP por DHCP"
  echo "  $0 -i wlan1 -m 12:34:56:78:9A:BC       # MAC fija, IP automática"
  echo "  $0 -i wlan0 -a 192.168.1.50/24 -g 192.168.1.1  # MAC aleatoria, IP fija"
  echo ""
  exit 1
}

# Parsear argumentos
while [[ "$#" -gt 0 ]]; do
  case "$1" in
    -i)
      IFACE="$2"
      shift 2
      ;;
    -m)
      MANUAL_MAC="$2"
      shift 2
      ;;
    -a)
      MANUAL_IP="$2"
      shift 2
      ;;
    -g)
      GATEWAY="$2"
      shift 2
      ;;
    --dhcp)
      USE_DHCP=true
      shift
      ;;
    -h|--help)
      usage
      ;;
    *)
      echo "[!] Opción desconocida: $1"
      usage
      ;;
  esac
done

echo "[+] Usando interfaz: $IFACE"

# Verifica si la interfaz existe
if ! ip link show "$IFACE" > /dev/null 2>&1; then
  echo "[!] Error: la interfaz '$IFACE' no existe."
  exit 1
fi

echo "[+] Apagando interfaz $IFACE..."
sudo ip link set "$IFACE" down

if [[ -n "$MANUAL_MAC" ]]; then
  echo "[+] Estableciendo MAC manual: $MANUAL_MAC"
  sudo macchanger -m "$MANUAL_MAC" "$IFACE"
else
  echo "[+] Generando MAC aleatoria..."
  sudo macchanger -r "$IFACE"
fi

echo "[+] Encendiendo interfaz $IFACE..."
sudo ip link set "$IFACE" up

echo "[+] Configurando IP..."

if [[ "$USE_DHCP" = true ]]; then
  echo "[+] Renovando IP vía DHCP... "
  sudo dhclient -r "$IFACE" 2>/dev/null || true
  sudo dhclient "$IFACE"

elif [[ -n "$MANUAL_IP" ]]; then
  echo "[+] Asignando IP manual: $MANUAL_IP"
  sudo ip addr flush dev "$IFACE"
  sudo ip addr add "$MANUAL_IP" dev "$IFACE"

  if [[ -n "$GATEWAY" ]]; then
    echo "[+] Estableciendo gateway: $GATEWAY"
    sudo ip route add default via "$GATEWAY"
  fi

else
  echo "[+] Esperando a que se asigne una IP automáticamente :3"
  MAX_WAIT=15
  WAITED=0

  while true; do
    IP=$(ip -4 addr show "$IFACE" | grep -oP '(?<=inet\s)\d+(\.\d+){3}')
    if [[ -n "$IP" ]]; then
      echo "[+] IP asignada : $IP"
      break
    fi

    if [[ "$WAITED" -ge "$MAX_WAIT" ]]; then
      echo "[!] Tiempo de espera agotado: no se asignó IP tras $MAX_WAIT segundos :( ."
      break
    fi

    sleep 1
    WAITED=$((WAITED + 1))
  done
fi

echo ""
echo "[+] Nueva configuración de $IFACE:"
ip a show "$IFACE" | grep -E "link/ether|inet "

echo ""
echo "[✓] Proceso completo."

