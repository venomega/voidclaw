#!/bin/bash
# lib/loop.sh - Sistema de ejecución automática de tareas pendientes

# Usar VOIDCLAW_BASE_DIR si está definido
if [[ -n "$VOIDCLAW_BASE_DIR" ]]; then
    SCRIPT_DIR="${VOIDCLAW_BASE_DIR}/lib"
    CONFIG_FILE="${VOIDCLAW_BASE_DIR}/config/settings.json"
    PENDING_FILE="${VOIDCLAW_BASE_DIR}/workspace/tasks/pending.json"
    COMPLETED_FILE="${VOIDCLAW_BASE_DIR}/workspace/tasks/completed.json"
else
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    CONFIG_FILE="${SCRIPT_DIR}/../config/settings.json"
    PENDING_FILE="${SCRIPT_DIR}/../workspace/tasks/pending.json"
    COMPLETED_FILE="${SCRIPT_DIR}/../workspace/tasks/completed.json"
fi

# Carga configuración del loop
loop_get_config() {
    local key="$1"
    if command -v jq &>/dev/null; then
        jq -r ".loop.$key // empty" "$CONFIG_FILE" 2>/dev/null
    else
        grep -o "\"$key\"[[:space:]]*:[[:space:]]*[^,}]*" "$CONFIG_FILE" | sed 's/.*: *//'
    fi
}

# Obtiene tareas pendientes
loop_get_pending() {
    if [[ ! -f "$PENDING_FILE" ]]; then
        echo "[]"
        return
    fi
    
    if command -v jq &>/dev/null; then
        jq -c '.tasks // []' "$PENDING_FILE" 2>/dev/null
    else
        # Fallback básico
        grep -o '"tasks"[[:space:]]*:[[:space:]]*\[[^]]*\]' "$PENDING_FILE" | sed 's/"tasks"[[:space:]]*:[[:space:]]*//'
    fi
}

# Cuenta tareas pendientes
loop_count_pending() {
    local pending
    pending=$(loop_get_pending)
    
    if command -v jq &>/dev/null; then
        echo "$pending" | jq 'length' 2>/dev/null
    else
        echo "$pending" | grep -o '"id"' | wc -l
    fi
}

# Obtiene siguiente tarea pendiente
loop_get_next_task() {
    local pending
    pending=$(loop_get_pending)
    
    if command -v jq &>/dev/null; then
        echo "$pending" | jq '.[0] // empty' 2>/dev/null
    else
        # Fallback: retorna primera tarea encontrada
        echo "$pending" | grep -o '{[^}]*}' | head -1
    fi
}

# Remueve tarea de pendientes
loop_remove_pending() {
    local task_id="$1"

    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        # Usar filter para remover tarea por ID
        if jq ".tasks = [.tasks[] | select(.id != \"$task_id\")]" "$PENDING_FILE" > "$temp_file" 2>/dev/null; then
            mv "$temp_file" "$PENDING_FILE"
        else
            log_error "Error al remover tarea $task_id de pendientes"
            return 1
        fi
    fi
    return 0
}

# Agrega tarea a completadas
loop_mark_completed() {
    local task="$1"
    
    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        
        # Agregar timestamp de completado
        local completed_task
        completed_task=$(echo "$task" | jq '. + {"completed_at": "'"$(date -Iseconds)"'", "status": "completed"}')
        
        jq ".tasks += [$completed_task]" "$COMPLETED_FILE" > "$temp_file" 2>/dev/null
        mv "$temp_file" "$COMPLETED_FILE"
    fi
}

