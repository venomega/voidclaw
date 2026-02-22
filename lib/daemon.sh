#!/bin/bash
# lib/daemon.sh - Sistema de daemon con soporte multi-init

# Usar VOIDCLAW_BASE_DIR si está definido
if [[ -n "$VOIDCLAW_BASE_DIR" ]]; then
    SCRIPT_DIR="${VOIDCLAW_BASE_DIR}/lib"
    CONFIG_FILE="${VOIDCLAW_BASE_DIR}/config/settings.json"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="${SCRIPT_DIR}/../config/settings.json"
fi

# Directorios de servicio
SYSTEMD_USER_DIR="${HOME}/.config/systemd/user"
TERMUX_RUNIT_DIR="${HOME}/.runit/services"
VOIDCLAW_SCRIPT="${VOIDCLAW_BASE_DIR:-$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)}/voidclaw.sh"

# Colores
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
BLUE='\033[0;34m'
NC='\033[0m'

# Detecta el sistema de init disponible
daemon_detect_init() {
    # systemd (user)
    if command -v systemctl &>/dev/null && [[ -d "/run/systemd/system" || -n "$XDG_RUNTIME_DIR" ]]; then
        echo "systemd"
        return 0
    fi

    # runit (Termux)
    if command -v sv &>/dev/null && command -v runsvdir &>/dev/null; then
        echo "runit"
        return 0
    fi

    # init.d (fallback genérico)
    if [[ -d "/etc/init.d" ]]; then
        echo "initd"
        return 0
    fi

    # Sin sistema de init detectado
    echo "none"
    return 1
}

# Verifica si systemd está disponible y configurado para user services
daemon_has_systemd() {
    if ! command -v systemctl &>/dev/null; then
        return 1
    fi

    # Verificar si systemd --user está disponible
    if systemctl --user daemon-reexec &>/dev/null 2>&1; then
        return 0
    fi

    # En algunos sistemas, verificar XDG_RUNTIME_DIR
    if [[ -n "$XDG_RUNTIME_DIR" && -d "$XDG_RUNTIME_DIR/systemd" ]]; then
        return 0
    fi

    return 1
}

# Verifica si runit está disponible (Termux)
daemon_has_runit() {
    if ! command -v sv &>/dev/null; then
        return 1
    fi

    if ! command -v runsvdir &>/dev/null; then
        return 1
    fi

    return 0
}

# Crea directorio de servicios systemd user
daemon_systemd_create_dir() {
    if [[ ! -d "$SYSTEMD_USER_DIR" ]]; then
        mkdir -p "$SYSTEMD_USER_DIR"
        log_debug "Creado directorio systemd user: $SYSTEMD_USER_DIR"
    fi
}

# Genera archivo de servicio systemd
daemon_systemd_generate_service() {
    local service_file="${SYSTEMD_USER_DIR}/voidclaw.service"

    cat > "$service_file" << EOF
[Unit]
Description=VoidClaw Loop Daemon
After=network.target

[Service]
Type=simple
ExecStart=${VOIDCLAW_SCRIPT} --loop-daemon
Restart=on-failure
RestartSec=10
Environment="VOIDCLAW_BASE_DIR=$(dirname "$(dirname "$VOIDCLAW_SCRIPT")")"
Environment="PATH=/usr/local/bin:/usr/bin:/bin"
WorkingDirectory=$(dirname "$(dirname "$VOIDCLAW_SCRIPT")")

# Logging
StandardOutput=append:${VOIDCLAW_BASE_DIR:-$HOME/.voidclaw}/logs/daemon.log
StandardError=append:${VOIDCLAW_BASE_DIR:-$HOME/.voidclaw}/logs/daemon-error.log

# Security
NoNewPrivileges=true
ProtectSystem=strict
ProtectHome=read-only
ReadWritePaths=${VOIDCLAW_BASE_DIR:-$HOME/.voidclaw}

[Install]
WantedBy=default.target
EOF

    echo "$service_file"
}

