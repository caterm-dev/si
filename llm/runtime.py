"""Local-only MLX execution. Imports stay lazy so data tools need only Python."""

import importlib.metadata
import json
import os
import platform
import time
from pathlib import Path

from protocol import ROOT, finish_candidates, parse_response


def offline_environment():
    # Set before importing HF/MLX; do not inherit an online Hub/ModelScope mode.
    os.environ.update({
        "HF_HOME": str(ROOT / ".cache/huggingface"),
        "HF_HUB_OFFLINE": "1", "TRANSFORMERS_OFFLINE": "1",
        "HF_DATASETS_OFFLINE": "1", "HF_HUB_DISABLE_TELEMETRY": "1",
        "TOKENIZERS_PARALLELISM": "false", "MLXLM_USE_MODELSCOPE": "False",
    })


def check_platform():
    if platform.system() != "Darwin" or platform.machine() != "arm64":
        raise ValueError("Use native Apple Silicon macOS Python for MLX execution")


def model_directory(value):
    path = Path(value).expanduser().resolve()
    if not path.is_dir() or not (path / "config.json").is_file():
        raise ValueError("--model must be an existing local snapshot with config.json; no downloads are performed")
    config = json.loads((path / "config.json").read_text())
    if config.get("model_type") not in ("qwen3_5", "qwen3_5_text"):
        raise ValueError("This experiment expects a Qwen3.5 Safetensors snapshot, not GGUF")
    if not list(path.glob("*.safetensors")) or not (path / "tokenizer_config.json").is_file():
        raise ValueError("Local snapshot is missing Safetensors weights or tokenizer configuration")
    return path


class NonThinkingTokenizer:
    """Use the same non-thinking template for MLX training and inference."""

    def __init__(self, tokenizer):
        self.tokenizer = tokenizer

    def apply_chat_template(self, messages, **kwargs):
        return self.tokenizer.apply_chat_template(messages, **{**kwargs, "enable_thinking": False})


class Generator:
    def __init__(self, model_path, adapter_path=None, max_tokens=384):
        check_platform()
        offline_environment()
        from mlx_lm import load
        from mlx_lm.sample_utils import make_sampler

        model_path = model_directory(model_path)
        if adapter_path is not None:
            adapter_path = Path(adapter_path).expanduser().resolve()
            if not all((adapter_path / name).is_file() for name in ("adapter_config.json", "adapters.safetensors")):
                raise ValueError("Adapter directory must contain adapter_config.json and adapters.safetensors")
        started = time.perf_counter()
        self.model, self.tokenizer = load(
            str(model_path), adapter_path=str(adapter_path) if adapter_path else None,
            tokenizer_config={"trust_remote_code": False, "local_files_only": True},
            trust_remote_code=False,
        )
        self.load_ms = (time.perf_counter() - started) * 1000
        self.sampler = make_sampler(temp=0.0)
        self.max_tokens = max_tokens

    def generate(self, request):
        started = time.perf_counter()
        if not request.needs_model:
            return {"candidates": finish_candidates([], request), "status": "bypassed", "timing": {
                "total_ms": (time.perf_counter() - started) * 1000,
                "first_token_ms": None, "generation_tokens": 0,
            }}
        from mlx_lm import stream_generate

        prompt = NonThinkingTokenizer(self.tokenizer).apply_chat_template(
            request.messages(), tokenize=False, add_generation_prompt=True,
        )
        parts = []
        first_token_ms = None
        last = None
        for response in stream_generate(
            self.model, self.tokenizer, prompt=prompt,
            max_tokens=self.max_tokens, sampler=self.sampler,
        ):
            if first_token_ms is None:
                first_token_ms = (time.perf_counter() - started) * 1000
            parts.append(response.text)
            last = response
        status = "ok"
        try:
            if last is not None and last.finish_reason == "length":
                raise ValueError("truncated generation")
            rows = parse_response("".join(parts), request)
        except (ValueError, TypeError, UnicodeError):
            # Do not log the untrusted response or return half a candidate list.
            rows, status = [], "invalid_response"
        return {"candidates": finish_candidates(rows, request), "status": status, "timing": {
            "total_ms": (time.perf_counter() - started) * 1000,
            "first_token_ms": first_token_ms,
            "generation_tokens": last.generation_tokens if last else 0,
        }}


def doctor():
    check_platform()
    offline_environment()
    import mlx.core as mx
    from mlx_lm.models import qwen3_5  # Check installed architecture support without weights.

    if not mx.metal.is_available():
        raise ValueError("MLX Metal device is unavailable in this session")
    mx.eval(mx.array([1, 2]) + 1)
    return {"platform": "Apple Silicon macOS", "metal": True, "versions": {
        name: importlib.metadata.version(name) for name in ("mlx", "mlx-lm", "transformers")
    }, "model_downloaded": False}
