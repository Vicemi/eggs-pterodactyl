#!/bin/bash
# ===========================================================
# Boxi-AI — Script de inicio para Pterodactyl
# Yolk      : ghcr.io/vicemi/yolks:ai-api_latest
# Python    : 3.11 | llama-cpp-python (CPU) | FastAPI
# Repositorio: https://github.com/Vicemi/eggs-pterodactyl
# ===========================================================

set -euo pipefail

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

MODEL_NAME="${MODEL_NAME:-qwen2.5-uncensored}"
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
# PASO 3: Descargar modelo
# ─────────────────────────────────────────────────────────────────────────────
echo ""
echo -e "${BOLD}[3/4] Modelo en caché${NC}"
sep

mkdir -p "$MODEL_CACHE"

if [ -n "$HF_TOKEN" ]; then
    info "Autenticando en HuggingFace..."
    huggingface-cli login --token "$HF_TOKEN" --add-to-git-credential >/dev/null 2>&1 \
        && ok "HuggingFace autenticado" \
        || warn "No se pudo autenticar en HuggingFace (continuando sin token)"
    HF_EXTRA="--token $HF_TOKEN"
else
    HF_EXTRA=""
fi

if [ "$M_TYPE" = "gguf" ]; then
    GGUF_PATH="$MODEL_CACHE/$M_FILE"
    if [ -f "$GGUF_PATH" ] && [ -s "$GGUF_PATH" ]; then
        ok "En caché: ${M_FILE} ($(du -sh "$GGUF_PATH" | cut -f1))"
    else
        info "Descargando ${M_REPO} / ${M_FILE}"
        info "Esto puede tardar varios minutos..."
        huggingface-cli download "$M_REPO" "$M_FILE" \
            --local-dir "$MODEL_CACHE" \
            --local-dir-use-symlinks False \
            $HF_EXTRA \
            || die "Fallo al descargar '${M_REPO}/${M_FILE}'"
        [ -f "$GGUF_PATH" ] || die "Archivo no encontrado tras descarga: ${GGUF_PATH}"
        ok "Descargado: $(du -sh "$GGUF_PATH" | cut -f1)"
    fi

elif [ "$M_TYPE" = "transformers" ]; then
    TF_DIR="$MODEL_CACHE/$MODEL_NAME"
    if [ -d "$TF_DIR" ] && [ -n "$(ls -A "$TF_DIR" 2>/dev/null)" ]; then
        ok "En caché: ${TF_DIR} ($(du -sh "$TF_DIR" | cut -f1))"
    else
        info "Descargando modelo completo: ${M_REPO}"
        info "Esto puede tardar varios minutos..."
        huggingface-cli download "$M_REPO" \
            --local-dir "$TF_DIR" \
            --local-dir-use-symlinks False \
            $HF_EXTRA \
            || die "Fallo al descargar '${M_REPO}'"
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