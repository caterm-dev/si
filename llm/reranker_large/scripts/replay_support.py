"""Deterministic LM replay and constrained selection for offline experiments."""
import math
import random

import torch
from llm.pinyin_to_text.common import normalized
from llm.reranker_small.tokenizer import PAD


def replay_budget(kd_targets,fraction):
    if not 0<=fraction<1 or kd_targets<0:
        raise ValueError('Invalid replay fraction or target count')
    return round(kd_targets*fraction/(1-fraction))


class ReplayStream:
    def __init__(self,dataset,tokenizer,seed,forbidden=()):
        self.dataset=dataset
        self.tokenizer=tokenizer
        self.random=random.Random(seed)
        self.forbidden=tuple(sorted({normalized(t) for t in forbidden if len(normalized(t))>=4}))
        self.draws=self.rejected=self.targets=0

    def state(self):
        return dict(rng=self.random.getstate(),draws=self.draws,rejected=self.rejected,targets=self.targets)

    def restore(self,state):
        self.random.setstate(state['rng'])
        self.draws,self.rejected,self.targets=(state[k] for k in ('draws','rejected','targets'))

    def batch(self,target_count,device):
        if target_count<=0:raise ValueError('Replay batch must supervise a positive token count')
        indices=[];available=0;attempts=0
        while available<target_count:
            attempts+=1
            if attempts>target_count*100+1000:raise ValueError('No eligible replay windows')
            index=self.random.randrange(len(self.dataset));self.draws+=1
            start,count=map(int,self.dataset.windows[index])
            try:text=normalized(self.tokenizer.decode(self.dataset.tokens[start:start+count].tolist()))
            except UnicodeDecodeError:self.rejected+=1;continue
            if any(value in text for value in self.forbidden):self.rejected+=1;continue
            indices.append(index);available+=count-1
        inputs,labels=self.dataset.batch(indices,device)
        # Mask only surplus supervised targets, preserving real padding.
        keep=labels.ne(PAD).flatten().cumsum(0).le(target_count).reshape_as(labels)
        labels=labels.masked_fill(~keep,PAD)
        assert int(labels.ne(PAD).sum())==target_count
        self.targets+=target_count
        return inputs,labels


def eligible_selection(metrics,baseline_lm,max_increase):
    return math.isfinite(metrics['lm_loss']) and metrics['lm_loss']-baseline_lm<max_increase


def improves_selection(metrics,best,baseline_lm,max_increase):
    # Strict top1 improvement; ties preserve the earlier checkpoint.
    return eligible_selection(metrics,baseline_lm,max_increase) and metrics['native_top1']>best['native_top1']
