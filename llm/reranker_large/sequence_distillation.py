"""Candidate-level sequence KL, separate from the exact App inference policy."""

import math

from .app_scoring import forward_app_sequences
from .scoring import distillation_loss


def sequence_logits(logp, weight):
    # Centering is softmax-invariant; no hard cap, length average or base score.
    values = logp * (weight / math.log(2))
    return values - values.max()


def pool_loss(model, tokenizer, row, config, device):
    texts, logp, observed = forward_app_sequences(model, tokenizer, row, device, config['scoring'])
    if len(texts) < 2:
        raise ValueError('Candidate sequence KL requires two distinct scored texts')
    source = {}
    for candidate, selected, value in zip(row['candidates'], row['model_mask'],
                                         row['teacher_conditional_logp'], strict=True):
        if selected:
            text = candidate['text']
            if text in source and source[text] != value:
                raise ValueError('Identical teacher text has inconsistent likelihoods')
            source[text] = value
    teacher_logp = logp.new_tensor([source[text] for text in texts])
    weight = config['scoring']['app']['model_score_weight']
    return distillation_loss(sequence_logits(logp, weight), sequence_logits(teacher_logp, weight),
                             observed, config['distillation'])
