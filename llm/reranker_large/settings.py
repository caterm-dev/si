"""Student configuration and experiment identities, independent of existing runs."""

from pathlib import Path
import math

from llm.pinyin_to_text.common import file_hash, fingerprint, read_json, write_json

ROOT = Path(__file__).resolve().parent
REPO = ROOT.parents[1]
SPLITS = ('train', 'validation', 'test')


def load_config(path):
    config = read_json(path)
    if config.get('schema_version') != 1 or type(config.get('seed')) is not int:
        raise ValueError('Expected a schema-1 student configuration and integer seed')
    model, scoring = config['model'], config['scoring']
    for key in ('vocab_size', 'layers', 'width', 'heads', 'feedforward', 'context'):
        if type(model[key]) is not int or model[key] <= 0:
            raise ValueError('Positive integer required: model.' + key)
    if (not 260 <= model['vocab_size'] <= 65536 or model['width'] % model['heads']
            or not 2 <= model['context'] or not 0 <= model['dropout'] < 1):
        raise ValueError('Invalid vocabulary, head width, context or dropout')
    data, training = config['data'], config['training']
    if (data.get('format') != 'reviewed-documents-v1' or type(data['max_document_characters']) is not int
            or data['max_document_characters'] <= 0):
        raise ValueError('Use explicit reviewed documents with a positive size limit')
    for key in ('batch_size', 'gradient_accumulation', 'max_steps', 'schedule_steps', 'warmup_steps',
                'validate_every', 'save_every', 'validation_tokens'):
        if type(training[key]) is not int or training[key] <= 0:
            raise ValueError('Positive integer required: training.' + key)
    if (type(training['max_tokens']) is not int or training['max_tokens'] < 0
            or training['warmup_steps'] >= training['schedule_steps']):
        raise ValueError('Invalid training budget or warmup')
    for key in ('learning_rate', 'weight_decay', 'gradient_clip'):
        value = training[key]
        if (type(value) not in (int, float) or not math.isfinite(value)
                or value < (0 if key == 'weight_decay' else 1e-20)):
            raise ValueError('Invalid optimizer setting: ' + key)
    for key in ('batch_size', 'max_candidates'):
        if type(scoring[key]) is not int or scoring[key] <= 0:
            raise ValueError('Positive integer required: scoring.' + key)
    if (config.get('stage') not in ('pretrain', 'distill') or model['width'] > 2048
            or model['layers'] > 24 or model['feedforward'] > 8192 or model['context'] > 512):
        raise ValueError('Unsupported student stage or Rust model dimensions')
    if scoring['length_penalty'] != 1.0 or not 2 <= scoring['max_candidates'] <= 12:
        raise ValueError('Student uses mean log probability and at most 12 candidates')
    distillation = config['distillation']
    if type(distillation['validation_pools']) is not int or distillation['validation_pools'] <= 0:
        raise ValueError('Positive distillation validation pool budget required')
    for key in ('temperature', 'kd_weight', 'lm_weight', 'label_weight'):
        value = distillation[key]
        if type(value) not in (float, int) or not math.isfinite(value) or value < 0:
            raise ValueError('Invalid distillation setting: ' + key)
    if distillation['temperature'] <= 0 or distillation['kd_weight'] <= 0:
        raise ValueError('Temperature and KD weight must be positive')
    if (type(scoring['context_tokens']) is not int or not 0 <= scoring['context_tokens'] <= 128
            or type(scoring['candidate_tokens']) is not int or not 1 <= scoring['candidate_tokens'] <= 64
            or scoring['context_tokens'] + scoring['candidate_tokens'] > model['context']):
        raise ValueError('Scoring token limits must fit the student window')
    return config


def code_identity():
    # Include every reused implementation without changing old code/resume identities.
    paths = [*ROOT.glob('*.py'), *ROOT.glob('requirements*.txt'),
             *(REPO / 'llm/reranker_small').glob('*.py'),
             *(REPO / 'llm/pinyin_to_text').glob('*.py'),
             REPO / 'llm/export_rust.py', REPO / 'corpus/common.py']
    return fingerprint({str(p.relative_to(REPO)): file_hash(p) for p in sorted(paths)})


def resume_identity(config):
    value = {**config, 'training': dict(config['training'])}
    for key in ('max_steps', 'max_tokens'):
        value['training'].pop(key)
    return fingerprint(value)
