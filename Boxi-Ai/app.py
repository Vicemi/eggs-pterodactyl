"""
AI API — Pterodactyl Egg (Vicemi/planka-egg)
────────────────────────────────────────────
OpenAI-compatible REST API • CPU-only • Bearer token auth
GGUF models via llama-cpp-python | HuggingFace Transformers models

Endpoints:
  GET  /health                    → Estado del servidor
  GET  /models                    → Modelos disponibles / activo
  POST /v1/chat/completions       → API compatible con OpenAI
  POST /chat                      → Endpoint simplificado con historial

Configuración:
  MODEL_NAME   → Modelo activo (ver MODEL_REGISTRY)
  MODEL_CACHE  → Ruta local donde están los pesos
  API_TOKEN    → Bearer token de autenticación
  SERVER_PORT  → Puerto de escucha
  MAX_TOKENS   → Tokens máximos de respuesta
  N_THREADS    → Hilos CPU para inferencia
  N_CTX        → Ventana de contexto (GGUF)
  CONTEXT_FILE → Archivo con el system prompt (context.txt)
"""

import os, json, time, logging, uuid, asyncio
from pathlib import Path
from contextlib import asynccontextmanager
from concurrent.futures import ThreadPoolExecutor
from typing import Optional, List, Dict, Any

from fastapi import FastAPI, HTTPException, Security
from fastapi.security import HTTPAuthorizationCredentials, HTTPBearer
from pydantic import BaseModel

# ── Config desde entorno ───────────────────────────────────────────────────────
MODEL_NAME   = os.environ.get("MODEL_NAME",   "qwen2.5-uncensored")
MODEL_CACHE  = os.environ.get("MODEL_CACHE",  "/home/container/model_cache")
API_TOKEN    = os.environ.get("API_TOKEN",    "changeme")
API_PORT     = int(os.environ.get("API_PORT", os.environ.get("SERVER_PORT", "5832")))
MAX_TOKENS   = int(os.environ.get("MAX_TOKENS",  "512"))
N_THREADS    = int(os.environ.get("N_THREADS",   "2"))
N_CTX        = int(os.environ.get("N_CTX",       "4096"))
CONTEXT_FILE = Path(os.environ.get("CONTEXT_FILE", "/home/container/context.txt"))

# ── Registro de modelos ────────────────────────────────────────────────────────
# type "gguf"         → llama-cpp-python (mejor rendimiento en CPU)
# type "transformers" → HuggingFace AutoModelForCausalLM (más flexible)
MODEL_REGISTRY: Dict[str, Dict] = {
    # ── Especificados por el usuario ─────────────────────────────────────────
    "qwen2.5-uncensored": {
        "type":   "transformers",
        "repo":   "thirdeyeai/Qwen2.5-0.5B-Instruct-uncensored",
        "file":   None,
        "label":  "Qwen2.5 0.5B Uncensored (Transformers)",
        "params": "0.5B",
        "notes":  "Sin censura, muy ligero, ideal para baja RAM",
    },
    "qwen3.5-0.8b": {
        "type":   "gguf",
        "repo":   "unsloth/Qwen3.5-0.8B-GGUF",
        "file":   "Qwen3.5-0.8B-Q4_K_M.gguf",
        "label":  "Qwen3.5 0.8B (GGUF Q4_K_M)",
        "params": "0.8B",
        "notes":  "Qwen3.5 cuantizado Q4 — buen balance calidad/velocidad",
    },
    # ── 3 modelos adicionales pequeños y variados ─────────────────────────────
    "llama3.2-1b": {
        "type":   "gguf",
        "repo":   "bartowski/Llama-3.2-1B-Instruct-GGUF",
        "file":   "Llama-3.2-1B-Instruct-Q4_K_M.gguf",
        "label":  "Llama 3.2 1B Instruct (GGUF Q4_K_M)",
        "params": "1B",
        "notes":  "Meta Llama 3.2 — robusto y general purpose en 1B parámetros",
    },
    "smollm2-1.7b": {
        "type":   "gguf",
        "repo":   "bartowski/SmolLM2-1.7B-Instruct-GGUF",
        "file":   "SmolLM2-1.7B-Instruct-Q4_K_M.gguf",
        "label":  "SmolLM2 1.7B Instruct (GGUF Q4_K_M)",
        "params": "1.7B",
        "notes":  "HuggingFace SmolLM2 — extremadamente eficiente en CPU para su tamaño",
    },
    "qwen2.5-1.5b": {
        "type":   "gguf",
        "repo":   "bartowski/Qwen2.5-1.5B-Instruct-GGUF",
        "file":   "Qwen2.5-1.5B-Instruct-Q4_K_M.gguf",
        "label":  "Qwen2.5 1.5B Instruct (GGUF Q4_K_M)",
        "params": "1.5B",
        "notes":  "Qwen2.5 1.5B — mejor razonamiento que 0.5B, aún muy ligero",
    },
    "gemma-4-e2b": {
        "type":   "gguf",
        "repo":   "bartowski/google_gemma-4-E2B-it-GGUF",
        "file":   "google_gemma-4-E2B-it-IQ4_XS.gguf",
        "label":  "Gemma 4 E2B Instruct (GGUF IQ4_XS)",
        "params": "2B",
        "notes":  "Google Gemma 4 — 2B efectivos (5.1B total), 128K contexto, razonamiento",
    },
    "deepseek-r1-1.5b": {
        "type":   "gguf",
        "repo":   "bartowski/DeepSeek-R1-Distill-Qwen-1.5B-GGUF",
        "file":   "DeepSeek-R1-Distill-Qwen-1.5B-Q4_K_M.gguf",
        "label":  "DeepSeek R1 Distill 1.5B (GGUF Q4_K_M)",
        "params": "1.5B",
        "notes":  "DeepSeek R1 destilado en 1.5B — razonamiento Chain-of-Thought en CPU",
    },
}