# Habilita servicio systemd
daemon_systemd_enable() {
    echo -e "${BLUE}Configurando servicio systemd user...${NC}"

    daemon_systemd_create_dir

    local service_file
    service_file=$(daemon_systemd_generate_service)

    # Recargar daemon de systemd user
    systemctl --user daemon-reload

    # Habilitar servicio
    if systemctl --user enable voidclaw.service &>/dev/null; then
        echo -e "${GREEN}✓ Servicio habilitado${NC}"
        return 0
    else
        echo -e "${RED}✗ Error al habilitar servicio${NC}"
        return 1
    fi
}

# Inicia servicio systemd
daemon_systemd_start() {
    echo -e "${BLUE}Iniciando servicio systemd...${NC}"

    systemctl --user daemon-reload

    if systemctl --user start voidclaw.service &>/dev/null; then
        echo -e "${GREEN}✓ Servicio iniciado${NC}"
        return 0
    else
        echo -e "${RED}✗ Error al iniciar servicio${NC}"
        systemctl --user status voidclaw.service 2>&1 | head -10
        return 1
    fi
}

# Detiene servicio systemd
daemon_systemd_stop() {
    echo -e "${YELLOW}Deteniendo servicio systemd...${NC}"

    if systemctl --user stop voidclaw.service &>/dev/null; then
        echo -e "${GREEN}✓ Servicio detenido${NC}"
        return 0
    else
        echo -e "${RED}✗ Error al detener servicio${NC}"
        return 1
    fi
}

# Verifica estado de servicio systemd
daemon_systemd_status() {
    if systemctl --user is-active --quiet voidclaw.service 2>/dev/null; then
        echo -e "${GREEN}● voidclaw.service - Activo (running)${NC}"
        systemctl --user status voidclaw.service 2>&1 | head -15
        return 0
    else
        echo -e "${RED}○ voidclaw.service - Inactivo${NC}"
        return 1
    fi
}

# Deshabilita servicio systemd
daemon_systemd_disable() {
    echo -e "${YELLOW}Deshabilitando servicio systemd...${NC}"

    systemctl --user stop voidclaw.service &>/dev/null || true
    systemctl --user disable voidclaw.service &>/dev/null || true

    # Remover archivo de servicio
    local service_file="${SYSTEMD_USER_DIR}/voidclaw.service"
    if [[ -f "$service_file" ]]; then
        rm -f "$service_file"
        systemctl --user daemon-reload
        echo -e "${GREEN}✓ Servicio removido${NC}"
    fi

    return 0
}

# Crea directorio de servicios runit
daemon_runit_create_dir() {
    if [[ ! -d "$TERMUX_RUNIT_DIR" ]]; then
        mkdir -p "$TERMUX_RUNIT_DIR"
        log_debug "Creado directorio runit: $TERMUX_RUNIT_DIR"
    fi
}

# Genera script de servicio runit
daemon_runit_generate_service() {
    local service_dir="${TERMUX_RUNIT_DIR}/voidclaw"
    local run_script="${service_dir}/run"

    if [[ ! -d "$service_dir" ]]; then
        mkdir -p "$service_dir"
    fi

    cat > "$run_script" << EOF
#!/data/data/com.termux/files/usr/bin/bash
# VoidClaw Loop Daemon - runit service

export VOIDCLAW_BASE_DIR=$(dirname "$(dirname "$VOIDCLAW_SCRIPT")")
export PATH="/data/data/com.termux/files/usr/bin:/data/data/com.termux/files/usr/bin/applets:\$PATH"

cd "\$VOIDCLAW_BASE_DIR" || exit 1

# Ejecutar loop en modo daemon
exec ${VOIDCLAW_SCRIPT} --loop-daemon 2>&1
EOF

    chmod +x "$run_script"

    echo "$service_dir"
}

