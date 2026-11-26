"""One explicitly invoked stage at a time; ordinary commands never install/download."""

import argparse
import json
import os
from pathlib import Path

from .settings import ROOT, load_config


def main():
    experiment = os.environ.get('SI_RERANKER_LARGE_EXPERIMENT', 'student-15m-v1')
    def path(name, default):
        return Path(os.environ.get('SI_RERANKER_LARGE_' + name, str(default)))
    data = path('DATA', ROOT / 'data/prepared' / experiment / 'lm')
    pools = path('POOLS', ROOT / 'data/prepared' / experiment / 'pools')
    teacher_data = path('TEACHER_DATA', ROOT / 'data/prepared' / experiment / 'teacher')
    runs = path('RUN_ROOT', ROOT / 'runs' / experiment)
    reports = path('REPORT_ROOT', ROOT / 'reports' / experiment)
    configs = {stage: path(stage.upper() + '_CONFIG', ROOT / f'configs/{stage}.json')
               for stage in ('pretrain', 'distill')}
    parser = argparse.ArgumentParser(description=__doc__)
    commands = parser.add_subparsers(dest='command', required=True)
    for command in ('size', 'data', 'prepare-data', 'pools', 'teacher', 'pretrain', 'distill', 'resume',
                    'validation', 'test', 'evaluate', 'rank', 'export', 'benchmark'):
        sub = commands.add_parser(command)
        if command in ('size', 'data', 'prepare-data', 'pools', 'teacher', 'pretrain', 'distill', 'resume'):
            sub.add_argument('--config', type=Path)
        if command not in ('size', 'prepare-data', 'rank', 'benchmark'):
            sub.add_argument('--data', type=Path, default=data)
        if command in ('size', 'data', 'prepare-data', 'pools', 'teacher'):
            default_stage = 'pretrain'
        else:
            default_stage = 'distill'
        sub.set_defaults(default_stage=default_stage)
        if command in ('data', 'pools'):
            sub.add_argument('--provenance', type=Path, required=True)
            sub.add_argument('--documents' if command == 'data' else '--records', type=Path, required=True)
            sub.add_argument('--output', type=Path, default=data if command == 'data' else pools)
        if command == 'prepare-data':
            sub.add_argument('--prepared-root', type=Path, default=ROOT.parents[1] / 'corpus/chinese/prepared/raw-text-v2')
            sub.add_argument('--dialogue-root', type=Path,
                             help='Override dialogue only with a complete matching manifest/text/metadata snapshot')
            sub.add_argument('--notices-root', type=Path, default=ROOT.parents[1] / 'corpus/chinese')
            sub.add_argument('--mixture-config', type=Path, default=ROOT / 'configs/corpus.json')
            sub.add_argument('--train-tokens', type=int, help='Override the training target-token sampling budget')
            sub.add_argument('--allow-shortfall', action='store_true', help='Explicitly retain undersized source/split quotas')
            sub.add_argument('--output', type=Path, default=data)
        if command in ('teacher', 'distill', 'resume', 'evaluate', 'export'):
            sub.add_argument('--pools', type=Path, default=pools if command == 'teacher' else teacher_data)
        if command == 'teacher':
            sub.add_argument('--model', type=Path, required=True, help='Existing local Qwen2.5-0.5B Base snapshot')
            sub.add_argument('--output', type=Path, default=teacher_data)
        if command in ('pretrain', 'distill', 'resume'):
            sub.add_argument('--run', type=Path)
            sub.add_argument('--max-steps', type=int)
            sub.add_argument('--max-tokens', type=int)
        if command == 'distill':
            sub.add_argument('--init-checkpoint', type=Path, default=runs / 'pretrain/best.pt')
        if command == 'resume':
            sub.add_argument('--stage', choices=('pretrain', 'distill'), required=True)
        if command in ('validation', 'test', 'evaluate', 'rank', 'export', 'benchmark'):
            sub.add_argument('--checkpoint', type=Path, default=path('CHECKPOINT', runs / 'distill/best.pt'))
        if command in ('validation', 'test', 'evaluate', 'export', 'benchmark'):
            sub.add_argument('--output', type=Path, default=(
                path('EXPORT', ROOT / 'exports' / experiment) if command == 'export' else reports / f'{command}.json'))
        if command == 'evaluate':
            sub.add_argument('--split', choices=('validation', 'test'), default='validation')
        if command == 'rank':
            sub.add_argument('--context', default='')
            sub.add_argument('--candidate', action='append', required=True)
            sub.add_argument('--language', choices=('zh-Hans', 'en', 'mixed'), default='zh-Hans')
            sub.add_argument('--input', help='Exact spelling retained separately as the literal action')
        if command == 'benchmark':
            sub.add_argument('--binary', type=Path, default=Path('target/release/si-neural'))
            sub.add_argument('--bundle', type=Path, default=path('EXPORT', ROOT / 'exports' / experiment) / 'rust')
            sub.add_argument('--repeats', type=int, default=40)
        if command not in ('size', 'data', 'prepare-data', 'pools', 'export'):
            if command != 'benchmark':
                sub.add_argument('--device', choices=('cpu', 'mps', 'cuda', 'auto'), default='mps')
            sub.add_argument('--threads', type=int, default=4)
    args = parser.parse_args()
    command = args.command
    stage = args.stage if command == 'resume' else (command if command in configs else args.default_stage)
    config_path = getattr(args, 'config', None) or configs[stage]
    if command == 'size':
        from llm.reranker_small.model import parameter_report
        result = parameter_report(load_config(config_path)['model'])
    elif command == 'data':
        from .prepare import prepare_documents
        result = prepare_documents(config_path, args.documents, args.provenance, args.output)
    elif command == 'prepare-data':
        from .corpus_data import prepare_corpus
        manifest = prepare_corpus(config_path, args.mixture_config, args.prepared_root,
            args.notices_root, args.output, train_tokens=args.train_tokens, allow_shortfall=args.allow_shortfall,
            dialogue_root=args.dialogue_root)
        result = dict(dataset_id=manifest['dataset_id'], output=str(args.output), splits=manifest['splits'],
                      sampling_report=str(args.output / 'sampling-report.json'))
    elif command == 'pools':
        from .prepare import prepare_pools
        result = prepare_pools(config_path, args.data, args.records, args.provenance, args.output)
    elif command == 'teacher':
        from .teacher import QwenTeacher, cache_teacher
        result = cache_teacher(config_path, args.data, args.pools, args.output,
                               QwenTeacher(args.model, args.device, args.threads))
    elif command in ('pretrain', 'distill', 'resume'):
        from .train import train
        if load_config(config_path)['stage'] != stage:
            raise ValueError('Selected command/stage conflicts with configuration')
        result = train(config_path, args.data, args.run or runs / stage, args.device,
            pools_path=args.pools if stage == 'distill' else None,
            init_checkpoint=args.init_checkpoint if command == 'distill' else None,
            resume=command == 'resume', max_steps=args.max_steps, max_tokens=args.max_tokens, threads=args.threads)
    elif command in ('validation', 'test'):
        from llm.reranker_small.evaluate import evaluate
        result = evaluate(args.checkpoint, args.data, args.output,
                          'test' if command == 'test' else 'validation', args.device, threads=args.threads)
    elif command == 'evaluate':
        from .evaluate import evaluate
        result = evaluate(args.checkpoint, args.data, args.pools, args.output, args.split, args.device, args.threads)
    elif command == 'rank':
        import torch
        from llm.reranker_small.runtime import load_checkpoint, select_device
        from .evaluate import predict
        if args.threads <= 0:
            raise ValueError('Threads must be positive')
        torch.set_num_threads(args.threads)
        device = select_device(args.device)
        checkpoint, model, tokenizer = load_checkpoint(args.checkpoint, device)
        row = dict(context=args.context, candidates=[dict(text=c, language=args.language) for c in args.candidate],
                   observed_text=args.candidate[0])
        result = (predict(model, tokenizer, row, checkpoint['config'], device) if args.input != '' else
                  dict(scores=[], order=[], abstained=False, context_tokens_used=0))
        result['candidates'] = row['candidates'] if args.input != '' else []
        result['literal'] = args.input
    elif command == 'export':
        from .export import export
        result = export(args.checkpoint, args.data, args.output, args.pools)
    else:
        from .evaluate import rust_check
        result = rust_check(args.checkpoint, args.bundle, args.binary, args.output, args.repeats, args.threads)
    print(json.dumps(result, ensure_ascii=False, indent=2, allow_nan=False))


if __name__ == '__main__':
    main()