# ── Logging ────────────────────────────────────────────────────────────────────
logging.basicConfig(
    level=logging.INFO,
    format="%(asctime)s [%(levelname)s] %(message)s",
    datefmt="%H:%M:%S",
)
log = logging.getLogger(__name__)

_state: Dict[str, Any] = {}
security = HTTPBearer()


# ── Utilidades ─────────────────────────────────────────────────────────────────
def load_system_prompt() -> str:
    """Lee context.txt. Si no existe o está vacío, devuelve un prompt por defecto."""
    if CONTEXT_FILE.exists():
        content = CONTEXT_FILE.read_text(encoding="utf-8").strip()
        if content:
            return content
    return "You are a helpful, harmless and honest AI assistant. Always respond in the user's language."


def _verify(creds: HTTPAuthorizationCredentials = Security(security)) -> str:
    if creds.credentials != API_TOKEN:
        raise HTTPException(status_code=401, detail="Token de autenticación inválido")
    return creds.credentials


# ── Carga de modelos ───────────────────────────────────────────────────────────
def _load_gguf(entry: Dict) -> Any:
    from llama_cpp import Llama
    model_path = str(Path(MODEL_CACHE) / entry["file"])
    if not Path(model_path).exists():
        raise FileNotFoundError(
            f"Modelo GGUF no encontrado: {model_path}\n"
            f"Asegúrate de que start.sh descargó el modelo antes de iniciar."
        )
    log.info(f"Cargando GGUF desde: {model_path}")
    llm = Llama(
        model_path=model_path,
        n_ctx=N_CTX,
        n_threads=N_THREADS,
        n_gpu_layers=0,   # CPU-only
        verbose=False,
    )
    log.info(f"✓ GGUF listo: {entry['label']}")
    return llm


def _load_transformers(entry: Dict) -> tuple:
    import torch
    from transformers import AutoTokenizer, AutoModelForCausalLM

    # Buscar primero en caché local, luego en HuggingFace Hub
    local_dir = Path(MODEL_CACHE) / MODEL_NAME
    source = str(local_dir) if local_dir.exists() and any(local_dir.iterdir()) else entry["repo"]

    log.info(f"Cargando Transformers desde: {source}")
    tokenizer = AutoTokenizer.from_pretrained(source, trust_remote_code=True)
    model = AutoModelForCausalLM.from_pretrained(
        source,
        torch_dtype=torch.float32,   # float32 para CPU (no bfloat16)
        device_map="cpu",
        trust_remote_code=True,
        low_cpu_mem_usage=True,
    )
    model.eval()
    log.info(f"✓ Transformers listo: {entry['label']}")
    return tokenizer, model


