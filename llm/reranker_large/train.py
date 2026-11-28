"""Independent pretraining/distillation runs with strict, revision-bound resume."""

import json
from pathlib import Path
import random

import torch
from torch.nn import functional as F

from llm.reranker_small.data import load_bundle
from llm.reranker_small.model import CharacterLM, parameter_report
from llm.reranker_small.runtime import atomic_checkpoint, seed_everything, select_device, validation_loss
from llm.reranker_small.tokenizer import PAD
from llm.reranker_small.train import learning_rate
from .data import checked_file, load_pools, manifest_at
from .scoring import distillation_loss, forward_pool, validate_pool
from .settings import (APP_PROTOCOL, SEQUENCE_KD, code_identity, file_hash, load_config,
                       resume_identity, training_objective, write_json)


def pool_loss(model, tokenizer, row, config, device):
    if not validate_pool(row, tokenizer, config) or 'teacher_scores' not in row:
        raise ValueError('Distillation requires eligible pools and cached teacher scores')
    if training_objective(config) == SEQUENCE_KD:
        from .sequence_distillation import pool_loss as sequence_pool_loss
        total, kd = sequence_pool_loss(model, tokenizer, row, config, device)
    else:
        scores, observed = forward_pool(model, tokenizer, row, device, config['scoring'])
        total, kd = distillation_loss(scores, row['teacher_scores'], observed,
                                     config['distillation'], row.get('reference_indices', []))
    if not torch.isfinite(total):
        raise RuntimeError('Nonfinite distillation loss')
    return total, kd


@torch.inference_mode()
def validate_distillation(model, tokenizer, data, config, device):
    was_training = model.training
    model.eval()
    total = kd = 0.0
    try:
        # Budget counts pools in this phase, explicitly reported as partial.
        count = min(len(data), config['distillation']['validation_pools'])
        order = torch.randperm(len(data), generator=torch.Generator().manual_seed(0))[:count].tolist()
        for i in order:
            value, divergence = pool_loss(model, tokenizer, data[i], config, device)
            total += float(value)
            kd += float(divergence)
        if not count:
            raise ValueError('Validation pool split is empty')
        result = dict(loss=total / count, kl=kd / count, pools=count, partial=count < len(data))
        if training_objective(config) == SEQUENCE_KD:
            result['objective'] = SEQUENCE_KD
        return result
    finally:
        model.train(was_training)


def load_initialization(path, config, tokenizer, manifest, init_data=None):
    """Accept identical-data weights or a verified continuation of this corpus."""
    pin = file_hash(path)
    parent = torch.load(path, map_location='cpu', weights_only=True)
    if (parent.get('schema_version') != 1 or parent.get('kind') != 'si-character-lm'
            or parent.get('stage') != 'pretrain' or parent['config']['model'] != config['model']
            or parent.get('tokenizer_digest') != tokenizer.digest
            or parent.get('tokenizer') != tokenizer.to_dict() or file_hash(path) != pin):
        raise ValueError('Initialization requires a matching pretrained student and identical frozen tokenizer')
    initial = dict(sha256=pin, dataset_id=parent['dataset_id'], step=parent['step'],
                   stage=parent['stage'], code_identity=parent['code_identity'])
    if parent['dataset_id'] != manifest['dataset_id']:
        if init_data is None:
            raise ValueError('Continued initialization requires --init-data and verified ancestor dataset lineage')
        source_pin = file_hash(Path(init_data) / 'manifest.json')
        source = manifest_at(init_data, 'si-character-lm')
        ancestor = parent.get('initial_checkpoint') or {}
        lineage = parent.get('lineage_dataset_ids', [])
        prior = ancestor.get('ancestor_dataset_ids', [])
        excluded = source.get('excluded_dataset_ids', [])
        if any(not isinstance(v, list) or any(not isinstance(x, str) for x in v)
               for v in (lineage, prior, excluded)):
            raise ValueError('Invalid continuation dataset lineage')
        prior = set(prior) | {ancestor.get('dataset_id')}
        if (parent.get('continuation_kind') != 'si-student-continued-pretrain-v1'
                or source['dataset_id'] != parent['dataset_id']
                or source.get('tokenizer_origin') != 'frozen-parent'
                or source.get('parent_dataset_id') != ancestor.get('dataset_id')
                or source['tokenizer_digest'] != tokenizer.digest
                or source['model_limits'] != {k: config['model'][k] for k in ('vocab_size', 'context')}
                or manifest['dataset_id'] not in prior or not prior <= set(excluded)
                or set(lineage) != prior | {parent['dataset_id']}):
            raise ValueError('Initialization corpus must be a recorded continuation of the candidate-pool LM ancestor')
        source_tokenizer = checked_file(init_data, source, 'tokenizer.json')
        from llm.reranker_small.tokenizer import Tokenizer
        if Tokenizer.load(source_tokenizer).to_dict() != tokenizer.to_dict():
            raise ValueError('Initialization source tokenizer bytes differ')
        if file_hash(Path(init_data) / 'manifest.json') != source_pin:
            raise ValueError('Initialization source manifest changed')
        initial.update(parent_initial_checkpoint=ancestor, lineage_dataset_ids=lineage,
                       source_dataset_manifest=source,
                       source_dataset_manifest_sha256=source_pin)
    elif init_data is not None:
        source = manifest_at(init_data, 'si-character-lm')
        if source['dataset_id'] != parent['dataset_id']:
            raise ValueError('Initialization data do not match the checkpoint')
    return parent, initial