# Habilita servicio runit
daemon_runit_enable() {
    echo -e "${BLUE}Configurando servicio runit...${NC}"

    daemon_runit_create_dir

    local service_dir
    service_dir=$(daemon_runit_generate_service)

    # Crear symlink en svdir si existe
    if [[ -d "${HOME}/.runit" ]]; then
        local svdir="${HOME}/.runit/current"
        if [[ ! -L "${svdir}/voidclaw" ]]; then
            ln -sf "$service_dir" "${svdir}/voidclaw" 2>/dev/null || true
        fi
    fi

    echo -e "${GREEN}✓ Servicio habilitado${NC}"
    echo -e "${YELLOW}Nota: En Termux, ejecuta 'termux-services' para gestionar el servicio${NC}"
    return 0
}

# Inicia servicio runit
daemon_runit_start() {
    echo -e "${BLUE}Iniciando servicio runit...${NC}"

    local service_dir="${TERMUX_RUNIT_DIR}/voidclaw"

    if [[ -d "$service_dir" && -x "${service_dir}/run" ]]; then
        # Iniciar mediante sv
        if command -v sv &>/dev/null; then
            sv up voidclaw 2>&1 || {
                echo -e "${YELLOW}Intentando inicio manual...${NC}"
                "${service_dir}/run" &
                echo $! > "${service_dir}/pid"
            }
        else
            # Inicio manual si sv no está disponible
            "${service_dir}/run" &
            echo $! > "${service_dir}/pid"
        fi
        echo -e "${GREEN}✓ Servicio iniciado${NC}"
        return 0
    else
        echo -e "${RED}✗ Servicio no configurado${NC}"
        return 1
    fi
}

# Detiene servicio runit
daemon_runit_stop() {
    echo -e "${YELLOW}Deteniendo servicio runit...${NC}"

    local service_dir="${TERMUX_RUNIT_DIR}/voidclaw"

    if [[ -f "${service_dir}/pid" ]]; then
        local pid
        pid=$(cat "${service_dir}/pid")
        if kill -0 "$pid" 2>/dev/null; then
            kill "$pid" 2>/dev/null
            rm -f "${service_dir}/pid"
            echo -e "${GREEN}✓ Servicio detenido${NC}"
            return 0
        fi
    fi

    # Intentar con sv
    if command -v sv &>/dev/null; then
        sv down voidclaw 2>&1 && {
            echo -e "${GREEN}✓ Servicio detenido${NC}"
            return 0
        }
    fi

    echo -e "${YELLOW}Servicio no estaba corriendo${NC}"
    return 0
}

# Verifica estado de servicio runit
daemon_runit_status() {
    local service_dir="${TERMUX_RUNIT_DIR}/voidclaw"

    if [[ -f "${service_dir}/pid" ]]; then
        local pid
        pid=$(cat "${service_dir}/pid")
        if kill -0 "$pid" 2>/dev/null; then
            echo -e "${GREEN}● voidclaw (runit) - Activo (PID: $pid)${NC}"
            return 0
        fi
    fi

    if command -v sv &>/dev/null; then
        local status
        status=$(sv status voidclaw 2>&1)
        if echo "$status" | grep -q "run"; then
            echo -e "${GREEN}● voidclaw (runit) - Activo${NC}"
            echo "$status"
            return 0
        fi
    fi

    echo -e "${RED}○ voidclaw (runit) - Inactivo${NC}"
    return 1
}

# Deshabilita servicio runit
daemon_runit_disable() {
    echo -e "${YELLOW}Deshabilitando servicio runit...${NC}"

    # Detener primero
    daemon_runit_stop

    # Remover directorio de servicio
    local service_dir="${TERMUX_RUNIT_DIR}/voidclaw"
    if [[ -d "$service_dir" ]]; then
        rm -rf "$service_dir"
        echo -e "${GREEN}✓ Servicio removido${NC}"
    fi

    # Remover symlink
    if [[ -L "${HOME}/.runit/current/voidclaw" ]]; then
        rm -f "${HOME}/.runit/current/voidclaw"
    fi

    return 0
}