# ── Inferencia ─────────────────────────────────────────────────────────────────
def _infer_gguf(messages: List[Dict], max_tokens: int, temperature: float) -> str:
    llm = _state["model"]
    result = llm.create_chat_completion(
        messages=messages,
        max_tokens=max_tokens,
        temperature=max(temperature, 1e-7),   # llama-cpp no acepta temp=0.0 exacto
        stop=["<|im_end|>", "</s>", "<|end|>", "<|eot_id|>"],
    )
    return result["choices"][0]["message"]["content"].strip()


def _infer_transformers(messages: List[Dict], max_tokens: int, temperature: float) -> str:
    import torch
    tokenizer, model = _state["model"]

    # Intentar chat template nativo del modelo
    try:
        text = tokenizer.apply_chat_template(
            messages,
            tokenize=False,
            add_generation_prompt=True,
        )
    except Exception:
        # Fallback genérico si el modelo no tiene chat template
        parts = []
        for m in messages:
            if m["role"] == "system":
                parts.append(f"<|system|>\n{m['content']}\n<|end|>")
            elif m["role"] == "user":
                parts.append(f"<|user|>\n{m['content']}\n<|end|>\n<|assistant|>")
            else:
                parts.append(f"{m['content']}\n<|end|>")
        text = "\n".join(parts)

    inputs = tokenizer(text, return_tensors="pt").to("cpu")
    input_len = inputs["input_ids"].shape[1]

    with torch.no_grad():
        outputs = model.generate(
            **inputs,
            max_new_tokens=max_tokens,
            temperature=temperature if temperature > 0 else 1.0,
            do_sample=temperature > 0,
            pad_token_id=tokenizer.eos_token_id,
            eos_token_id=tokenizer.eos_token_id,
        )

    generated = outputs[0][input_len:]
    return tokenizer.decode(generated, skip_special_tokens=True).strip()


def _run_inference(messages: List[Dict], max_tokens: int, temperature: float) -> str:
    model_type = _state["model_type"]
    if model_type == "gguf":
        return _infer_gguf(messages, max_tokens, temperature)
    else:
        return _infer_transformers(messages, max_tokens, temperature)


# ── Modelos Pydantic ───────────────────────────────────────────────────────────
class Message(BaseModel):
    role: str
    content: str


class ChatCompletionRequest(BaseModel):
    model: Optional[str] = None
    messages: List[Message]
    max_tokens: Optional[int] = None
    temperature: Optional[float] = 0.7
    stream: Optional[bool] = False


class SimpleChatRequest(BaseModel):
    message: str
    history: Optional[List[Message]] = []
    max_tokens: Optional[int] = None
    temperature: Optional[float] = 0.7


# ── Lifecycle ──────────────────────────────────────────────────────────────────
@asynccontextmanager
async def lifespan(app: FastAPI):
    entry = MODEL_REGISTRY.get(MODEL_NAME)
    if not entry:
        valid = ", ".join(MODEL_REGISTRY.keys())
        raise RuntimeError(
            f"Modelo desconocido: '{MODEL_NAME}'. Válidos: {valid}"
        )

    _state["model_info"]  = entry
    _state["model_type"]  = entry["type"]
    _state["executor"]    = ThreadPoolExecutor(max_workers=1)
    _state["started_at"]  = time.time()

    log.info("=" * 50)
    log.info(f"  AI API — Pterodactyl Egg (Vicemi)")
    log.info(f"  Modelo  : {entry['label']}")
    log.info(f"  Tipo    : {entry['type'].upper()}")
    log.info(f"  Puerto  : {API_PORT}")
    log.info("=" * 50)

    loop = asyncio.get_event_loop()
    loader = _load_gguf if entry["type"] == "gguf" else _load_transformers
    _state["model"] = await loop.run_in_executor(
        _state["executor"], lambda: loader(entry)
    )

    log.info("✓ Modelo listo — API lista para recibir peticiones")
    yield

    log.info("Apagando servidor...")
    _state["executor"].shutdown(wait=False)