def train(config_path, data_path, run_path, device_name='mps', *, pools_path=None,
          init_checkpoint=None, init_data=None, check_only=False, resume=False,
          max_steps=None, max_tokens=None, threads=4):
    config = load_config(config_path)
    settings, stage = config['training'], config['stage']
    for key, override in (('max_steps', max_steps), ('max_tokens', max_tokens)):
        if override is not None:
            if type(override) is not int or override < (1 if key == 'max_steps' else 0):
                raise ValueError('Invalid training budget')
            settings[key] = override
    if threads <= 0 or (resume and (init_checkpoint is not None or init_data is not None or check_only)):
        raise ValueError('Use positive threads and choose initialization or resume')
    if stage == 'distill' and not pools_path:
        raise ValueError('Distillation needs a frozen teacher cache')
    if stage == 'pretrain' and (pools_path or init_checkpoint or init_data or check_only):
        raise ValueError('This student pretraining starts from random weights without teacher data')
    if stage == 'distill' and not resume and init_checkpoint is None:
        raise ValueError('Start distillation from a compatible pretrained student')
    if init_data is not None and init_checkpoint is None:
        raise ValueError('Initialization data require a source checkpoint')
    run_path = Path(run_path)
    if not resume and run_path.exists():
        raise FileExistsError('Choose a new run directory')
    torch.set_num_threads(threads)
    device = select_device('cpu' if check_only else device_name)
    seed_everything(config['seed'])
    manifest, tokenizer, datasets = load_bundle(data_path, config, ('train', 'validation'))
    training_data_id, teacher = manifest['dataset_id'], None
    if stage == 'distill':
        pool_manifest, datasets = load_pools(pools_path, config, manifest, tokenizer,
                                            ('train', 'validation'), scored=True)
        training_data_id, teacher = pool_manifest['dataset_id'], pool_manifest['teacher']
    identity = code_identity()
    expected = dict(schema_version=1, kind='si-character-lm', stage=stage,
        dataset_id=manifest['dataset_id'], training_data_id=training_data_id, tokenizer_digest=tokenizer.digest,
        code_identity=identity, resume_identity=resume_identity(config), device_type=device.type,
        torch_version=str(torch.__version__), threads=threads)
    checkpoint = None
    if resume:
        checkpoint = torch.load(run_path / 'last.pt', map_location='cpu', weights_only=True)
        if any(checkpoint.get(k) != v for k, v in expected.items()):
            raise ValueError('Resume requires identical code/data/teacher/config/tokenizer/device/PyTorch/threads')
        if (checkpoint['step'] >= settings['max_steps'] or
                (settings['max_tokens'] and checkpoint['tokens_seen'] >= settings['max_tokens'])):
            raise ValueError('Checkpoint reached its budget; explicitly extend it')
    parent, initial = (load_initialization(init_checkpoint, config, tokenizer, manifest, init_data)
                       if init_checkpoint is not None else (None, None))
    model = CharacterLM(config['model'], tokenizer.active_ids).to(device)
    if parent is not None:
        model.load_state_dict(parent['model'])
        del parent
    if check_only:
        return dict(stage=stage, training_started=False, initial_checkpoint=initial,
                    dataset_id=manifest['dataset_id'], training_data_id=training_data_id,
                    train_pools=len(datasets['train']), validation_pools=len(datasets['validation']),
                    max_steps=settings['max_steps'], training_objective=training_objective(config))
    optimizer = torch.optim.AdamW(model.parameters(), lr=settings['learning_rate'],
                                  betas=(0.9, 0.95), weight_decay=settings['weight_decay'])
    step = epoch = cursor = tokens_seen = 0
    best = float('inf')
    if checkpoint:
        model.load_state_dict(checkpoint['model'])
        optimizer.load_state_dict(checkpoint['optimizer'])
        step, epoch, cursor, tokens_seen, best = (checkpoint[k] for k in
            ('step', 'epoch', 'cursor', 'tokens_seen', 'best_validation_loss'))
        initial = checkpoint.get('initial_checkpoint')
        random.setstate(checkpoint['python_rng'])
        torch.set_rng_state(checkpoint['torch_rng'])
        if device.type == 'mps':
            torch.mps.set_rng_state(checkpoint['accelerator_rng'])
        elif device.type == 'cuda':
            torch.cuda.set_rng_state_all(checkpoint['accelerator_rng'])
        del checkpoint
    else:
        run_path.mkdir(parents=True)
        write_json(run_path / 'run.json', dict(**expected, config=config, teacher=teacher,
            initial_checkpoint=initial, model=parameter_report(config['model']), sources=manifest['sources']))

    def save(name):
        accelerator_rng = (torch.mps.get_rng_state() if device.type == 'mps' else
                           torch.cuda.get_rng_state_all() if device.type == 'cuda' else None)
        atomic_checkpoint(run_path / name, dict(**expected, config=config, tokenizer=tokenizer.to_dict(),
            teacher=teacher, initial_checkpoint=initial, model=model.state_dict(), optimizer=optimizer.state_dict(),
            step=step, epoch=epoch, cursor=cursor, tokens_seen=tokens_seen, best_validation_loss=best,
            python_rng=random.getstate(), torch_rng=torch.get_rng_state(), accelerator_rng=accelerator_rng))

    if not resume:
        save('last.pt')
    model.train()
    training = datasets['train']
    order = None
    while step < settings['max_steps'] and (not settings['max_tokens'] or tokens_seen < settings['max_tokens']):
        batches = []
        for _ in range(settings['gradient_accumulation']):
            if cursor >= len(training):
                epoch += 1
                cursor = 0
                order = None
            if order is None:
                order = torch.randperm(len(training), generator=torch.Generator().manual_seed(config['seed'] + epoch))
            end = min(len(training), cursor + settings['batch_size'])
            batches.append(order[cursor:end].tolist())
            cursor = end
        count = (sum(training.target_count(batch) for batch in batches) if stage == 'pretrain'
                 else sum(map(len, batches)))
        optimizer.zero_grad(set_to_none=True)
        rate = learning_rate(step + 1, settings)
        for group in optimizer.param_groups:
            group['lr'] = rate
        loss_sum, target_tokens = 0.0, 0
        for batch in batches:
            if stage == 'pretrain':
                inputs, labels = training.batch(batch, device)
                loss = F.cross_entropy(model(inputs).float().flatten(0, 1), labels.reshape(-1),
                                       ignore_index=PAD, reduction='sum')
                if not torch.isfinite(loss):
                    raise RuntimeError('Nonfinite loss; last complete checkpoint is preserved')
                (loss / count).backward()
                loss_sum += float(loss.detach())
            else:
                for index in batch:
                    row = training[index]
                    loss, _ = pool_loss(model, tokenizer, row, config, device)
                    (loss / count).backward()
                    loss_sum += float(loss.detach())
                    # Actual target-token exposures; observed text participates only with LM weight.
                    if config['scoring'].get('protocol') == APP_PROTOCOL:
                        unique = {c['text'] for c, flag in zip(row['candidates'], row['model_mask'], strict=True) if flag}
                        # The current App protocol forwards only the effective-context
                        # sequence; contextual scoring no longer needs a BOS pass.
                        target_tokens += sum(len(tokenizer.encode(t))-2 for t in unique)
                    else:
                        target_tokens += sum(len(tokenizer.encode(c['text'])) - 2 for c in row['candidates'])
                    if config['distillation']['lm_weight']:
                        target_tokens += len(tokenizer.encode(row['observed_text'])) - 2
        torch.nn.utils.clip_grad_norm_(model.parameters(), settings['gradient_clip'], error_if_nonfinite=True)
        optimizer.step()
        step += 1
        tokens_seen += count if stage == 'pretrain' else target_tokens
        finished = step == settings['max_steps'] or (settings['max_tokens'] and tokens_seen >= settings['max_tokens'])
        record = dict(stage=stage, step=step, epoch=epoch, cursor=cursor, tokens_seen=tokens_seen,
                      loss=loss_sum / count, learning_rate=rate)
        if step % settings['validate_every'] == 0 or finished:
            validation = (validation_loss(model, datasets['validation'], settings['batch_size'], device,
                                          settings['validation_tokens']) if stage == 'pretrain' else
                          validate_distillation(model, tokenizer, datasets['validation'], config, device))
            record['validation'] = validation
            if validation['loss'] < best:
                best = validation['loss']
                save('best.pt')
        with (run_path / 'metrics.jsonl').open('a', encoding='utf-8') as stream:
            stream.write(json.dumps(record, allow_nan=False) + '\n')
        print(json.dumps(record, allow_nan=False), flush=True)
        if step % settings['save_every'] == 0 or finished:
            save('last.pt')
    return dict(stage=stage, step=step, tokens_seen=tokens_seen, best_validation_loss=best)
