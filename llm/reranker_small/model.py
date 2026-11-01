"""Tied-embedding, pre-normalized causal character LM; no Pinyin generation."""

import argparse
import json
import math

import torch
from torch import nn
from torch.nn import functional as F

from .settings import ROOT, load_config
from .tokenizer import PAD


class Block(nn.Module):
    def __init__(self, config):
        super().__init__()
        width = config["width"]
        self.heads = config["heads"]
        self.norm1 = nn.LayerNorm(width)
        self.qkv = nn.Linear(width, width * 3)
        self.proj = nn.Linear(width, width)
        self.norm2 = nn.LayerNorm(width)
        self.fc = nn.Linear(width, config["feedforward"])
        self.out = nn.Linear(config["feedforward"], width)
        self.dropout = nn.Dropout(config["dropout"])

    def forward(self, x):
        batch, length, width = x.shape
        q, k, v = self.qkv(self.norm1(x)).chunk(3, dim=-1)
        q, k, v = (part.reshape(batch, length, self.heads, width // self.heads).transpose(1, 2)
                   for part in (q, k, v))
        # Right padding is always after real tokens; causal attention prevents it
        # from affecting any supervised position. Padding-query losses are ignored.
        y = F.scaled_dot_product_attention(q, k, v, is_causal=True,
                                          dropout_p=self.dropout.p if self.training else 0.0)
        x = x + self.dropout(self.proj(y.transpose(1, 2).reshape(batch, length, width)))
        return x + self.dropout(self.out(F.gelu(self.fc(self.norm2(x)))))


class CharacterLM(nn.Module):
    def __init__(self, config, active_ids=None):
        super().__init__()
        self.config = dict(config)
        self.embedding = nn.Embedding(config["vocab_size"], config["width"], padding_idx=PAD)
        self.positions = nn.Embedding(config["context"], config["width"])
        self.blocks = nn.ModuleList(Block(config) for _ in range(config["layers"]))
        self.norm = nn.LayerNorm(config["width"])
        self.dropout = nn.Dropout(config["dropout"])
        self.output = nn.Linear(config["width"], config["vocab_size"], bias=False)
        self.output.weight = self.embedding.weight
        allowed = torch.ones(config["vocab_size"], dtype=torch.bool) if active_ids is None else torch.zeros(config["vocab_size"], dtype=torch.bool)
        if active_ids is not None:
            allowed[active_ids] = True
        self.register_buffer("allowed", allowed, persistent=False)
        self.apply(self._initialize)
        for name, weight in self.named_parameters():
            if name.endswith(("proj.weight", "out.weight")):
                nn.init.normal_(weight, std=0.02 / math.sqrt(2 * config["layers"]))
        with torch.no_grad():
            self.embedding.weight[PAD].zero_()

    @staticmethod
    def _initialize(module):
        if isinstance(module, (nn.Linear, nn.Embedding)):
            nn.init.normal_(module.weight, std=0.02)
        if isinstance(module, nn.Linear) and module.bias is not None:
            nn.init.zeros_(module.bias)

    def forward(self, tokens):
        if not 1 <= tokens.shape[1] <= self.config["context"]:
            raise ValueError("Token sequence exceeds the model context")
        positions = torch.arange(tokens.shape[1], device=tokens.device)
        x = self.dropout(self.embedding(tokens) + self.positions(positions))
        for block in self.blocks:
            x = block(x)
        return self.output(self.norm(x)).masked_fill(~self.allowed, float("-inf"))


def parameter_report(config):
    with torch.device("meta"):
        model = CharacterLM(config)
    count = sum(parameter.numel() for parameter in model.parameters())
    return {"parameters": count, "fp32_weight_bytes": count * 4, "fp16_weight_bytes": count * 2,
            "note": "Weight storage arithmetic only; excludes runtime tensors, caches and export metadata."}


if __name__ == "__main__":
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default=ROOT / "configs/small.json")
    print(json.dumps(parameter_report(load_config(parser.parse_args().config)["model"]), indent=2))
