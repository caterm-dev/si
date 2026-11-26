"""Differentiable production-bounded student scores and listwise distillation."""

import math
import unicodedata

import torch
from torch.nn import functional as F

from llm.reranker_small.tokenizer import BOS, PAD

LANGUAGES = ('zh-Hans', 'en', 'mixed')


def printable(text):
    return (isinstance(text, str) and bool(text) and len(text.encode('utf-8')) <= 4096
            and not any(unicodedata.category(c) in ('Cc', 'Cs') for c in text))


def suffix(text, tokenizer, budget):
    selected, used = [], 0
    for scalar in reversed(text):
        size = len(tokenizer.encode(scalar)) - 2
        if used + size > budget:
            break
        selected.append(scalar)
        used += size
    return ''.join(reversed(selected))


def validate_pool(row, tokenizer, config):
    candidates = row.get('candidates')
    settings = config['scoring']
    if not isinstance(candidates, list) or not 2 <= len(candidates) <= settings['max_candidates']:
        raise ValueError('Pool must contain 2..max_candidates candidates')
    identities = set()
    for candidate in candidates:
        if (not isinstance(candidate, dict) or not printable(candidate.get('text'))
                or candidate.get('language') not in LANGUAGES):
            raise ValueError('Expected a printable text and stable language per candidate')
        identity = (candidate['text'], candidate['language'])
        if identity in identities:
            raise ValueError('Duplicate language-aware candidate identity')
        identities.add(identity)
    context = row.get('context', '')
    if (not isinstance(context, str) or len(context.encode('utf-8')) > 8192
            or any(unicodedata.category(c) == 'Cs' for c in context)):
        raise ValueError('Invalid context')
    eligible = all(len(tokenizer.encode(c['text'])) - 2 <= settings['candidate_tokens'] for c in candidates)
    if not printable(row.get('observed_text')):
        raise ValueError('Pool needs its observed natural-text span for the auxiliary LM loss')
    eligible = eligible and len(tokenizer.encode(row['observed_text'])) - 2 <= settings['candidate_tokens']
    references = row.get('reference_indices', [])
    if (not isinstance(references, list) or len(set(references)) != len(references)
            or any(type(i) is not int or not 0 <= i < len(candidates) for i in references)
            or (references and row.get('labels_reviewed') is not True)):
        raise ValueError('References must be explicitly reviewed, unique valid indices')
    if 'teacher_scores' in row:
        scores = row['teacher_scores']
        if (not isinstance(scores, list) or len(scores) != len(candidates)
                or any(type(x) not in (int, float) or not math.isfinite(x) for x in scores)):
            raise ValueError('Teacher scores must be finite and match candidate order')
    return eligible


def forward_pool(model, tokenizer, row, device, settings):
    """Return mean-per-scalar scores and the observed span's per-token LM loss."""
    context = suffix(row.get('context', ''), tokenizer, settings['context_tokens'])
    prefix = [BOS, *tokenizer.encode(context)[1:-1]]
    texts = [c['text'] for c in row['candidates']] + [row['observed_text']]
    targets = [tokenizer.encode(text)[1:-1] for text in texts]
    if any(not ids or len(ids) > settings['candidate_tokens'] for ids in targets):
        raise ValueError('Unscorable pool: candidate exceeds the token budget')
    sequences = [prefix + ids for ids in targets]
    length = max(map(len, sequences)) - 1
    values = torch.full((len(sequences), length), PAD, dtype=torch.long, device=device)
    labels = torch.full_like(values, -100)
    for i, sequence in enumerate(sequences):
        n = len(sequence) - 1
        values[i, :n] = torch.tensor(sequence[:-1], device=device)
        labels[i, len(prefix) - 1:n] = torch.tensor(sequence[len(prefix):], device=device)
    nll = F.cross_entropy(model(values).float().transpose(1, 2), labels,
                          reduction='none', ignore_index=-100).sum(-1)
    lengths = torch.tensor([len(text) for text in texts[:-1]], device=device)
    return -nll[:-1] / lengths, nll[-1] / len(targets[-1])


def distillation_loss(scores, teacher_scores, observed_loss, settings, references=()):
    temperature = settings['temperature']
    teacher = torch.as_tensor(teacher_scores, dtype=scores.dtype, device=scores.device).detach()
    if teacher.shape != scores.shape or not torch.isfinite(teacher).all():
        raise ValueError('Teacher/student score vectors differ or are nonfinite')
    kd = F.kl_div(F.log_softmax(scores / temperature, dim=-1),
                  F.softmax(teacher / temperature, dim=-1), reduction='sum') * temperature**2
    supervised = scores.new_zeros(())
    if references and settings['label_weight']:
        supervised = -torch.logsumexp(F.log_softmax(scores, dim=-1)[list(references)], dim=0)
    total = (settings['kd_weight'] * kd + settings['lm_weight'] * observed_loss
             + settings['label_weight'] * supervised)
    return total, kd