app = FastAPI(
    title="AI API",
    description="API de IA genérica para Pterodactyl — compatible con OpenAI",
    version="1.0.0",
    lifespan=lifespan,
)


# ── Endpoints ──────────────────────────────────────────────────────────────────
@app.get("/health")
async def health():
    """Estado del servidor y modelo activo."""
    if "model" not in _state:
        raise HTTPException(status_code=503, detail="Modelo no cargado")
    return {
        "status": "ok",
        "model_name": MODEL_NAME,
        "model_label": _state["model_info"]["label"],
        "model_type": _state["model_type"],
        "uptime_seconds": round(time.time() - _state["started_at"]),
        "system_prompt_source": str(CONTEXT_FILE),
    }


@app.get("/models")
async def list_models():
    """Lista todos los modelos disponibles y cuál está activo."""
    return {
        "object": "list",
        "active": MODEL_NAME,
        "data": [
            {
                "id": k,
                "object": "model",
                "label": v["label"],
                "params": v["params"],
                "type": v["type"],
                "notes": v["notes"],
                "active": k == MODEL_NAME,
            }
            for k, v in MODEL_REGISTRY.items()
        ],
    }


@app.post("/v1/chat/completions")
async def chat_completions(
    req: ChatCompletionRequest,
    _: str = Security(_verify),
):
    """
    Endpoint compatible con OpenAI Chat Completions API.
    El system prompt se carga automáticamente desde context.txt.
    """
    if "model" not in _state:
        raise HTTPException(status_code=503, detail="Modelo no cargado aún")

    system_prompt = load_system_prompt()
    messages = [{"role": "system", "content": system_prompt}]
    messages += [{"role": m.role, "content": m.content} for m in req.messages]

    max_tok = req.max_tokens or MAX_TOKENS
    temp    = req.temperature if req.temperature is not None else 0.7

    loop = asyncio.get_event_loop()
    try:
        text = await loop.run_in_executor(
            _state["executor"],
            lambda: _run_inference(messages, max_tok, temp),
        )
    except Exception as e:
        log.error(f"Error de inferencia: {e}")
        raise HTTPException(status_code=500, detail=f"Error de inferencia: {str(e)}")

    return {
        "id": f"chatcmpl-{uuid.uuid4().hex[:12]}",
        "object": "chat.completion",
        "created": int(time.time()),
        "model": MODEL_NAME,
        "choices": [{
            "index": 0,
            "message": {"role": "assistant", "content": text},
            "finish_reason": "stop",
        }],
        "usage": {
            "prompt_tokens": -1,
            "completion_tokens": -1,
            "total_tokens": -1,
        },
    }


@app.post("/chat")
async def simple_chat(
    req: SimpleChatRequest,
    _: str = Security(_verify),
):
    """
    Endpoint simplificado con soporte de historial.
    Ideal para integraciones propias sin compatibilidad OpenAI estricta.
    """
    if "model" not in _state:
        raise HTTPException(status_code=503, detail="Modelo no cargado aún")

    system_prompt = load_system_prompt()
    messages = [{"role": "system", "content": system_prompt}]
    if req.history:
        messages += [{"role": m.role, "content": m.content} for m in req.history]
    messages.append({"role": "user", "content": req.message})

    max_tok = req.max_tokens or MAX_TOKENS
    temp    = req.temperature if req.temperature is not None else 0.7

    loop = asyncio.get_event_loop()
    try:
        text = await loop.run_in_executor(
            _state["executor"],
            lambda: _run_inference(messages, max_tok, temp),
        )
    except Exception as e:
        log.error(f"Error en /chat: {e}")
        raise HTTPException(status_code=500, detail=f"Error de inferencia: {str(e)}")

    return {
        "response": text,
        "model": MODEL_NAME,
        "model_label": _state["model_info"]["label"],
    }


if __name__ == "__main__":
    import uvicorn
    uvicorn.run(app, host="0.0.0.0", port=API_PORT, workers=1, log_level="info")
