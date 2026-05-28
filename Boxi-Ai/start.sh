#!/bin/bash
# ===========================================================
# Boxi-AI — Script de inicio para Pterodactyl
# Yolk      : ghcr.io/vicemi/yolks:boxi-ai_latest
# Python    : 3.11 | llama-cpp-python (CPU) | FastAPI
# Repositorio: https://github.com/Vicemi/eggs-pterodactyl
# ===========================================================

# FIX: sin -e — evita crash loop si la descarga del modelo falla
set -uo pipefail

cd /home/container || { echo "ERROR: No se pudo acceder a /home/container"; exit 1; }

# ── Colores ───────────────────────────────────────────────────────────────────
RED='\033[0;31m'
GREEN='\033[0;32m'
YELLOW='\033[1;33m'
CYAN='\033[0;36m'
BLUE='\033[0;34m'
MAGENTA='\033[0;35m'
BOLD='\033[1m'
DIM='\033[2m'
NC='\033[0m'

ok()   { echo -e "${GREEN}  ✓ ${NC}$*"; }
warn() { echo -e "${YELLOW}  ⚠ ${NC}$*"; }
info() { echo -e "${CYAN}  → ${NC}$*"; }
die()  { echo -e "${RED}  ✗ FATAL: $*${NC}"; exit 1; }
sep()  { echo -e "${DIM}  ──────────────────────────────────────────────${NC}"; }

# ── Banner ASCII ──────────────────────────────────────────────────────────────
clear 2>/dev/null || true
echo ""
echo -e "${CYAN}${BOLD}"
echo '  ______           _             ___  _____ '
echo '  | ___ \         (_)           / _ \|_   _|'
echo '  | |_/ / _____  ___   ______  / /_\ \ | |  '
echo '  | ___ \/ _ \ \/ / | |______| |  _  | | |  '
echo '  | |_/ / (_) >  <| |          | | | |_| |_ '
echo '  \____/ \___/_/\_\_|          \_| |_/\___/ '
echo -e "${NC}"
echo -e "${DIM}  AI API para Pterodactyl — by Vicemi${NC}"
echo -e "${DIM}  github.com/Vicemi/eggs-pterodactyl${NC}"
echo ""
sep

# ─────────────────────────────────────────────────────────────────────────────
# PASO 0: Variables y configuración
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[0/4] Configuración${NC}"
sep

# FIX: limpiar CRLF de variables de entorno (pueden llegar con \r desde el panel)
MODEL_NAME="${MODEL_NAME:-qwen2.5-uncensored}"
MODEL_NAME="${MODEL_NAME//[$'\r\n']}"

API_TOKEN="${API_TOKEN:-changeme}"
API_PORT="${SERVER_PORT:-5832}"
MAX_TOKENS="${MAX_TOKENS:-512}"
N_THREADS="${N_THREADS:-2}"
N_CTX="${N_CTX:-4096}"
HF_TOKEN="${HF_TOKEN:-}"
MODEL_CACHE="/home/container/model_cache"
CONTEXT_FILE="/home/container/context.txt"

[ -n "$API_TOKEN" ] || die "API_TOKEN no puede estar vacío"
[ "$API_TOKEN" != "changeme" ] || warn "API_TOKEN usa el valor por defecto — cámbialo en el panel"

echo -e "  ${DIM}Modelo   ${NC}  ${CYAN}${MODEL_NAME}${NC}"
echo -e "  ${DIM}Puerto   ${NC}  ${CYAN}${API_PORT}${NC}"
echo -e "  ${DIM}Threads  ${NC}  ${CYAN}${N_THREADS}${NC}"
echo -e "  ${DIM}MaxTok   ${NC}  ${CYAN}${MAX_TOKENS}${NC}"
echo -e "  ${DIM}Ctx Len  ${NC}  ${CYAN}${N_CTX}${NC}"

# ── Verificar app.py ──────────────────────────────────────────────────────────
APP_PY=""
for candidate in "/app/app.py" "/home/container/app.py"; do
    if [ -f "$candidate" ]; then
        APP_PY="$candidate"
        break
    fi
done
[ -n "$APP_PY" ] || die "app.py no encontrado en /app/app.py ni en /home/container/app.py"
ok "app.py encontrado: ${APP_PY}"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 1: Registro de modelos
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[1/4] Modelo seleccionado${NC}"
sep

declare -A MTYPE MREPO MFILE MLABEL

MTYPE["qwen2.5-uncensored"]="transformers"
MREPO["qwen2.5-uncensored"]="thirdeyeai/Qwen2.5-0.5B-Instruct-uncensored"
MFILE["qwen2.5-uncensored"]=""
MLABEL["qwen2.5-uncensored"]="Qwen2.5 0.5B Uncensored"

MTYPE["qwen3.5-0.8b"]="gguf"
MREPO["qwen3.5-0.8b"]="unsloth/Qwen3.5-0.8B-GGUF"
MFILE["qwen3.5-0.8b"]="Qwen3.5-0.8B-Q4_K_M.gguf"
MLABEL["qwen3.5-0.8b"]="Qwen3.5 0.8B (GGUF Q4_K_M)"

