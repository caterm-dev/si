"""LM validation and candidate scoring, preserving exact supplied text and order ties."""

import math
import unicodedata

import torch
from torch.nn import functional as F

from llm.pinyin_to_text.runtime import atomic_checkpoint, seed_everything, select_device
from .model import CharacterLM
from .tokenizer import BOS, PAD, Tokenizer


def load_checkpoint(path, device):
    checkpoint = torch.load(path, map_location='cpu', weights_only=True)
    if checkpoint.get('schema_version') != 1 or checkpoint.get('kind') != 'si-character-lm':
        raise ValueError('Expected a character-LM reranker checkpoint, not a conversion model')
    value = checkpoint['tokenizer']
    tokenizer = Tokenizer(value['vocab_size'], value['characters'])
    if tokenizer.digest != checkpoint['tokenizer_digest']:
        raise ValueError('Checkpoint tokenizer checksum mismatch')
    model = CharacterLM(checkpoint['config']['model'], tokenizer.active_ids)
    model.load_state_dict(checkpoint['model'])
    model.to(device).eval()
    return checkpoint, model, tokenizer


@torch.inference_mode()
def validation_loss(model, dataset, batch_size, device, max_tokens=0):
    was_training = model.training
    model.eval()
    total = 0.0
    count = 0
    try:
        # A prefix budget would validate mostly the first corpus in the bundle.
        # Sample a fixed permutation instead, without advancing training RNG.
        order = (torch.randperm(len(dataset), generator=torch.Generator().manual_seed(0)).tolist()
                 if max_tokens else range(len(dataset)))
        for offset in range(0, len(dataset), batch_size):
            if max_tokens and count >= max_tokens:
                break
            indices = list(order[offset:min(len(dataset), offset + batch_size)])
            inputs, labels = dataset.batch(indices, device)
            if max_tokens:
                remaining = max_tokens - count
                if remaining <= 0:
                    break
                flat = labels.reshape(-1)
                keep = flat.ne(PAD).cumsum(0).le(remaining).reshape_as(labels)
                labels = labels.masked_fill(~keep, PAD)
            tokens = int(labels.ne(PAD).sum())
            loss = F.cross_entropy(model(inputs).float().flatten(0, 1), labels.reshape(-1),
                                   ignore_index=PAD, reduction='sum')
            total += float(loss)
            count += tokens
        if not count or not math.isfinite(total):
            raise ValueError('Validation has no finite supervised tokens')
        return {'loss': total / count, 'tokens': count}
    finally:
        model.train(was_training)


@torch.inference_mode()
def rank_candidates(model, tokenizer, context, candidates, device, batch_size=4, length_penalty=0.0,
                    max_candidates=32):
    if not isinstance(context, str) or not all(isinstance(text, str) for text in candidates):
        raise ValueError('Context and candidates must be Unicode text')
    if len(candidates) > max_candidates or batch_size <= 0 or not 0 <= length_penalty <= 2:
        raise ValueError('Invalid candidate scoring limits')
    if not candidates:
        return {'order': [], 'scores': [], 'abstained': False}
    if any(not text or len(text.encode('utf-8')) > 4096
           or any(unicodedata.category(c) in ('Cc', 'Cs') for c in text) for text in candidates):
        raise ValueError('Candidates must be nonempty printable text of at most 4096 UTF-8 bytes')
    encoded = [tokenizer.encode(text)[1:-1] for text in candidates]
    longest = max(map(len, encoded))
    limit = model.config['context']
    if longest > limit:
        return {'order': list(range(len(candidates))), 'scores': [None] * len(candidates),
                'abstained': True, 'reason': 'A candidate exceeds the context; original order retained'}
    available = limit - longest
    groups = []
    used = 0
    for character in reversed(context):
        tokens = tokenizer.encode(character)[1:-1]
        if used + len(tokens) > available:
            break
        groups.append(tokens)
        used += len(tokens)
    # Trim only at Unicode scalar boundaries, including a byte-fallback scalar.
    history = [token for group in reversed(groups) for token in group]
    prefix = [BOS, *history]
    scores = []
    was_training = model.training
    model.eval()
    try:
        for offset in range(0, len(candidates), batch_size):
            rows = [[*prefix, *tokens] for tokens in encoded[offset:offset + batch_size]]
            length = max(map(len, rows))
            values = torch.full((len(rows), length), PAD, dtype=torch.long, device=device)
            for index, row in enumerate(rows):
                values[index, :len(row)] = torch.tensor(row, device=device)
            inputs, targets = values[:, :-1], values[:, 1:]
            log_probs = model(inputs).float().log_softmax(-1)
            # Padding is not a predicted token. Gather an allowed placeholder at
            # ignored positions so masked -inf values never produce NaN via 0*-inf.
            safe_targets = targets.masked_fill(targets.eq(PAD), tokenizer.active_ids[0])
            picked = log_probs.gather(-1, safe_targets.unsqueeze(-1)).squeeze(-1)
            for index, row in enumerate(rows):
                # Position prefix_len-1 predicts the FIRST candidate token.
                value = float(picked[index, len(prefix) - 1:len(row) - 1].sum())
                value /= len(candidates[offset + index]) ** length_penalty
                if not math.isfinite(value):
                    raise ValueError('Nonfinite candidate score')
                scores.append(value)
    finally:
        model.train(was_training)
    return {'order': sorted(range(len(candidates)), key=lambda index: (-scores[index], index)),
            'scores': scores, 'abstained': False, 'context_tokens_used': len(history)}
