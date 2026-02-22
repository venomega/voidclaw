#!/bin/bash
# skills/task_manager.sh - Skill de gestión de tareas

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PENDING_FILE="${SCRIPT_DIR}/../workspace/tasks/pending.json"

SKILL_NAME="task_manager"
SKILL_DESCRIPTION="Gestión de tareas pendientes - crear, listar, completar tareas"

# Registra herramientas para OpenAI
task_manager_register() {
    source "${SCRIPT_DIR}/../lib/tools.sh"
    
    # Herramienta: crear_tarea
    tools_register "crear_tarea" \
        "Crea una nueva tarea pendiente para ejecutar después" \
        '{"type": "object", "properties": {"description": {"type": "string", "description": "Descripción de la tarea"}, "action": {"type": "string", "description": "Acción a ejecutar (ej: file_ops.copy, system_ops.run)"}, "params": {"type": "object", "description": "Parámetros para la acción"}, "priority": {"type": "integer", "description": "Prioridad (1-5, siendo 5 la más alta)"}}, "required": ["description", "action"]}'
    
    # Herramienta: listar_tareas
    tools_register "listar_tareas" \
        "Lista todas las tareas pendientes actuales" \
        '{"type": "object", "properties": {"status": {"type": "string", "description": "Filtrar por estado: pending, completed, all"}}, "required": []}'
    
    # Herramienta: completar_tarea
    tools_register "completar_tarea" \
        "Marca una tarea como completada" \
        '{"type": "object", "properties": {"task_id": {"type": "string", "description": "ID de la tarea a completar"}}, "required": ["task_id"]}'
}

# Genera ID único para tarea
task_generate_id() {
    echo "task_$(date +%s)_$RANDOM"
}

# Crea una nueva tarea
task_create() {
    local description="$1"
    local action="$2"
    local params="${3:-{}}"
    local priority="${4:-3}"
    
    local task_id
    task_id=$(task_generate_id)
    
    local timestamp
    timestamp=$(date -Iseconds 2>/dev/null || date +%Y-%m-%dT%H:%M:%S%z)
    
    local new_task
    new_task="{\"id\": \"$task_id\", \"created_at\": \"$timestamp\", \"description\": \"$description\", \"action\": \"$action\", \"params\": $params, \"status\": \"pending\", \"priority\": $priority, \"retry_count\": 0}"
    
    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        jq ".tasks += [$new_task]" "$PENDING_FILE" > "$temp_file" 2>/dev/null
        mv "$temp_file" "$PENDING_FILE"
    else
        # Fallback sin jq - append simple
        local temp_file
        temp_file=$(mktemp)
        # Leer contenido actual, remover cierre y agregar nueva tarea
        sed 's/}[[:space:]]*$//' "$PENDING_FILE" > "$temp_file"
        echo ", $new_task]}" >> "$temp_file"
        mv "$temp_file" "$PENDING_FILE"
    fi
    
    echo "Tarea creada: $task_id"
    echo "  Descripción: $description"
    echo "  Acción: $action"
    echo "  Prioridad: $priority"
    
    # Log
    echo "[$(date -Iseconds)] [TASK_CREATE] $task_id - $description" >> "${SCRIPT_DIR}/../logs/voidclaw.log"
    
    echo "$task_id"
}

# Lista tareas
task_list() {
    local status_filter="${1:-pending}"
    
    if [[ ! -f "$PENDING_FILE" ]]; then
        echo "No hay archivo de tareas"
        return 1
    fi
    
    if command -v jq &>/dev/null; then
        if [[ "$status_filter" == "pending" ]]; then
            jq -r '.tasks[] | select(.status == "pending") | "  [\(.priority)] \(.id): \(.description) (\(.action))"' "$PENDING_FILE" 2>/dev/null
        elif [[ "$status_filter" == "completed" ]]; then
            local completed_file="${SCRIPT_DIR}/../workspace/tasks/completed.json"
            if [[ -f "$completed_file" ]]; then
                jq -r '.tasks[] | "  [\(.priority)] \(.id): \(.description) (\(.action))"' "$completed_file" 2>/dev/null
            fi
        else
            jq -r '.tasks[] | "  [\(.priority)] \(.id): \(.description) (\(.action)) - \(.status)"' "$PENDING_FILE" 2>/dev/null
        fi
    else
        # Fallback básico
        grep -o '"description"[[:space:]]*:[[:space:]]*"[^"]*"' "$PENDING_FILE" | sed 's/"description"[[:space:]]*:[[:space:]]*"\([^"]*\)"/  - \1/'
    fi
}

