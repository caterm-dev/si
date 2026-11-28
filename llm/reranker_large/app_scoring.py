"""Differentiable counterparts of Rust SmallReranker adjustments, in bits."""
import math
import torch
from torch.nn import functional as F
from llm.reranker_small.tokenizer import BOS, PAD


def bonus_values(conditional, baseline, texts, has_context, params):
    weight = params['model_score_weight']
    if has_context:
        highest = max(conditional)
        cap = params['model_score_gap_limit_bits']
        return [weight * max((c-highest)/math.log(2), -cap) for c in conditional]
    cap = params['model_sentence_reward_cap_bits']
    highest = max(baseline)
    return [weight * max((b-highest)/math.log(2), -cap) for b in baseline]


def bonus_tensor(conditional, baseline, texts, has_context, params):
    weight = params['model_score_weight']
    if has_context:
        return weight * torch.clamp((conditional-conditional.max()) / math.log(2),
                                    min=-params['model_score_gap_limit_bits'])
    cap = params['model_sentence_reward_cap_bits']
    return weight * torch.clamp((baseline-baseline.max()) / math.log(2), min=-cap)


def pool_bonus_values(candidates, adjustment_mask, texts, bonuses):
    mapping = dict(zip(texts, bonuses, strict=True))
    worst = min(bonuses, default=0.0)
    return [mapping.get(candidate['text'], worst) if flag else 0.0
            for candidate, flag in zip(candidates, adjustment_mask, strict=True)]


def forward_app_sequences(model, tokenizer, row, device, settings):
    """Sum target log probabilities without output normalization or clipping."""
    from .scoring import suffix
    context = suffix(row.get('context', ''), tokenizer, settings['context_tokens'])
    prefix = [BOS, *tokenizer.encode(context)[1:-1]]
    selected = [i for i, flag in enumerate(row['model_mask']) if flag]
    texts = list(dict.fromkeys(row['candidates'][i]['text'] for i in selected))
    if len(texts) < 2:
        texts = []
        selected = []
    targets = [tokenizer.encode(t)[1:-1] for t in texts]
    observed = tokenizer.encode(row['observed_text'])[1:-1]
    sequences = [prefix+t for t in targets] + [prefix+observed]
    prefix_sizes = [len(prefix)]*len(sequences)
    length = max(map(len, sequences))-1
    inputs = torch.full((len(sequences), length), PAD, dtype=torch.long, device=device)
    labels = torch.full_like(inputs, -100)
    for i, (sequence, size) in enumerate(zip(sequences, prefix_sizes, strict=True)):
        n = len(sequence)-1
        inputs[i, :n] = torch.tensor(sequence[:-1], device=device)
        labels[i, size-1:n] = torch.tensor(sequence[size:], device=device)
    nll = F.cross_entropy(model(inputs).float().transpose(1, 2), labels, reduction='none', ignore_index=-100).sum(-1)
    return texts, -nll[:len(texts)], nll[-1] / len(observed)


def forward_app_pool(model, tokenizer, row, device, settings):
    from .scoring import suffix
    texts, logp, observed = forward_app_sequences(model, tokenizer, row, device, settings)
    scores = logp.new_tensor(row['base_scores_bits'])
    if texts:
        context = suffix(row.get('context', ''), tokenizer, settings['context_tokens'])
        bonuses = bonus_tensor(logp, logp, texts, bool(context), settings['app'])
        mapping = {t: i for i, t in enumerate(texts)}
        worst = bonuses.min()
        values = torch.stack([(bonuses[mapping[c['text']]] if c['text'] in mapping else worst)
                              if flag else bonuses.new_zeros(())
                              for c, flag in zip(row['candidates'], row['model_adjustment_mask'], strict=True)])
        scores = scores + values
    return scores, observed