# Crea script init.d genérico
daemon_initd_generate_script() {
    local init_script="/etc/init.d/voidclaw"

    cat > "$init_script" << 'EOF'
#!/system/bin/sh
### BEGIN INIT INFO
# Provides: voidclaw
# Required-Start: $local_fs $network
# Required-Stop: $local_fs
# Default-Start: 2 3 4 5
# Default-Stop: 0 1 6
# Short-Description: VoidClaw Loop Daemon
### END INIT INFO

BASE_DIR="@BASE_DIR@"
VOIDCLAW="${BASE_DIR}/voidclaw.sh"

case "$1" in
    start)
        echo "Starting VoidClaw daemon..."
        $VOIDCLAW --loop-daemon &
        ;;
    stop)
        echo "Stopping VoidClaw daemon..."
        pkill -f "voidclaw.sh --loop-daemon"
        ;;
    restart)
        $0 stop
        $0 start
        ;;
    status)
        if pgrep -f "voidclaw.sh --loop-daemon" > /dev/null; then
            echo "VoidClaw daemon is running"
        else
            echo "VoidClaw daemon is stopped"
        fi
        ;;
    *)
        echo "Usage: $0 {start|stop|restart|status}"
        exit 1
        ;;
esac

exit 0
EOF

    # Reemplazar placeholder
    sed -i "s|@BASE_DIR@|$(dirname "$(dirname "$VOIDCLAW_SCRIPT")")|g" "$init_script"
    chmod +x "$init_script"

    echo "$init_script"
}

# Habilita servicio init.d
daemon_initd_enable() {
    echo -e "${BLUE}Configurando servicio init.d...${NC}"

    # Requiere root
    if [[ $EUID -ne 0 ]]; then
        echo -e "${YELLOW}Se requiere root para init.d. Usando modo usuario...${NC}"
        # Fallback: crear script en home
        local user_init="${HOME}/.init.d/voidclaw"
        mkdir -p "${HOME}/.init.d"
        daemon_initd_generate_script
        mv "/etc/init.d/voidclaw" "$user_init" 2>/dev/null || {
            # Si no se puede mover, crear directamente
            cat > "$user_init" << EOF
#!/bin/bash
export VOIDCLAW_BASE_DIR=$(dirname "$(dirname "$VOIDCLAW_SCRIPT")")
${VOIDCLAW_SCRIPT} --loop-daemon &
EOF
            chmod +x "$user_init"
        }
        echo -e "${GREEN}✓ Script creado en $user_init${NC}"
        echo -e "${YELLOW}Agrega esto a tu ~/.bashrc para auto-inicio:${NC}"
        echo "  [[ -x ~/.init.d/voidclaw ]] && ~/.init.d/voidclaw"
        return 0
    fi

    local init_script
    init_script=$(daemon_initd_generate_script)

    # Habilitar en runlevels
    if command -v update-rc.d &>/dev/null; then
        update-rc.d voidclaw defaults
    elif command -v chkconfig &>/dev/null; then
        chkconfig --add voidclaw
        chkconfig voidclaw on
    fi

    echo -e "${GREEN}✓ Servicio init.d habilitado${NC}"
    return 0
}

# Inicia servicio init.d
daemon_initd_start() {
    echo -e "${BLUE}Iniciando servicio init.d...${NC}"

    if [[ -x "/etc/init.d/voidclaw" ]]; then
        /etc/init.d/voidclaw start
        return $?
    elif [[ -x "${HOME}/.init.d/voidclaw" ]]; then
        "${HOME}/.init.d/voidclaw" start
        return $?
    else
        echo -e "${RED}✗ Servicio no encontrado${NC}"
        return 1
    fi
}

# Detiene servicio init.d
daemon_initd_stop() {
    echo -e "${YELLOW}Deteniendo servicio init.d...${NC}"

    if [[ -x "/etc/init.d/voidclaw" ]]; then
        /etc/init.d/voidclaw stop
        return $?
    elif [[ -x "${HOME}/.init.d/voidclaw" ]]; then
        "${HOME}/.init.d/voidclaw" stop
        return $?
    else
        # Fallback: matar proceso
        pkill -f "voidclaw.sh --loop-daemon" 2>/dev/null
        echo -e "${GREEN}✓ Proceso terminado${NC}"
        return 0
    fi
}

