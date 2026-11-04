"""Optional local model adapters; evaluation itself needs only the Python standard library."""

import argparse
import json
from pathlib import Path

from .datasets import digest, load, requests, write_new


def predict_small(identity, cases, checkpoint, device_name='cpu', threads=4):
    import torch
    from llm.reranker_small.runtime import load_checkpoint, rank_candidates, select_device

    if identity['task'] != 'ranking':
        raise ValueError('The small LM scores supplied pools; select ranking')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    payload, model, tokenizer = load_checkpoint(checkpoint, device)
    scoring = payload['config']['scoring']
    predictions = []
    for case in cases:
        result = rank_candidates(model, tokenizer, case['context'], case['candidates'], device,
                                 scoring['batch_size'], scoring['length_penalty'], scoring['max_candidates'])
        predictions.append({'id': case['id'], 'order': result['order'], 'abstained': result['abstained']})
    return {**identity, 'predictor': {
        'name': 'reranker_small', 'checkpoint_sha256': digest(checkpoint),
        'step': payload['step'], 'training_dataset_id': payload['dataset_id'],
        'scoring': scoring, 'device': str(device), 'threads': threads, 'torch_version': str(torch.__version__),
    }, 'predictions': predictions}


def predict_converter(identity, cases, checkpoint, device_name='cpu', threads=4, beam_size=None):
    import torch
    from llm.pinyin_to_text.runtime import candidates, load_checkpoint, select_device

    if identity['task'] not in ('correction', 'pinyin_to_hanzi'):
        raise ValueError('The converter generates text; select correction or pinyin_to_hanzi')
    if any(case['context'] for case in cases):
        raise ValueError('The current converter does not support context')
    torch.set_num_threads(threads)
    device = select_device(device_name)
    payload, model, tokenizer = load_checkpoint(checkpoint, device)
    settings = payload['config']['decoding']
    k = beam_size if beam_size is not None else settings['beam_size']
    if type(k) is not int or not 1 <= k <= 32:
        raise ValueError('beam_size must be between 1 and 32')
    predictions = []
    for case in cases:
        result = candidates(model, tokenizer, case['input'], device, k, settings['length_penalty'])
        # Compare actual model outputs; do not add the engine's literal fallback.
        predictions.append({'id': case['id'], 'outputs': result['model_candidates']})
    return {**identity, 'predictor': {
        'name': 'pinyin_to_text', 'checkpoint_sha256': digest(checkpoint),
        'step': payload['step'], 'training_dataset_id': payload['dataset_id'],
        'beam_size': k, 'length_penalty': settings['length_penalty'],
        'device': str(device), 'threads': threads, 'torch_version': str(torch.__version__),
    }, 'predictions': predictions}


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('adapter', choices=('small', 'converter'))
    parser.add_argument('--task', choices=('ranking', 'correction', 'pinyin_to_hanzi'), required=True)
    parser.add_argument('--suite')
    parser.add_argument('--split', choices=('dev', 'test'), default='test')
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'cuda'), default='cpu')
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--beam-size', type=int)
    args = parser.parse_args()
    try:
        if args.threads <= 0:
            raise ValueError('threads must be positive')
        if args.output.exists():
            raise FileExistsError('Predictions exist; choose --output NEW_PATH')
        if args.adapter == 'small' and args.beam_size is not None:
            raise ValueError('beam-size applies only to the converter')
        identity, rows, _ = load(args.task, args.split, args.suite)
        cases = requests(identity, rows)['cases']
        if args.adapter == 'small':
            result = predict_small(identity, cases, args.checkpoint, args.device, args.threads)
        else:
            result = predict_converter(identity, cases, args.checkpoint, args.device, args.threads, args.beam_size)
        write_new(args.output, result)
        print(json.dumps({'output': str(args.output), 'cases': len(result['predictions'])}))
    except (ValueError, OSError) as error:
        parser.exit(2, str(error) + '\n')


if __name__ == '__main__':
    main()
