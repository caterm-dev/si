"""Read the local raw files in codemayq's Chinese Chatbot Corpus collection."""

import csv
from itertools import zip_longest
from pathlib import Path

if __package__:
    from .local_sources import fingerprint, local_path
else:
    from local_sources import fingerprint, local_path

SOURCE = 'chinese-chatbot-corpus'
REVISION = '3e1aaf381fc971997a585c2571af050660331f48'
DOUBAN = tuple(f'douban-multiturn-100w/{split}.txt' for split in ('train', 'dev', 'test'))
PTT_V1 = 'ptt-42w/Gossiping-QA-Dataset.txt'
PTT_V2 = 'ptt-77w/Gossiping-QA-Dataset-2_0.csv'
WEIBO = ('weibo-400w/stc_weibo_train_post', 'weibo-400w/stc_weibo_train_response')
FILES = {
    'douban': DOUBAN,
    'ptt': (PTT_V2, PTT_V1),
    'qingyun': ('qingyun-11w/12万对话语料青云库.csv',),
    'subtitle': ('subtitle-useless/dgk_shooter_min.conv',),
    'tieba': ('tieba-305w/tieba.dialogues',),
    'weibo': WEIBO,
    'xiaohuangji': ('xiaohuangji-40w/xiaohuangji50w_nofenci.conv',),
}


def chatbot_snapshot(root):
    chatterbot = sorted(path.relative_to(root).as_posix()
                        for path in root.glob('chatterbot-1k/chinese/*')
                        if path.suffix in ('.yml', '.yaml'))
    datasets = {'chatterbot': chatterbot} if chatterbot else {}
    for dataset, paths in FILES.items():
        present = [name for name in paths if (root / name).exists()]
        if dataset == 'weibo' and present and len(present) != len(paths):
            raise ValueError('Chinese Chatbot Corpus requires both Weibo files')
        if present:
            datasets[dataset] = present[:1] if dataset == 'ptt' else present
    if not datasets:
        raise ValueError('No supported Chinese Chatbot Corpus files in ' + str(root))
    notices = sorted(path.relative_to(root).as_posix()
                     for folder in ('licenses', 'metadata')
                     for path in (root / folder).rglob('*') if path.is_file())
    return {
        'id': SOURCE, 'kind': SOURCE,
        'repository': 'https://github.com/codemayq/chinese-chatbot-corpus',
        'layout_revision': REVISION,
        'datasets': datasets,
        'missing_datasets': sorted(({'chatterbot'} | FILES.keys()) - datasets.keys()),
        'missing_douban_splits': [Path(name).stem for name in DOUBAN if name not in datasets.get('douban', ())],
        'files': [fingerprint(root, name) for names in datasets.values() for name in names],
        'notices': [fingerprint(root, name) for name in notices],
    }


def line_records(dataset, name, handle, counts):
    if name == PTT_V2:
        reader = csv.DictReader(handle, strict=True)
        if not {'question', 'answer'}.issubset(reader.fieldnames or ()):
            raise ValueError('Missing PTT question/answer columns: ' + name)
        for record, row in enumerate(reader, 1):
            if row['question'] is None or row['answer'] is None:
                raise ValueError(f'Incomplete PTT record {record}: {name}')
            counts['records_read'] += 1
            turns = (row['question'], row['answer'])
            if any(turn.strip() in ('沒有資料', '没有资料') for turn in turns):
                counts['excluded_ptt_placeholders'] += 1
                continue
            yield record, None, turns
        return

    conversation, turn = 0, 0
    for line_number, raw in enumerate(handle, 1):
        counts['records_read'] += 1
        line = raw.rstrip('\r\n')
        if not line.strip():
            continue
        if dataset == 'chatterbot':
            # The archive uses block-list YAML. Each top-level item starts a conversation.
            if line.startswith('- - '):
                conversation, turn = line_number, 0
                yield conversation, turn, (line.removeprefix('- - '),)
            elif line.startswith('  - ') and conversation:
                turn += 1
                yield conversation, turn, (line.removeprefix('  - '),)
        elif dataset in ('subtitle', 'xiaohuangji'):
            if line.strip() == 'E':
                conversation, turn = line_number, 0
            elif line.startswith(('M ', 'M\t')):
                text = line[2:].replace('/', '') if dataset == 'subtitle' else line[2:]
                yield conversation, turn, (text,)
                turn += 1
            else:
                counts['skipped_conv_rows'] += 1
        elif dataset == 'douban':
            label, *turns = line.split('\t')
            if label == '0':
                counts['excluded_douban_negatives'] += 1
                continue
            if label != '1' or len(turns) < 2:
                raise ValueError(f'Invalid Douban row {line_number}: {name}')
            yield line_number, None, turns
        elif dataset == 'qingyun':
            turns = line.split('|')
            if len(turns) != 2:
                counts['skipped_qingyun_rows'] += 1
                continue
            yield line_number, None, turns
        else:
            turns = line.split('\t') if dataset == 'ptt' or '\t' in line else line.split()
            if dataset == 'ptt' and any(turn.strip() in ('沒有資料', '没有资料') for turn in turns):
                counts['excluded_ptt_placeholders'] += 1
                continue
            yield line_number, None, turns


def decoded_lines(handle, counts):
    for index, line in enumerate(handle):
        encoding = 'utf-8-sig' if index == 0 else 'utf-8'
        try:
            yield line.decode(encoding)
        except UnicodeDecodeError:
            counts['invalid_utf8_lines'] += 1
            yield line.decode(encoding, errors='replace')


def chatbot_documents(source, root, counts):
    for dataset, names in source['datasets'].items():
        if dataset == 'weibo':
            with local_path(root, names[0]).open('rb') as posts, \
                    local_path(root, names[1]).open('rb') as replies:
                pairs = zip_longest(decoded_lines(posts, counts), decoded_lines(replies, counts))
                for number, lines in enumerate(pairs, 1):
                    if None in lines:
                        raise ValueError(f'Weibo post/reply lengths differ at row {number}')
                    counts['records_read'] += 1
                    for turn, (name, line) in enumerate(zip(names, lines, strict=True)):
                        yield f'{name}/row:{number}', line.rstrip('\r\n'), {
                            'dataset': dataset, 'path': name, 'conversation': number, 'turn': turn,
                            'split': 'train', 'role': ('post', 'response')[turn]}
            continue
        for name in names:
            split = Path(name).stem if dataset == 'douban' else None
            with local_path(root, name).open('rb') as handle:
                lines = decoded_lines(handle, counts)
                for record, first_turn, turns in line_records(dataset, name, lines, counts):
                    for turn, value in enumerate(turns, first_turn or 0):
                        yield f'{name}/record:{record}/turn:{turn}', value, {
                            'dataset': dataset, 'path': name, 'conversation': record,
                            'turn': turn, 'split': split}
