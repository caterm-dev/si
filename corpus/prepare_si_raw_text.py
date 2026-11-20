#!/usr/bin/env python3
"""Prepare the local dialogue, Chinese Chatbot Corpus and SI text collections."""

import argparse
from pathlib import Path

if __package__:
    from .chatbot_sources import SOURCE as CHATBOT
    from .common import CHINESE
    from .prepare_raw_text import extract, local_snapshot
else:
    from chatbot_sources import SOURCE as CHATBOT
    from common import CHINESE
    from prepare_raw_text import extract, local_snapshot


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--raw-root', type=Path, default=CHINESE / 'raw',
                        help='raw collections directory (default: corpus/chinese/raw)')
    parser.add_argument('--output', type=Path, default=CHINESE / 'prepared/si-corpus',
                        help='prepared collections directory (default: corpus/chinese/prepared/si-corpus)')
    args = parser.parse_args()

    chatbot_root = args.raw_root / CHATBOT
    if not chatbot_root.exists():
        chatbot_root = args.raw_root / 'chinese-corpus'
    sources = (
        ('dialogue', 'dialogue', args.raw_root / 'dialogue'),
        ('chinese-corpus', CHATBOT, chatbot_root),
        ('si', 'si', args.raw_root / 'si'),
    )
    for _, _, root in sources:
        if not root.is_dir():
            parser.error(f'Missing raw source directory: {root}')

    for name, kind, root in sources:
        print(f'Preparing {name} from {root}', flush=True)
        extract(local_snapshot(kind, root), root, args.output / name)


if __name__ == '__main__':
    main()
