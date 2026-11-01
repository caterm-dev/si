"""Score explicit candidate text; never generate replacement text or Pinyin output."""

import argparse
import json
from pathlib import Path

import torch

from .runtime import load_checkpoint, rank_candidates, select_device


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--checkpoint', required=True, type=Path)
    parser.add_argument('--context', default='')
    parser.add_argument('--candidate', action='append', default=[])
    parser.add_argument('--input', help='Optional original spelling, retained as an explicit final literal choice')
    parser.add_argument('--device', choices=('auto', 'cpu', 'mps', 'cuda'), default='mps')
    parser.add_argument('--threads', type=int, default=4)
    parser.add_argument('--length-penalty', type=float)
    args = parser.parse_args()
    if args.threads <= 0:
        parser.error('--threads must be positive')
    torch.set_num_threads(args.threads)
    device = select_device(args.device)
    checkpoint, model, tokenizer = load_checkpoint(args.checkpoint, device)
    settings = checkpoint['config']['scoring']
    # Literal text is a separate action, not a language-model hypothesis.
    candidates = [text for text in args.candidate if args.input is None or text != args.input]
    if args.input == '':
        result = {'order': [], 'scores': [], 'abstained': False}
        candidates = []
    else:
        result = rank_candidates(model, tokenizer, args.context, candidates, device,
                                 settings['batch_size'], settings['length_penalty'] if args.length_penalty is None
                                 else args.length_penalty, settings['max_candidates'])
    ordered = [candidates[index] for index in result['order']]
    if args.input:
        ordered.append(args.input)
    print(json.dumps({'candidates': ordered, 'model_candidates': candidates, **result}, ensure_ascii=False, indent=2))


if __name__ == '__main__':
    main()