# Ejecuta una tarea
loop_execute_task() {
    local task="$1"

    local action
    local params
    local task_id

    if command -v jq &>/dev/null; then
        action=$(echo "$task" | jq -r '.action // empty' 2>/dev/null)
        params=$(echo "$task" | jq -c '.params // {}' 2>/dev/null)
        task_id=$(echo "$task" | jq -r '.id // empty' 2>/dev/null)
    else
        # Fallback parsing
        action=$(echo "$task" | grep -o '"action"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"action"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
        task_id=$(echo "$task" | grep -o '"id"[[:space:]]*:[[:space:]]*"[^"]*"' | sed 's/"id"[[:space:]]*:[[:space:]]*"\([^"]*\)"/\1/')
    fi

    if [[ -z "$action" ]]; then
        log_error "Tarea sin acción definida"
        # Remover tarea inválida
        loop_remove_pending "$task_id"
        return 0
    fi

    echo "Ejecutando tarea: $action (ID: $task_id)"
    log_info "Ejecutando tarea: $action (ID: $task_id)"

    # Ejecutar mediante tools.sh (usar ruta absoluta para evitar sobrescritura de SCRIPT_DIR)
    local tools_lib="${VOIDCLAW_BASE_DIR:-$SCRIPT_DIR}/lib/tools.sh"
    source "$tools_lib"
    local result=0
    tools_execute "$action" "$params" || result=$?

    if [[ $result -eq 0 ]]; then
        loop_remove_pending "$task_id" || true
        loop_mark_completed "$task"
        echo "Tarea completada: $task_id"
        log_info "Tarea completada: $task_id"
    else
        # Incrementar retry_count
        loop_increment_retry "$task_id" || true
        log_error "Tarea fallida: $task_id (exit code: $result)"
    fi

    # Siempre retornar 0 para continuar el loop
    return 0
}

# Incrementa contador de reintentos
loop_increment_retry() {
    local task_id="$1"
    
    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        jq "(.tasks[] | select(.id == \"$task_id\") | .retry_count) += 1" "$PENDING_FILE" > "$temp_file" 2>/dev/null
        mv "$temp_file" "$PENDING_FILE"
    fi
}

# Ejecuta ciclo de procesamiento
loop_run_cycle() {
    # Deshabilitar exit on error para el loop
    set +e

    local max_iterations="${1:-50}"
    local interval="${2:-5}"
    local iteration=0

    echo "Iniciando loop de procesamiento..."
    echo "Presiona Ctrl+C para detener"
    echo ""

    log_info "Iniciando loop: max_iterations=$max_iterations, interval=$interval"

    # Loop infinito si max_iterations es 0
    while [[ "$max_iterations" -eq 0 ]] || [[ $iteration -lt $max_iterations ]]; do
        local pending_count
        pending_count=$(loop_count_pending)

        echo "[$(date +%H:%M:%S)] Iteración $iteration - Tareas pendientes: $pending_count"

        if [[ $pending_count -gt 0 ]]; then
            local task
            task=$(loop_get_next_task)

            if [[ -n "$task" && "$task" != "null" ]]; then
                loop_execute_task "$task"
            fi
        else
            echo "  No hay tareas pendientes. Esperando..."
        fi

        ((iteration++))
        sleep "$interval"
    done

    echo ""
    echo "Loop finalizado después de $iteration iteraciones"
    log_info "Loop finalizado: $iteration iteraciones"
}

# Inicia el loop principal
loop_start() {
    local enabled
    local interval
    local max_iter

    enabled=$(loop_get_config "enabled")
    interval=$(loop_get_config "interval_seconds")
    max_iter=$(loop_get_config "max_iterations")

    # Valores por defecto
    enabled="${enabled:-true}"
    interval="${interval:-5}"
    max_iter="${max_iter:-50}"

    # Verificar si el daemon está habilitado
    local daemon_enabled
    if command -v jq &>/dev/null; then
        daemon_enabled=$(jq -r '.loop.daemon // false' "$CONFIG_FILE" 2>/dev/null)
    else
        daemon_enabled=$(grep -o '"daemon"[[:space:]]*:[[:space:]]*true' "$CONFIG_FILE" 2>/dev/null)
        [[ -n "$daemon_enabled" ]] && daemon_enabled="true" || daemon_enabled="false"
    fi

    if [[ "$daemon_enabled" == "true" ]]; then
        echo -e "\033[0;33mEl daemon está habilitado en la configuración.\033[0m"
        echo ""
        echo "Opciones:"
        echo "  1. Ver estado del daemon: ./voidclaw.sh --daemon-status"
        echo "  2. Ejecutar loop manual temporal (sin afectar daemon)"
        echo "  3. Salir"
        echo ""
        read -p "Selecciona una opción [1-3]: " option

        case "$option" in
            1)
                source "${SCRIPT_DIR}/daemon.sh"
                daemon_status
                return $?
                ;;
            2)
                echo "Ejecutando loop manual..."
                ;;
            *)
                return 0
                ;;
        esac
    fi

    if [[ "$enabled" != "true" && "$1" != "force" ]]; then
        echo "El loop automático está deshabilitado en la configuración"
        echo "Usa --loop force para ejecutar de todos modos"
        return 1
    fi

    loop_run_cycle "$max_iter" "$interval"
}

# Muestra estado del loop
loop_status() {
    local pending_count
    pending_count=$(loop_count_pending)
    
    local enabled
    enabled=$(loop_get_config "enabled")
    
    local interval
    interval=$(loop_get_config "interval_seconds")
    
    local max_iter
    max_iter=$(loop_get_config "max_iterations")
    
    echo "=== Estado del Loop ==="
    echo "Habilitado: ${enabled:-false}"
    echo "Intervalo: ${interval:-5}s"
    echo "Máx iteraciones: ${max_iter:-50}"
    echo "Tareas pendientes: $pending_count"
}
