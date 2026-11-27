"""Initialize a separate one-pass LM continuation without changing legacy trainers."""

import argparse
import json
import math
from pathlib import Path
import random
import sys

import torch
from torch.nn import functional as F

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))

from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM, parameter_report
from llm.reranker_small.runtime import atomic_checkpoint, seed_everything, select_device, validation_loss
from llm.reranker_small.tokenizer import PAD
from llm.reranker_small.train import learning_rate
from llm.reranker_large.settings import (
    ROOT, code_identity, file_hash, fingerprint, load_config, resume_identity, write_json,
)

KIND = 'si-student-continued-pretrain-v1'


def train(config_path, data_path, run_path, init_checkpoint=None, *, device_name='mps',
          resume=False, max_steps=None, max_tokens=None, threads=4, check_only=False):
    config = load_config(config_path)
    settings = config['training']
    if config['stage'] != 'pretrain' or settings.get('single_pass') is not True:
        raise ValueError('Continuation requires a pretraining configuration with single_pass=true')
    if threads <= 0 or (resume and (init_checkpoint is not None or check_only)):
        raise ValueError('Use positive threads; resume cannot initialize or run check-only')
    for name, override in (('max_steps', max_steps), ('max_tokens', max_tokens)):
        if override is not None:
            if type(override) is not int or override < (1 if name == 'max_steps' else 0):
                raise ValueError('Invalid continuation budget')
            settings[name] = override
    run_path = Path(run_path)
    if not resume and run_path.exists():
        raise FileExistsError('Choose an independent new run or use --resume')
    torch.set_num_threads(threads)
    device = select_device('cpu' if check_only else device_name)
    seed_everything(config['seed'])
    manifest, tokenizer, datasets = load_bundle(data_path, config, ('train', 'validation'))
    if manifest.get('tokenizer_origin') != 'frozen-parent':
        raise ValueError('Continuation requires an explicitly frozen-parent tokenizer')
    training = datasets['train']
    pass_steps = math.ceil(math.ceil(len(training)/settings['batch_size'])/settings['gradient_accumulation'])
    settings['max_steps'] = min(settings['max_steps'], pass_steps)
    settings['warmup_steps'] = min(settings['warmup_steps'], max(1, pass_steps-1))
    settings['schedule_steps'] = max(pass_steps, settings['warmup_steps']+1)
    identity = fingerprint(dict(shared=code_identity(), continuation=file_hash(Path(__file__))))
    expected = dict(schema_version=1, kind='si-character-lm', stage='pretrain', continuation_kind=KIND,
        dataset_id=manifest['dataset_id'], training_data_id=manifest['dataset_id'],
        tokenizer_digest=tokenizer.digest, code_identity=identity, resume_identity=resume_identity(config),
        device_type=device.type, torch_version=str(torch.__version__), threads=threads)
    parent_pin = None
    if resume:
        checkpoint = torch.load(run_path/'last.pt', map_location='cpu', weights_only=True)
        if any(checkpoint.get(k) != v for k, v in expected.items()):
            raise ValueError('Resume requires identical continuation code/data/config/tokenizer/device/PyTorch/threads')
        if checkpoint['step'] >= settings['max_steps'] or (settings['max_tokens']
                and checkpoint['tokens_seen'] >= settings['max_tokens']):
            raise ValueError('Checkpoint reached its budget; explicitly extend it within this single pass')
        initial = checkpoint['initial_checkpoint']
        lineage = checkpoint['lineage_dataset_ids']
    else:
        if init_checkpoint is None:
            raise ValueError('A new continuation requires --init-checkpoint')
        parent_pin = file_hash(init_checkpoint)
        checkpoint = torch.load(init_checkpoint, map_location='cpu', weights_only=True)
        if (checkpoint.get('schema_version') != 1 or checkpoint.get('kind') != 'si-character-lm'
                or checkpoint.get('stage') != 'pretrain' or checkpoint['config']['model'] != config['model']
                or checkpoint['tokenizer_digest'] != tokenizer.digest or checkpoint['tokenizer'] != tokenizer.to_dict()
                or file_hash(init_checkpoint) != parent_pin):
            raise ValueError('Initialization requires a matching pretrained student and identical frozen tokenizer')
        ancestor = checkpoint.get('initial_checkpoint') or {}
        prior = (set(checkpoint.get('lineage_dataset_ids', []))
                 | set(ancestor.get('ancestor_dataset_ids', [])) | {checkpoint['dataset_id']})
        if ancestor.get('dataset_id'):
            prior.add(ancestor['dataset_id'])
        if not prior <= set(manifest.get('excluded_dataset_ids', [])) or manifest['dataset_id'] in prior:
            raise ValueError('New data must explicitly exclude every ancestor training dataset')
        lineage = sorted(prior | {manifest['dataset_id']})
        initial = dict(sha256=parent_pin, dataset_id=checkpoint['dataset_id'], step=checkpoint['step'],
                       stage=checkpoint['stage'], code_identity=checkpoint['code_identity'],
                       ancestor_dataset_ids=sorted(prior))
    model = CharacterLM(config['model'], tokenizer.active_ids).to(device)
    model.load_state_dict(checkpoint['model'])
    if check_only:
        return dict(ready=True, training_started=False, dataset_id=manifest['dataset_id'],
                    initial_checkpoint=initial, one_pass_steps=pass_steps, effective_steps=settings['max_steps'],
                    train_targets=manifest['splits']['train']['targets'], run=str(run_path),
                    training=config['training'], model=parameter_report(config['model']))
    optimizer = torch.optim.AdamW(model.parameters(), lr=settings['learning_rate'],
                                 betas=(.9, .95), weight_decay=settings['weight_decay'])
    step = cursor = tokens_seen = 0
    best = float('inf')
    if resume:
        optimizer.load_state_dict(checkpoint['optimizer'])
        step, cursor, tokens_seen, best = (checkpoint[k] for k in
            ('step', 'cursor', 'tokens_seen', 'best_validation_loss'))
        random.setstate(checkpoint['python_rng'])
        torch.set_rng_state(checkpoint['torch_rng'])
        if device.type == 'mps':
            torch.mps.set_rng_state(checkpoint['accelerator_rng'])
        elif device.type == 'cuda':
            torch.cuda.set_rng_state_all(checkpoint['accelerator_rng'])
    else:
        run_path.mkdir(parents=True)
        write_json(run_path/'run.json', dict(**expected, config=config, initial_checkpoint=initial,
            lineage_dataset_ids=lineage, initialization='weights-only-new-optimizer',
            model=parameter_report(config['model']), sources=manifest['sources']))
    del checkpoint

    def save(name):
        accelerator = (torch.mps.get_rng_state() if device.type == 'mps' else
                       torch.cuda.get_rng_state_all() if device.type == 'cuda' else None)
        atomic_checkpoint(run_path/name, dict(**expected, config=config, tokenizer=tokenizer.to_dict(),
            teacher=None, initial_checkpoint=initial, lineage_dataset_ids=lineage, model=model.state_dict(),
            optimizer=optimizer.state_dict(), step=step, epoch=0, cursor=cursor, tokens_seen=tokens_seen,
            best_validation_loss=best, python_rng=random.getstate(), torch_rng=torch.get_rng_state(),
            accelerator_rng=accelerator))

    if not resume:
        save('last.pt')
    model.train()
    order = torch.randperm(len(training), generator=torch.Generator().manual_seed(config['seed']))
    while step < settings['max_steps'] and (not settings['max_tokens'] or tokens_seen < settings['max_tokens']):
        batches = []
        for _ in range(settings['gradient_accumulation']):
            if cursor >= len(training):
                break
            end = min(len(training), cursor+settings['batch_size'])
            batches.append(order[cursor:end].tolist())
            cursor = end
        if not batches:
            break
        count = sum(training.target_count(batch) for batch in batches)
        optimizer.zero_grad(set_to_none=True)
        rate = learning_rate(step+1, settings)
        for group in optimizer.param_groups:
            group['lr'] = rate
        loss_sum = 0.0
        for batch in batches:
            inputs, labels = training.batch(batch, device)
            loss = F.cross_entropy(model(inputs).float().flatten(0, 1), labels.reshape(-1),
                                   ignore_index=PAD, reduction='sum')
            if not torch.isfinite(loss):
                raise RuntimeError('Nonfinite continuation loss; last complete checkpoint is preserved')
            (loss/count).backward()
            loss_sum += float(loss.detach())
        torch.nn.utils.clip_grad_norm_(model.parameters(), settings['gradient_clip'], error_if_nonfinite=True)
        optimizer.step()
        step += 1
        tokens_seen += count
        finished = (step == settings['max_steps'] or cursor == len(training)
                    or (settings['max_tokens'] and tokens_seen >= settings['max_tokens']))
        record = dict(stage='pretrain', phase='continued-pretrain', step=step, epoch=0, cursor=cursor,
                      tokens_seen=tokens_seen, loss=loss_sum/count, learning_rate=rate)
        if step % settings['validate_every'] == 0 or finished:
            record['validation'] = validation_loss(model, datasets['validation'], settings['batch_size'],
                                                    device, settings['validation_tokens'])
            if record['validation']['loss'] < best:
                best = record['validation']['loss']
                save('best.pt')
        with (run_path/'metrics.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record, allow_nan=False)+'\n')
        print(json.dumps(record, allow_nan=False), flush=True)
        if step % settings['save_every'] == 0 or finished:
            save('last.pt')
    return dict(stage='pretrain', step=step, tokens_seen=tokens_seen, one_pass_steps=pass_steps,
                pass_complete=cursor == len(training), best_validation_loss=best, run=str(run_path))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT/'configs/continue-pretrain.json')
    parser.add_argument('--data', type=Path, default=ROOT/'data/prepared/student-15m-extra-v1/lm')
    parser.add_argument('--run', type=Path, default=ROOT/'runs/student-15m-extra-v1/pretrain')
    parser.add_argument('--init-checkpoint', type=Path)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--check-only', action='store_true')
    parser.add_argument('--max-steps', type=int)
    parser.add_argument('--max-tokens', type=int)
    parser.add_argument('--device', choices=('cpu', 'mps', 'cuda', 'auto'), default='mps')
    parser.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    if args.resume and args.init_checkpoint:
        parser.error('--resume and --init-checkpoint are mutually exclusive')
    checkpoint = args.init_checkpoint
    if not args.resume and checkpoint is None:
        checkpoint = ROOT/'runs/student-15m-v1/snapshots/pretrain-step-060000/best.pt'
    result = train(args.config, args.data, args.run, checkpoint, device_name=args.device,
                   resume=args.resume, max_steps=args.max_steps, max_tokens=args.max_tokens,
                   threads=args.threads, check_only=args.check_only)
    print(json.dumps(result, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
