# Local models

Download the complete `Qwen/Qwen3.5-0.8B` Hugging Face snapshot yourself into
`llm/models/Qwen3.5-0.8B/`, including Safetensors weights, configuration,
tokenizer, chat template, license and notices. Alternatively use another local
directory with `--model /absolute/path`. Model IDs and GGUF files are not
accepted by these offline MLX scripts.

To create a local four-bit MLX copy after setup:

```sh
llm/.venv/bin/python llm/experiment.py convert \
  --model llm/models/Qwen3.5-0.8B \
  --output llm/models/Qwen3.5-0.8B-4bit
```

An existing MLX quantized snapshot can be used directly. The conversion command
requires a new destination and never downloads or uploads weights. All files
here except this README are ignored by Git. Delete unwanted model directories
manually; no model cleanup runs automatically.
