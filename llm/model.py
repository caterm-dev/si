"""A randomly initialized, tied-embedding spelling-to-text Transformer."""

import argparse
import math

import torch
from torch import nn
from torch.utils.checkpoint import checkpoint

from .common import load_config
from .tokenizer import PAD


class SpellingTransformer(nn.Module):
    def __init__(self, config, active_ids=None, activation_checkpointing=False):
        super().__init__()
        self.config = dict(config)
        self.activation_checkpointing = activation_checkpointing
        width = config["d_model"]
        self.embedding = nn.Embedding(config["vocab_size"], width, padding_idx=PAD)
        layer_args = dict(d_model=width, nhead=config["nhead"], dim_feedforward=config["dim_feedforward"],
                          dropout=config["dropout"], activation="gelu", batch_first=True, norm_first=True)
        # Construct independently initialized layers, rather than cloning one initialized layer.
        self.encoder = nn.ModuleList(nn.TransformerEncoderLayer(**layer_args) for _ in range(config["encoder_layers"]))
        self.decoder = nn.ModuleList(nn.TransformerDecoderLayer(**layer_args) for _ in range(config["decoder_layers"]))
        self.encoder_norm = nn.LayerNorm(width)
        self.decoder_norm = nn.LayerNorm(width)
        self.output = nn.Linear(width, config["vocab_size"], bias=False)
        self.output.weight = self.embedding.weight
        self.dropout = nn.Dropout(config["dropout"])
        limit = max(config["max_source_tokens"], config["max_target_tokens"])
        positions = torch.arange(limit).unsqueeze(1)
        frequencies = torch.exp(torch.arange(0, width, 2) * (-math.log(10000.0) / width))
        encoding = torch.zeros(limit, width)
        encoding[:, 0::2] = torch.sin(positions * frequencies)
        encoding[:, 1::2] = torch.cos(positions * frequencies)
        self.register_buffer("positions", encoding, persistent=False)
        allowed = torch.ones(config["vocab_size"], dtype=torch.bool) if active_ids is None else torch.zeros(config["vocab_size"], dtype=torch.bool)
        if active_ids is not None:
            allowed[active_ids] = True
        self.register_buffer("allowed", allowed, persistent=False)
        # Balance the scaled token embeddings with positional encoding and the tied
        # output projection using width-scaled initialization.
        nn.init.normal_(self.embedding.weight, mean=0, std=width ** -0.5)
        with torch.no_grad():
            self.embedding.weight[PAD].zero_()

    def embed(self, tokens):
        if tokens.shape[1] > self.positions.shape[0]:
            raise ValueError("Sequence exceeds model position limit")
        value = self.embedding(tokens) * math.sqrt(self.config["d_model"])
        return self.dropout(value + self.positions[:tokens.shape[1]])

    def encode(self, source):
        padding = source.eq(PAD)
        hidden = self.embed(source)
        if source.device.type == "mps":
            batch, source_length = padding.shape
            kwargs = {"src_mask": padding[:, None, None, :].expand(
                batch, self.config["nhead"], source_length, source_length
            ).reshape(batch * self.config["nhead"], source_length, source_length).contiguous()}
        else:
            kwargs = {"src_key_padding_mask": padding}
        for layer in self.encoder:
            if self.training and self.activation_checkpointing:
                hidden = checkpoint(layer, hidden, **kwargs, use_reentrant=False)
            else:
                hidden = layer(hidden, **kwargs)
        return self.encoder_norm(hidden), padding

    def decode(self, target, memory, source_padding):
        hidden = self.embed(target)
        causal = torch.ones(target.shape[1], target.shape[1], device=target.device, dtype=torch.bool).triu(1)
        kwargs = dict(tgt_mask=causal, tgt_key_padding_mask=target.eq(PAD))
        if target.device.type == "mps":
            # PyTorch 2.6 MPS aborted when variable-length attention mixed
            # broadcast/full masks. Materialize encoder and cross-attention
            # masks consistently, preserving every padding constraint.
            batch, source_length = source_padding.shape
            heads, target_length = self.config["nhead"], target.shape[1]
            kwargs["memory_mask"] = source_padding[:, None, None, :].expand(
                batch, heads, target_length, source_length
            ).reshape(batch * heads, target_length, source_length).contiguous()
        else:
            kwargs["memory_key_padding_mask"] = source_padding
        for layer in self.decoder:
            if self.training and self.activation_checkpointing:
                hidden = checkpoint(layer, hidden, memory, **kwargs, use_reentrant=False)
            else:
                hidden = layer(hidden, memory, **kwargs)
        logits = self.output(self.decoder_norm(hidden))
        return logits.masked_fill(~self.allowed, float("-inf"))

    def forward(self, source, target):
        memory, padding = self.encode(source)
        return self.decode(target, memory, padding)


def parameter_report(config):
    # The meta device counts the actual architecture without allocating 0.4B weights.
    with torch.device("meta"):
        model = SpellingTransformer(config)
    parameters = sum(p.numel() for p in model.parameters())
    return {"parameters": parameters, "billions": parameters / 1e9,
            "fp32_weight_bytes": parameters * 4,
            "fp32_weights_gradients_adam_bytes": parameters * 16,
            "note": "Estimates exclude activations, attention, logits, allocator and checkpoint overhead."}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--config", default="llm/configs/0.4b.json")
    args = parser.parse_args()
    print(parameter_report(load_config(args.config)["model"]))


if __name__ == "__main__":
    main()