# Verifica estado de servicio init.d
daemon_initd_status() {
    if pgrep -f "voidclaw.sh --loop-daemon" > /dev/null; then
        local pid
        pid=$(pgrep -f "voidclaw.sh --loop-daemon" | head -1)
        echo -e "${GREEN}● voidclaw (init.d) - Activo (PID: $pid)${NC}"
        return 0
    else
        echo -e "${RED}○ voidclaw (init.d) - Inactivo${NC}"
        return 1
    fi
}

# Deshabilita servicio init.d
daemon_initd_disable() {
    echo -e "${YELLOW}Deshabilitando servicio init.d...${NC}"

    daemon_initd_stop

    if [[ $EUID -eq 0 ]]; then
        if command -v update-rc.d &>/dev/null; then
            update-rc.d voidclaw remove
        elif command -v chkconfig &>/dev/null; then
            chkconfig voidclaw off
            chkconfig --del voidclaw
        fi
        rm -f "/etc/init.d/voidclaw"
    else
        rm -f "${HOME}/.init.d/voidclaw"
    fi

    echo -e "${GREEN}✓ Servicio deshabilitado${NC}"
    return 0
}

# ============================================================================
# API PRINCIPAL
# ============================================================================

# Habilita daemon (detecta init automáticamente)
daemon_enable() {
    local init_system
    init_system=$(daemon_detect_init)

    echo -e "${BLUE}Detectado sistema de init: ${init_system}${NC}"
    echo ""

    case "$init_system" in
        systemd)
            daemon_systemd_enable
            ;;
        runit)
            daemon_runit_enable
            ;;
        initd)
            daemon_initd_enable
            ;;
        *)
            echo -e "${RED}No se detectó un sistema de init soportado${NC}"
            echo ""
            echo "Opciones:"
            echo "  1. Instalar systemd (recomendado)"
            echo "  2. Instalar runit (para Termux)"
            echo "  3. Usar modo manual: ./voidclaw.sh --loop"
            return 1
            ;;
    esac

    # Actualizar configuración
    daemon_set_config "enabled" "true"

    echo ""
    echo -e "${GREEN}================================${NC}"
    echo -e "${GREEN}  Daemon habilitado exitosamente  ${NC}"
    echo -e "${GREEN}================================${NC}"
    echo ""
    echo "El loop se ejecutará automáticamente al iniciar sesión."
    echo ""

    return 0
}

# Deshabilita daemon
daemon_disable() {
    local init_system
    init_system=$(daemon_detect_init)

    case "$init_system" in
        systemd)
            daemon_systemd_disable
            ;;
        runit)
            daemon_runit_disable
            ;;
        initd)
            daemon_initd_disable
            ;;
        *)
            echo -e "${YELLOW}No hay servicio que deshabilitar${NC}"
            ;;
    esac

    # Actualizar configuración
    daemon_set_config "enabled" "false"

    echo -e "${GREEN}✓ Daemon deshabilitado${NC}"
    return 0
}

# Inicia daemon
daemon_start() {
    local init_system
    init_system=$(daemon_detect_init)

    case "$init_system" in
        systemd)
            daemon_systemd_start
            ;;
        runit)
            daemon_runit_start
            ;;
        initd)
            daemon_initd_start
            ;;
        *)
            echo -e "${YELLOW}Iniciando en modo manual...${NC}"
            "${VOIDCLAW_SCRIPT}" --loop-daemon &
            echo $! > "${VOIDCLAW_BASE_DIR:-/tmp}/voidclaw.pid"
            echo -e "${GREEN}✓ Proceso iniciado (PID: $!)${NC}"
            ;;
    esac

    return $?
}

# Detiene daemon
daemon_stop() {
    local init_system
    init_system=$(daemon_detect_init)

    case "$init_system" in
        systemd)
            daemon_systemd_stop
            ;;
        runit)
            daemon_runit_stop
            ;;
        initd)
            daemon_initd_stop
            ;;
        *)
            echo -e "${YELLOW}Deteniendo proceso manual...${NC}"
            if [[ -f "${VOIDCLAW_BASE_DIR:-/tmp}/voidclaw.pid" ]]; then
                kill "$(cat "${VOIDCLAW_BASE_DIR:-/tmp}/voidclaw.pid")" 2>/dev/null
                rm -f "${VOIDCLAW_BASE_DIR:-/tmp}/voidclaw.pid"
            else
                pkill -f "voidclaw.sh --loop-daemon" 2>/dev/null
            fi
            echo -e "${GREEN}✓ Proceso detenido${NC}"
            ;;
    esac

    return $?
}

