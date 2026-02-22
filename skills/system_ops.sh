#!/bin/bash
# skills/system_ops.sh - Skill de operaciones del sistema

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

SKILL_NAME="system_ops"
SKILL_DESCRIPTION="Operaciones del sistema - ejecutar comandos, información del sistema, procesos"

# Registra herramientas para OpenAI
system_ops_register() {
    source "${SCRIPT_DIR}/../lib/tools.sh"
    
    # Ejecutar comando
    tools_register "system_ops.run" \
        "Ejecuta un comando en la shell del sistema" \
        '{"type": "object", "properties": {"command": {"type": "string", "description": "Comando a ejecutar"}, "timeout": {"type": "integer", "description": "Timeout en segundos"}}, "required": ["command"]}'
    
    # Información del sistema
    tools_register "system_ops.info" \
        "Obtiene información del sistema (OS, CPU, memoria, disco)" \
        '{"type": "object", "properties": {"detail": {"type": "string", "description": "Nivel de detalle: basic, full"}}, "required": []}'
    
    # Listar procesos
    tools_register "system_ops.ps" \
        "Lista procesos en ejecución" \
        '{"type": "object", "properties": {"filter": {"type": "string", "description": "Filtrar por nombre de proceso"}}, "required": []}'
    
    # Uso de recursos
    tools_register "system_ops.resources" \
        "Muestra uso de recursos (CPU, memoria, disco)" \
        '{"type": "object", "properties": {"type": {"type": "string", "description": "Tipo de recurso: cpu, memory, disk, all"}}, "required": []}'
}

# Ejecuta comando
system_ops_run() {
    local command="$1"
    local timeout="${2:-30}"
    
    # Validaciones de seguridad
    local blocked_patterns=("rm -rf /" "mkfs" "dd if=" ":(){:|:&};" "> /dev/sd" "chmod -R 777 /")
    
    for pattern in "${blocked_patterns[@]}"; do
        if [[ "$command" == *"$pattern"* ]]; then
            echo "ERROR: Comando bloqueado por seguridad: $pattern"
            log_error "system_ops.run: Comando bloqueado: $command"
            return 1
        fi
    done
    
    echo "Ejecutando: $command"
    log_info "system_ops.run: $command"
    
    # Ejecutar con timeout
    if command -v timeout &>/dev/null; then
        timeout "$timeout" bash -c "$command" 2>&1
    else
        # Fallback sin timeout
        bash -c "$command" 2>&1
    fi
    
    local result=$?
    log_info "system_ops.run: exit code $result"
    return $result
}

# Información del sistema
system_ops_info() {
    local detail="${1:-basic}"
    
    echo "=== Información del Sistema ==="
    echo ""
    
    # OS
    echo "Sistema Operativo:"
    if [[ -f /etc/os-release ]]; then
        . /etc/os-release
        echo "  Nombre: $NAME"
        echo "  Versión: $VERSION"
        echo "  ID: $ID"
    else
        uname -a
    fi
    echo ""
    
    if [[ "$detail" == "full" ]]; then
        # Kernel
        echo "Kernel:"
        uname -r
        echo ""
        
        # Arquitectura
        echo "Arquitectura:"
        uname -m
        echo ""
        
        # Hostname
        echo "Hostname:"
        hostname
        echo ""
        
        # Uptime
        echo "Uptime:"
        uptime 2>/dev/null || echo "No disponible"
        echo ""
    fi
}

# Lista procesos
system_ops_ps() {
    local filter="$1"
    
    echo "=== Procesos ==="
    
    if [[ -n "$filter" ]]; then
        ps aux 2>/dev/null | grep -i "$filter" | grep -v grep
    else
        ps aux 2>/dev/null | head -20
    fi
}

# Uso de recursos
system_ops_resources() {
    local type="${1:-all}"
    
    echo "=== Uso de Recursos ==="
    echo ""
    
    if [[ "$type" == "cpu" || "$type" == "all" ]]; then
        echo "CPU:"
        if command -v top &>/dev/null; then
            top -bn1 2>/dev/null | head -5
        else
            echo "  Información de CPU no disponible"
        fi
        echo ""
    fi
    
    if [[ "$type" == "memory" || "$type" == "all" ]]; then
        echo "Memoria:"
        if command -v free &>/dev/null; then
            free -h 2>/dev/null
        else
            echo "  Información de memoria no disponible"
        fi
        echo ""
    fi
    
    if [[ "$type" == "disk" || "$type" == "all" ]]; then
        echo "Disco:"
        df -h 2>/dev/null | head -10
        echo ""
    fi
}

# Ejecuta acción de skill
skill_execute() {
    local action="$1"
    local params="$2"
    
    local command timeout detail filter resource_type
    
    if command -v jq &>/dev/null; then
        command=$(echo "$params" | jq -r '.command // empty' 2>/dev/null)
        timeout=$(echo "$params" | jq -r '.timeout // 30' 2>/dev/null)
        detail=$(echo "$params" | jq -r '.detail // "basic"' 2>/dev/null)
        filter=$(echo "$params" | jq -r '.filter // empty' 2>/dev/null)
        resource_type=$(echo "$params" | jq -r '.type // "all"' 2>/dev/null)
    fi
    
    case "$action" in
        "run")
            system_ops_run "$command" "$timeout"
            ;;
        "info")
            system_ops_info "$detail"
            ;;
        "ps")
            system_ops_ps "$filter"
            ;;
        "resources")
            system_ops_resources "$resource_type"
            ;;
        *)
            echo "Acción desconocida: $action"
            return 1
            ;;
    esac
}