# Completa una tarea
task_complete() {
    local task_id="$1"
    
    if command -v jq &>/dev/null; then
        # Mover a completadas
        local completed_file="${SCRIPT_DIR}/../workspace/tasks/completed.json"
        local task_data
        task_data=$(jq ".tasks[] | select(.id == \"$task_id\")" "$PENDING_FILE" 2>/dev/null)
        
        if [[ -n "$task_data" && "$task_data" != "null" ]]; then
            # Agregar timestamp y estado
            local completed_task
            completed_task=$(echo "$task_data" | jq '. + {"completed_at": "'"$(date -Iseconds)"'", "status": "completed"}')
            
            # Agregar a completadas
            local temp_completed
            temp_completed=$(mktemp)
            jq ".tasks += [$completed_task]" "$completed_file" > "$temp_completed" 2>/dev/null
            mv "$temp_completed" "$completed_file"
            
            # Remover de pendientes
            local temp_pending
            temp_pending=$(mktemp)
            jq ".tasks = [.tasks[] | select(.id != \"$task_id\")]" "$PENDING_FILE" > "$temp_pending" 2>/dev/null
            mv "$temp_pending" "$PENDING_FILE"
            
            echo "Tarea completada: $task_id"
            log_info "Tarea completada: $task_id"
            return 0
        else
            echo "Tarea no encontrada: $task_id"
            return 1
        fi
    else
        echo "ERROR: jq required for task completion"
        return 1
    fi
}

# Elimina una tarea
task_delete() {
    local task_id="$1"
    
    if command -v jq &>/dev/null; then
        local temp_file
        temp_file=$(mktemp)
        jq ".tasks = [.tasks[] | select(.id != \"$task_id\")]" "$PENDING_FILE" > "$temp_file" 2>/dev/null
        mv "$temp_file" "$PENDING_FILE"
        echo "Tarea eliminada: $task_id"
    else
        echo "ERROR: jq required"
        return 1
    fi
}

# Ejecuta acción de skill
skill_execute() {
    local action="$1"
    local params="$2"
    
    case "$action" in
        "crear_tarea"| "create")
            local description action_name task_params priority
            if command -v jq &>/dev/null; then
                description=$(echo "$params" | jq -r '.description // "Tarea sin descripción"' 2>/dev/null)
                action_name=$(echo "$params" | jq -r '.action // "unknown"' 2>/dev/null)
                task_params=$(echo "$params" | jq -c '.params // {}' 2>/dev/null)
                priority=$(echo "$params" | jq -r '.priority // 3' 2>/dev/null)
            else
                description="Tarea desde params"
                action_name="unknown"
                task_params="$params"
                priority=3
            fi
            task_create "$description" "$action_name" "$task_params" "$priority"
            ;;
        "listar_tareas" | "list")
            local status
            if command -v jq &>/dev/null; then
                status=$(echo "$params" | jq -r '.status // "pending"' 2>/dev/null)
            else
                status="pending"
            fi
            task_list "$status"
            ;;
        "completar_tarea" | "complete")
            local task_id
            if command -v jq &>/dev/null; then
                task_id=$(echo "$params" | jq -r '.task_id // empty' 2>/dev/null)
            fi
            if [[ -n "$task_id" ]]; then
                task_complete "$task_id"
            else
                echo "ERROR: task_id requerido"
                return 1
            fi
            ;;
        "eliminar_tarea" | "delete")
            local task_id
            if command -v jq &>/dev/null; then
                task_id=$(echo "$params" | jq -r '.task_id // empty' 2>/dev/null)
            fi
            if [[ -n "$task_id" ]]; then
                task_delete "$task_id"
            else
                echo "ERROR: task_id requerido"
                return 1
            fi
            ;;
        *)
            echo "Acción desconocida: $action"
            return 1
            ;;
    esac
}
