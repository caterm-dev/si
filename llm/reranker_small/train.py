"""Train/resume the same frozen character-LM experiment; never read test tokens."""

import argparse
import datetime
import json
import math
from pathlib import Path
import random

import torch
from torch.nn import functional as F

from llm.pinyin_to_text.common import canonical_bytes
from .data import load_bundle
from .model import CharacterLM, parameter_report
from .runtime import atomic_checkpoint, seed_everything, select_device, validation_loss
from .settings import ROOT, code_identity, load_config, resume_identity, write_json
from .tokenizer import PAD


def learning_rate(step, settings):
    if step <= settings['warmup_steps']:
        return settings['learning_rate'] * step / settings['warmup_steps']
    fraction = min(1.0, (step - settings['warmup_steps']) /
                   (settings['schedule_steps'] - settings['warmup_steps']))
    return settings['learning_rate'] * (0.1 + 0.9 * (1 + math.cos(math.pi * fraction)) / 2)


def train(config_path, data_path, run_path, device_name='mps', resume=False,
          max_steps=None, max_tokens=None, threads=4):
    config = load_config(config_path)
    settings = config['training']
    for name, value in [('max_steps', max_steps), ('max_tokens', max_tokens)]:
        if value is not None:
            if value < (1 if name == 'max_steps' else 0):
                raise ValueError('Invalid training budget')
            settings[name] = value
    if threads <= 0:
        raise ValueError('Thread count must be positive')
    run_path = Path(run_path)
    if not resume and run_path.exists():
        raise FileExistsError('Run exists; choose a new experiment or use resume.sh')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    seed_everything(config['seed'])
    manifest, tokenizer, datasets = load_bundle(data_path, config, ('train', 'validation'))
    identity = code_identity()
    checkpoint = None
    if resume:
        checkpoint = torch.load(run_path / 'last.pt', map_location='cpu', weights_only=True)
        expected = {'schema_version': 1, 'kind': 'si-character-lm', 'dataset_id': manifest['dataset_id'],
                    'tokenizer_digest': tokenizer.digest, 'resume_identity': resume_identity(config),
                    'code_identity': identity, 'device_type': device.type,
                    'torch_version': str(torch.__version__), 'threads': threads}
        if any(checkpoint.get(key) != value for key, value in expected.items()):
            raise ValueError('Resume requires identical code/data/tokenizer/config/device/PyTorch/threads except budgets')
        if checkpoint['step'] >= settings['max_steps'] or (settings['max_tokens'] and checkpoint['tokens_seen'] >= settings['max_tokens']):
            raise ValueError('Checkpoint reached its budget; increase --max-steps or --max-tokens')
    model = CharacterLM(config['model'], tokenizer.active_ids).to(device)
    optimizer = torch.optim.AdamW(model.parameters(), lr=settings['learning_rate'],
                                 betas=(0.9, 0.95), weight_decay=settings['weight_decay'])
    step = epoch = cursor = tokens_seen = 0
    best = float('inf')
    if checkpoint:
        model.load_state_dict(checkpoint['model'])
        optimizer.load_state_dict(checkpoint['optimizer'])
        step, epoch, cursor, tokens_seen, best = (checkpoint[key] for key in
                                                ('step', 'epoch', 'cursor', 'tokens_seen', 'best_validation_loss'))
        random.setstate(checkpoint['python_rng'])
        torch.set_rng_state(checkpoint['torch_rng'])
        if device.type == 'mps':
            torch.mps.set_rng_state(checkpoint['accelerator_rng'])
        elif device.type == 'cuda':
            torch.cuda.set_rng_state_all(checkpoint['accelerator_rng'])
        del checkpoint
    else:
        run_path.mkdir(parents=True)
        write_json(run_path / 'run.json', {
            'schema_version': 1, 'kind': 'si-character-lm', 'initialization': 'random', 'config': config,
            'created_utc': datetime.datetime.now(datetime.timezone.utc).isoformat(),
            'dataset_id': manifest['dataset_id'], 'code_identity': identity,
            'tokenizer_digest': tokenizer.digest, 'torch_version': str(torch.__version__),
            'device': str(device), 'threads': threads, 'model': parameter_report(config['model']),
            'sources': manifest['sources'],
        })

    def save(name):
        accelerator_rng = (torch.mps.get_rng_state() if device.type == 'mps' else
                           torch.cuda.get_rng_state_all() if device.type == 'cuda' else None)
        atomic_checkpoint(run_path / name, {
            'schema_version': 1, 'kind': 'si-character-lm', 'config': config,
            'dataset_id': manifest['dataset_id'], 'tokenizer': tokenizer.to_dict(),
            'tokenizer_digest': tokenizer.digest, 'resume_identity': resume_identity(config),
            'code_identity': identity, 'device_type': device.type, 'torch_version': str(torch.__version__),
            'threads': threads, 'model': model.state_dict(), 'optimizer': optimizer.state_dict(),
            'step': step, 'epoch': epoch, 'cursor': cursor, 'tokens_seen': tokens_seen,
            'best_validation_loss': best, 'python_rng': random.getstate(),
            'torch_rng': torch.get_rng_state(), 'accelerator_rng': accelerator_rng,
        })

    def log(record):
        with (run_path / 'metrics.jsonl').open('ab') as handle:
            handle.write(canonical_bytes(record) + b'\n')
        print(json.dumps(record), flush=True)

    if not resume:
        save('last.pt')
    log({'event': 'resume' if resume else 'start', 'step': step, 'tokens_seen': tokens_seen,
         'target_steps': settings['max_steps'], 'token_budget': settings['max_tokens']})
    model.train()
    order = None
    training = datasets['train']
    while step < settings['max_steps'] and (not settings['max_tokens'] or tokens_seen < settings['max_tokens']):
        batches = []
        for _ in range(settings['gradient_accumulation']):
            if cursor >= len(training):
                epoch += 1
                cursor = 0
                order = None
            if order is None:
                generator = torch.Generator().manual_seed(config['seed'] + epoch)
                order = torch.randperm(len(training), generator=generator)
            end = min(len(training), cursor + settings['batch_size'])
            batches.append(order[cursor:end].tolist())
            cursor = end
        target_count = sum(training.target_count(batch) for batch in batches)
        optimizer.zero_grad(set_to_none=True)
        rate = learning_rate(step + 1, settings)
        for group in optimizer.param_groups:
            group['lr'] = rate
        loss_sum = 0.0
        for batch in batches:
            inputs, labels = training.batch(batch, device)
            loss = F.cross_entropy(model(inputs).float().flatten(0, 1), labels.reshape(-1),
                                   ignore_index=PAD, reduction='sum')
            if not torch.isfinite(loss):
                raise RuntimeError('Nonfinite loss; last complete checkpoint remains intact')
            (loss / target_count).backward()
            loss_sum += float(loss.detach())
        torch.nn.utils.clip_grad_norm_(model.parameters(), settings['gradient_clip'], error_if_nonfinite=True)
        optimizer.step()
        step += 1
        tokens_seen += target_count
        finished = step == settings['max_steps'] or (settings['max_tokens'] and tokens_seen >= settings['max_tokens'])
        record = {'event': 'step', 'step': step, 'epoch': epoch, 'tokens_seen': tokens_seen,
                  'step_tokens': target_count, 'loss': loss_sum / target_count, 'learning_rate': rate}
        if step % settings['validate_every'] == 0 or finished:
            validation = validation_loss(model, datasets['validation'], settings['batch_size'], device,
                                         settings['validation_tokens'])
            record.update(validation_loss=validation['loss'], validation_tokens=validation['tokens'])
            if validation['loss'] < best:
                best = validation['loss']
                save('best.pt')
        log(record)
        if step % settings['save_every'] == 0 or finished:
            save('last.pt')
    return {'step': step, 'tokens_seen': tokens_seen, 'best_validation_loss': best, 'run': str(run_path)}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config', type=Path, default=ROOT / 'configs/small.json')
    parser.add_argument('--data', required=True, type=Path)
    parser.add_argument('--run', required=True, type=Path)
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'cuda'), default='mps')
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--resume', action='store_true')
    parser.add_argument('--max-steps', type=int)
    parser.add_argument('--max-tokens', type=int)
    args = parser.parse_args()
    print(json.dumps(train(args.config, args.data, args.run, args.device, args.resume,
                           args.max_steps, args.max_tokens, args.threads)))


if __name__ == '__main__':
    main()