# Verifica estado del daemon
daemon_status() {
    local init_system
    init_system=$(daemon_detect_init)

    echo "=== Estado del Daemon ==="
    echo "Sistema de init detectado: ${init_system}"
    echo ""

    case "$init_system" in
        systemd)
            daemon_systemd_status
            ;;
        runit)
            daemon_runit_status
            ;;
        initd)
            daemon_initd_status
            ;;
        *)
            if pgrep -f "voidclaw.sh --loop-daemon" > /dev/null; then
                local pid
                pid=$(pgrep -f "voidclaw.sh --loop-daemon" | head -1)
                echo -e "${GREEN}● voidclaw - Activo (PID: $pid)${NC}"
                return 0
            else
                echo -e "${RED}○ voidclaw - Inactivo${NC}"
                return 1
            fi
            ;;
    esac
}

# Verifica si el daemon está habilitado en configuración
daemon_is_enabled() {
    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    local enabled
    if command -v jq &>/dev/null; then
        enabled=$(jq -r '.loop.enabled // false' "$CONFIG_FILE" 2>/dev/null)
    else
        enabled=$(grep -o '"enabled"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$enabled" ]] && enabled="true" || enabled="false"
    fi

    [[ "$enabled" == "true" ]]
}

# Guarda configuración del daemon
daemon_set_config() {
    local key="$1"
    local value="$2"

    if [[ ! -f "$CONFIG_FILE" ]]; then
        return 1
    fi

    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        jq ".loop.$key = $value" "$CONFIG_FILE" > "$temp_file" 2>/dev/null
        mv "$temp_file" "$CONFIG_FILE"
    fi
}

# Muestra información del daemon
daemon_info() {
    echo "=== Información del Daemon ==="
    echo ""
    echo "Script: $VOIDCLAW_SCRIPT"
    echo "Config: $CONFIG_FILE"
    echo ""

    local init_system
    init_system=$(daemon_detect_init)
    echo "Init system: $init_system"

    case "$init_system" in
        systemd)
            echo "Directorio de servicios: $SYSTEMD_USER_DIR"
            echo "Comando: systemctl --user [start|stop|status] voidclaw.service"
            ;;
        runit)
            echo "Directorio de servicios: $TERMUX_RUNIT_DIR"
            echo "Comando: sv [start|stop|status] voidclaw"
            ;;
        initd)
            echo "Directorio de servicios: /etc/init.d"
            echo "Comando: /etc/init.d/voidclaw [start|stop|status]"
            ;;
    esac

    echo ""
    echo "Estado en configuración:"
    if daemon_is_enabled; then
        echo -e "  ${GREEN}Habilitado${NC}"
    else
        echo -e "  ${RED}Deshabilitado${NC}"
    fi
}

# Función para modo daemon (usada internamente por --loop-daemon)
daemon_run() {
    # Configurar logging
    local log_file="${VOIDCLAW_BASE_DIR:-/tmp}/logs/daemon.log"
    mkdir -p "$(dirname "$log_file")"

    # Cargar configuración
    source "${SCRIPT_DIR}/loop.sh"

    # Obtener configuración
    local interval max_iter
    interval=$(loop_get_config "interval_seconds")
    max_iter=$(loop_get_config "max_iterations")

    # Valores por defecto
    interval="${interval:-5}"
    max_iter="${max_iter:-0}"  # 0 = sin límite en modo daemon

    log_info "Daemon iniciado: interval=${interval}s, max_iter=${max_iter:-∞}"

    # Ejecutar loop sin límite de iteraciones
    loop_run_cycle "$max_iter" "$interval"
}