MTYPE["llama3.2-1b"]="gguf"
MREPO["llama3.2-1b"]="bartowski/Llama-3.2-1B-Instruct-GGUF"
MFILE["llama3.2-1b"]="Llama-3.2-1B-Instruct-Q4_K_M.gguf"
MLABEL["llama3.2-1b"]="Llama 3.2 1B Instruct (GGUF Q4_K_M)"

MTYPE["smollm2-1.7b"]="gguf"
MREPO["smollm2-1.7b"]="bartowski/SmolLM2-1.7B-Instruct-GGUF"
MFILE["smollm2-1.7b"]="SmolLM2-1.7B-Instruct-Q4_K_M.gguf"
MLABEL["smollm2-1.7b"]="SmolLM2 1.7B Instruct (GGUF Q4_K_M)"

MTYPE["qwen2.5-1.5b"]="gguf"
MREPO["qwen2.5-1.5b"]="bartowski/Qwen2.5-1.5B-Instruct-GGUF"
MFILE["qwen2.5-1.5b"]="Qwen2.5-1.5B-Instruct-Q4_K_M.gguf"
MLABEL["qwen2.5-1.5b"]="Qwen2.5 1.5B Instruct (GGUF Q4_K_M)"

if [ -z "${MTYPE[$MODEL_NAME]+_}" ]; then
    die "Modelo desconocido: '${MODEL_NAME}'
  Modelos válidos:
    • qwen2.5-uncensored  — Qwen2.5 0.5B Uncensored (0.5B, transformers)
    • qwen3.5-0.8b        — Qwen3.5 0.8B GGUF (0.8B, CPU rápido)
    • llama3.2-1b         — Llama 3.2 1B Instruct GGUF (1B)
    • smollm2-1.7b        — SmolLM2 1.7B Instruct GGUF (1.7B, muy eficiente)
    • qwen2.5-1.5b        — Qwen2.5 1.5B Instruct GGUF (1.5B)"
fi

M_TYPE="${MTYPE[$MODEL_NAME]}"
M_REPO="${MREPO[$MODEL_NAME]}"
M_FILE="${MFILE[$MODEL_NAME]}"
M_LABEL="${MLABEL[$MODEL_NAME]}"

ok "${M_LABEL}"
echo -e "  ${DIM}Tipo     ${NC}  ${MAGENTA}${M_TYPE^^}${NC}"
echo -e "  ${DIM}Repo     ${NC}  ${DIM}${M_REPO}${NC}"

# ─────────────────────────────────────────────────────────────────────────────
# PASO 2: context.txt
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[2/4] Personalidad de la IA (context.txt)${NC}"
sep

if [ ! -f "$CONTEXT_FILE" ] || [ ! -s "$CONTEXT_FILE" ]; then
    warn "context.txt no encontrado — creando por defecto"
    cat > "$CONTEXT_FILE" << 'CTXEOF'
Eres un asistente de IA útil, honesto y amigable.
Responde siempre en el idioma en que te habla el usuario.
Sé conciso, claro y preciso en tus respuestas.
No reveles que eres un modelo de lenguaje a menos que se te pregunte directamente.
CTXEOF
    warn "Edita context.txt en el gestor de archivos de Pterodactyl para personalizar la IA."
else
    ok "context.txt cargado — $(wc -c < "$CONTEXT_FILE") bytes / $(wc -l < "$CONTEXT_FILE") líneas"
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 3: Descargar modelo (con retry infinito — no crashea el servidor)
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] Modelo en caché${NC}"
sep

mkdir -p "$MODEL_CACHE"

# FIX: detectar comando HuggingFace disponible (hf en versiones nuevas, huggingface-cli en antiguas)
if command -v hf &>/dev/null; then
    HF_CMD="hf"
elif command -v huggingface-cli &>/dev/null; then
    HF_CMD="huggingface-cli"
else
    die "Comando HuggingFace no encontrado (ni 'hf' ni 'huggingface-cli'). Verifica el yolk."
fi
ok "Comando HuggingFace: ${HF_CMD}"

if [ -n "$HF_TOKEN" ]; then
    info "Autenticando en HuggingFace..."
    if [ "$HF_CMD" = "hf" ]; then
        hf auth login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 \
            && ok "HuggingFace autenticado" \
            || warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    else
        huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 \
            && ok "HuggingFace autenticado" \
            || warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    fi
fi

_DL_ATTEMPT=0
_DL_OK=0

