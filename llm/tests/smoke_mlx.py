"""Optional Metal smoke: random tiny Qwen3.5, no downloaded model or quality claim."""

import json
from pathlib import Path
import subprocess
import sys
import tempfile
from types import SimpleNamespace

sys.path.insert(0, str(Path(__file__).resolve().parents[1]))
from protocol import ROOT, SYSTEM_PROMPT
from runtime import offline_environment


def main():
    offline_environment()
    import mlx.core as mx
    from mlx.utils import tree_flatten
    from mlx_lm.models.qwen3_5 import Model, ModelArgs
    from tokenizers import Tokenizer, models, pre_tokenizers, trainers
    from transformers import Qwen2Tokenizer

    config = {
        "model_type": "qwen3_5", "text_config": {
            "model_type": "qwen3_5_text", "hidden_size": 64, "intermediate_size": 128,
            "num_hidden_layers": 4, "num_attention_heads": 4, "num_key_value_heads": 1,
            "head_dim": 16, "vocab_size": 1024, "tie_word_embeddings": True,
            "linear_num_value_heads": 1, "linear_num_key_heads": 1,
            "linear_key_head_dim": 128, "linear_value_head_dim": 128,
            "full_attention_interval": 4, "eos_token_id": 1,
            "rope_parameters": {"rope_theta": 10000, "partial_rotary_factor": 0.5,
                                "mrope_section": [1, 1, 2], "rope_type": "default"},
        },
    }
    mx.random.seed(7)
    with tempfile.TemporaryDirectory(prefix="si-llm-smoke-") as temporary:
        root = Path(temporary)
        model_path = root / "tiny"
        model_path.mkdir()
        model = Model(ModelArgs.from_dict(config))
        mx.save_safetensors(str(model_path / "model.safetensors"), dict(tree_flatten(model.parameters())))
        (model_path / "config.json").write_text(json.dumps(config))
        backend = Tokenizer(models.BPE())
        backend.pre_tokenizer = pre_tokenizers.ByteLevel(add_prefix_space=False)
        backend.train_from_iterator(
            [SYSTEM_PROMPT, (ROOT / "data/seeds.jsonl").read_text()],
            trainers.BpeTrainer(vocab_size=1024, initial_alphabet=pre_tokenizers.ByteLevel.alphabet(), special_tokens=["[UNK]", "[EOS]", "[PAD]", "[ASSISTANT]"]),
        )
        merges = [tuple(pair) for pair in json.loads(backend.to_str())["model"]["merges"]]
        tokenizer = Qwen2Tokenizer(vocab=backend.get_vocab(), merges=merges, unk_token="[UNK]", eos_token="[EOS]", pad_token="[PAD]", additional_special_tokens=["[ASSISTANT]"])
        tokenizer.chat_template = "{% for m in messages %}{% if m['role'] == 'assistant' %}{{ '[ASSISTANT]' }}{% else %}{{ m['role'] + ': ' }}{% endif %}{{ m['content'] + '\\n' }}{% endfor %}{% if add_generation_prompt %}{{ '[ASSISTANT]' }}{% endif %}"
        tokenizer.save_pretrained(model_path)
        command = [sys.executable, str(ROOT / "experiment.py")]
        subprocess.run(command + ["convert", "--model", str(model_path), "--output", str(root / "quantized")], check=True)
        from mlx_lm.utils import load_tokenizer
        loaded = load_tokenizer(root / "quantized")
        assert loaded.encode("hello world"), "Synthetic tokenizer must survive local conversion"
        from experiment import train
        from prepare import export
        import protocol
        import yaml

        # Short synthetic prompt/data keep this an API smoke, not a model benchmark.
        protocol.SYSTEM_PROMPT = "Generate ordered candidates as JSON."
        seeds = []
        for split, spelling in (("train", "hello"), ("valid", "world"), ("test", "test")):
            seeds.append({"id": split, "group": split, "split": split, "category": "preserve",
                          "request": {"input": spelling, "languages": ["en"]}, "variants": [],
                          "candidates": [{"text": spelling, "language": "en"}]})
        source = root / "seeds.jsonl"
        source.write_text("".join(json.dumps(seed) + "\n" for seed in seeds))
        export(source, root / "data")
        settings = yaml.safe_load((ROOT / "configs/lora.yaml").read_text())
        settings.update(grad_accumulation_steps=1, val_batches=1)
        config_path = root / "lora.yaml"
        config_path.write_text(yaml.safe_dump(settings))
        train(SimpleNamespace(
            model=str(root / "quantized"), output=root / "adapter", iters=1,
            source=source, data=root / "data", config=config_path, dry_run=False,
        ))
        assert (root / "adapter/adapters.safetensors").is_file()
        adapter = mx.load(str(root / "adapter/adapters.safetensors"))
        # LoRA B matrices start at zero; a nonzero one establishes an actual update.
        assert any(bool(mx.any(value != 0).item()) for name, value in adapter.items() if name.endswith("lora_b"))
        request = json.dumps({"input": "nihao", "languages": ["en", "zh-Hans"]})
        response = subprocess.run(command + ["infer", "--model", str(root / "quantized"), "--adapter", str(root / "adapter"), "--max-tokens", "8"], input=request, text=True, capture_output=True, check=True)
        result = json.loads(response.stdout)
        assert result["candidates"][-1] == {"text": "nihao", "language": "verbatim"}
        report_path = root / "report.json"
        subprocess.run(command + ["evaluate", "--model", str(root / "quantized"),
                                 "--adapter", str(root / "adapter"), "--max-tokens", "8",
                                 "--cases", str(root / "data/test.cases.jsonl"),
                                 "--output", str(report_path)], check=True, capture_output=True)
        report = json.loads(report_path.read_text())
        assert report["summary"]["cases"] == 1
        assert report["summary"]["literal_failures"] == 0
    print("Tiny random-model conversion, QLoRA update, adapter reload, bounded generation and aggregate evaluation passed. This does not validate Qwen3.5-0.8B quality or memory use.")


if __name__ == "__main__":
    main()