if [ "$M_TYPE" = "gguf" ]; then
    GGUF_PATH="$MODEL_CACHE/$M_FILE"

    # FIX: validar caché con tamaño mínimo (50MB) — descarga parcial no cuenta como válida
    _CACHED_SIZE=$(stat -c%s "$GGUF_PATH" 2>/dev/null || echo 0)
    if [ -f "$GGUF_PATH" ] && [ "$_CACHED_SIZE" -gt 52428800 ]; then
        ok "En caché: ${M_FILE} ($(du -sh "$GGUF_PATH" | cut -f1))"
        _DL_OK=1
    else
        if [ -f "$GGUF_PATH" ]; then
            warn "Archivo incompleto detectado ($(du -sh "$GGUF_PATH" | cut -f1)) — eliminando y re-descargando"
            rm -f "$GGUF_PATH"
        fi

        # FIX: retry infinito con backoff exponencial — el servidor nunca crashea por descarga fallida
        while [ "$_DL_OK" -eq 0 ]; do
            _DL_ATTEMPT=$((_DL_ATTEMPT + 1))
            info "Descargando ${M_REPO} / ${M_FILE} (intento ${_DL_ATTEMPT})..."
            info "Esto puede tardar varios minutos la primera vez..."

            if [ -n "$HF_TOKEN" ]; then
                "$HF_CMD" download "$M_REPO" "$M_FILE" \
                    --local-dir "$MODEL_CACHE" \
                    --local-dir-use-symlinks False \
                    --token "$HF_TOKEN" 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            else
                "$HF_CMD" download "$M_REPO" "$M_FILE" \
                    --local-dir "$MODEL_CACHE" \
                    --local-dir-use-symlinks False 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            fi

            if [ "$_DL_OK" -eq 0 ]; then
                _WAIT=$(( _DL_ATTEMPT < 6 ? _DL_ATTEMPT * 60 : 300 ))
                warn "Intento ${_DL_ATTEMPT} fallido. Reintentando en ${_WAIT}s..."
                warn "Verifica: acceso a internet, quota de HuggingFace, nombre del modelo."
                sleep "$_WAIT"
            fi
        done

        ok "Descargado: $(du -sh "$GGUF_PATH" | cut -f1)"
    fi

elif [ "$M_TYPE" = "transformers" ]; then
    TF_DIR="$MODEL_CACHE/$MODEL_NAME"

    # FIX: validar que config.json existe — indica modelo completo (no solo archivos parciales)
    if [ -f "${TF_DIR}/config.json" ]; then
        ok "En caché: ${TF_DIR} ($(du -sh "$TF_DIR" | cut -f1))"
        _DL_OK=1
    else
        if [ -d "$TF_DIR" ]; then
            warn "Directorio incompleto detectado — re-descargando"
        fi

        while [ "$_DL_OK" -eq 0 ]; do
            _DL_ATTEMPT=$((_DL_ATTEMPT + 1))
            info "Descargando modelo completo: ${M_REPO} (intento ${_DL_ATTEMPT})..."
            info "Esto puede tardar varios minutos la primera vez..."

            if [ -n "$HF_TOKEN" ]; then
                "$HF_CMD" download "$M_REPO" \
                    --local-dir "$TF_DIR" \
                    --local-dir-use-symlinks False \
                    --token "$HF_TOKEN" 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            else
                "$HF_CMD" download "$M_REPO" \
                    --local-dir "$TF_DIR" \
                    --local-dir-use-symlinks False 2>&1 | grep -v "^Warning:\|^Hint:" && _DL_OK=1 || true
            fi

            if [ "$_DL_OK" -eq 0 ]; then
                _WAIT=$(( _DL_ATTEMPT < 6 ? _DL_ATTEMPT * 60 : 300 ))
                warn "Intento ${_DL_ATTEMPT} fallido. Reintentando en ${_WAIT}s..."
                warn "Verifica: acceso a internet, quota de HuggingFace, nombre del modelo."
                sleep "$_WAIT"
            fi
        done

        ok "Descargado: $(du -sh "$TF_DIR" | cut -f1)"
    fi
fi

# ─────────────────────────────────────────────────────────────────────────────
# PASO 4: Iniciar API
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[4/4] Iniciando Boxi-AI${NC}"
sep
echo ""
echo -e "  ${DIM}Modelo   ${NC}  ${GREEN}${BOLD}${M_LABEL}${NC}"
echo -e "  ${DIM}Tipo     ${NC}  ${GREEN}${BOLD}${M_TYPE^^}${NC}"
echo -e "  ${DIM}Puerto   ${NC}  ${GREEN}${BOLD}${API_PORT}${NC}"
echo -e "  ${DIM}Threads  ${NC}  ${GREEN}${BOLD}${N_THREADS} vCPU${NC}"
echo -e "  ${DIM}Contexto ${NC}  ${GREEN}${BOLD}${N_CTX} tokens${NC}"
echo ""
sep
echo ""

export MODEL_NAME MODEL_CACHE API_TOKEN API_PORT MAX_TOKENS N_THREADS N_CTX CONTEXT_FILE

cleanup() {
    echo ""
    echo -e "${YELLOW}  ⚠ Señal recibida — deteniendo Boxi-AI...${NC}"
    exit 0
}
trap cleanup SIGTERM SIGINT

# -u → stdout sin buffer (logs en tiempo real en la consola de Pterodactyl)
exec python3 -u "$APP_PY"
