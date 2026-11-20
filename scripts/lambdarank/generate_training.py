#!/usr/bin/env python3
"""Materialize a deterministic local LambdaRank query collection."""
import argparse
from collections import Counter
import csv
import json
from pathlib import Path
import random
import re
import shutil
import tempfile

from pipeline import DATA, ROOT, normalized, read_queries, sha, validate_sets, write_json

SEED = 20261120
QUOTAS = {
    'chinese': 47000, 'context': 8000, 'phrase': 11000, 'abbreviation': 7000,
    'separator': 4500, 'alias': 1500, 'missing-key': 3000, 'neighbor-key': 3000,
    'adjacent-swap': 3000, 'english': 2500, 'english-segmentation': 2000,
    'completion': 2500, 'mixed': 5000,
}
FIRST_BATCH = DATA / 'generated/training-100k-v1'
SECOND_BATCH = DATA / 'generated/training-100k-v2'
ZH = ROOT / 'Data/Chinese/base.csv'
EN = ROOT / 'Data/English/base.csv'
VALIDATION = DATA / 'validation.jsonl'
TEST = ROOT / 'eval/ranking/test.jsonl'
HAN = re.compile(r'[\u4e00-\u9fff]{1,12}')
PINYIN = re.compile(r"[a-zü]+(?:'[a-zü]+)*")
ASCII_WORD = re.compile(r'[a-z]{4,18}')
KEYBOARD = ('qwertyuiop', 'asdfghjkl', 'zxcvbnm')
NEIGHBORS = {
    key: ''.join(row[index + delta] for delta in (-1, 1) if 0 <= index + delta < len(row))
    for row in KEYBOARD for index, key in enumerate(row)
}
ENGLISH_SENTENCES = (
    ('please check the', 'before lunch'), ('can we move the', 'to tomorrow'),
    ('remember to update the', 'this week'), ('we should review the', 'together'),
    ('could you send the', 'when ready'), ('we can start the', 'after the meeting'),
    ('can you find the', 'in the folder'), ('let us discuss the', 'after the call'),
)
ADDITIONAL_ENGLISH_SENTENCES = (
    ('who is handling the', 'this month'), ('i am looking for the', 'right now'),
    ('we found the', 'in the shared folder'), ('can you confirm the', 'by friday'),
    ('i cannot open the', 'on this laptop'), ('did you receive the', 'this morning'),
    ('we need a copy of the', 'for next week'), ('where did you save the', 'last night'),
)
ENGLISH_TOPICS = (
    'agenda application appointment archive assignment attachment backup book budget calendar camera '
    'chart checklist contract dataset deadline delivery diagram document draft estimate example file '
    'forecast form folder guide invoice itinerary label layout lesson letter list log manual map '
    'message mockup model note order outline package page payment photo plan policy presentation '
    'proposal receipt record report request revision schedule script shipment specification statement '
    'summary survey table template ticket transcript update video worksheet'
).split()
ENGLISH_DESCRIPTORS = 'annual backup revised draft latest monthly new printed quarterly shared weekly'.split()
MIXED_TERMS = (
    'account address alert annotation archive audit backup benchmark branch buffer build cache calendar '
    'candidate catalog chart checkpoint client cluster command commit compiler component config connection '
    'console context dashboard dataset debugger decoder default deployment diagram dictionary diff directory '
    'document download driver editor encoder endpoint error export extension fallback feature field filter '
    'flag formatter framework function gateway grammar graph header history index interface keyboard label '
    'layout library list locale log manifest mapping message metadata migration model module network note '
    'package page panel parser patch path pipeline plugin preview profile project prompt protocol query '
    'queue reader release report request resource response result router rule runtime schema script search '
    'server session settings shortcut signal snapshot socket source stack status storage stream summary '
    'symbol syntax table tag target task template terminal test text thread token toolbar trace tracker '
    'training transfer trigger update upload user validation variable version viewer window worker'
).split()
MIXED_LEFT = (
    ('检查', 'jiancha'), ('更新', 'gengxin'), ('删除', 'shanchu'), ('修改', 'xiugai'),
    ('读取', 'duqu'), ('打开', 'dakai'), ('保存', 'baocun'), ('搜索', 'sousuo'),
    ('请检查', 'qingjiancha'), ('先确认', 'xianqueren'), ('需要更新', 'xuyaogengxin'),
    ('重新加载', 'chongxinjiazai'), ('复制', 'fuzhi'), ('查看', 'chakan'),
    ('我想检查', 'woxiangjiancha'), ('帮我打开', 'bangwodakai'),
)
ADDITIONAL_MIXED_LEFT = (
    ('导出', 'daochu'), ('上传', 'shangchuan'), ('下载', 'xiazai'), ('找一下', 'zhaoyixia'),
    ('对比一下', 'duibiyixia'), ('帮我确认', 'bangwoqueren'), ('请检查一下', 'qingjianchayixia'),
    ('我想修改', 'woxiangxiugai'), ('先备份', 'xianbeifen'), ('试着打开', 'shizhedakai'),
    ('准备迁移', 'zhunbeiqianyi'), ('需要重建', 'xuyaochongjian'),
)
MIXED_RIGHT = (
    ('', ''), ('的设置', 'deshezhi'), ('的位置', 'deweizhi'), ('的状态', 'dezhuangtai'),
    ('的说明', 'deshuoming'), ('是否可用', 'shifoukeyong'), ('是否存在', 'shifoucunzai'),
)
MIXED_CONTEXTS = ('刚才修改了一遍。', '先核对一下当前版本。', '这个问题需要再确认。')
CHINESE_DOCUMENTS = (
    '工作报告 项目计划 测试报告 会议纪要 需求文档 会议记录 设计方案 测试计划 发布公告 操作手册 版本说明 '
    '接口文档 故障报告 评审意见 工作总结 采购清单 交接清单 培训计划 考勤记录 变更记录 巡检记录 '
    '调查报告 统计报表 任务清单 风险评估 绩效报告 进度报告 周报 月报 简报 报名表 申请表 登记表 审批表 '
    '预算表 报销单 付款单 订单 合同 协议 草稿 提案 说明书 产品介绍 维护手册 操作指南 使用指南 '
    '用户协议 问题清单 问卷调查 操作记录 交付清单 数据字典 文件目录 更新日志 配置文件 归档文件 '
    '验收报告 验收标准 验收记录 项目方案 应急预案 预算方案 研究报告 分析报告 评估报告 复盘报告 '
    '审批记录 审核记录 出差申请 市场报告 销售报表 财务报表 资源清单 文档模板 开发计划 部署方案 '
    '技术文档 反馈意见 基础资料 说明文件 会议议程 需求清单 项目清单 审查意见 修订记录 交付文档'
).split()
CHINESE_MODIFIERS = (
    ('最新的', 'zuixinde'), ('上次的', 'shangcide'), ('修订后的', 'xiudinghoude'),
    ('刚收到的', 'gangshoudaode'), ('上周的', 'shangzhoude'), ('整理过的', 'zhengliguode'),
    ('存档的', 'cundangde'), ('原来的', 'yuanlaide'), ('准备好的', 'zhunbeihaode'),
    ('已经审核的', 'yijingshenhede'),
)
CHINESE_DOCUMENT_FRAMES = (
    ('请把', 'qingba', '发给我', 'fageiwo'),
    ('请把', 'qingba', '放进共享文件夹', 'fangjingongxiangwenjianjia'),
    ('我们明天讨论', 'womenmingtiantaolun', '', ''),
    ('我想再看一遍', 'woxiangzaikanyibian', '', ''),
    ('帮我找一下', 'bangwozhaoyixia', '', ''),
    ('我们需要重新核对', 'womenxuyaochongxinhedui', '', ''),
    ('我下午会整理', 'woxiawuhuizhengli', '', ''),
    ('请先确认', 'qingxianqueren', '有没有缺页', 'youmeiyouqueye'),
    ('记得保存', 'jidebaocun', '的副本', 'defuben'),
    ('会议结束后记得提交', 'huiyijieshuhoujidetijiao', '', ''),
    ('临走前请备份', 'linzouqianqingbeifen', '', ''),
    ('你能先发一下', 'ninengxianfayixia', '吗', 'ma'),
    ('请把', 'qingba', '送到会议室', 'songdaohuiyishi'),
    ('请打印一份', 'qingdayinyifen', '备用', 'beiyong'),
)
CHINESE_ACTIONS = (
    ('核对', 'hedui', '几份资料还没确认。'), ('补齐', 'buqi', '有些材料还不完整。'),
    ('更新', 'gengxin', '刚刚调整了项目安排。'), ('归档', 'guidang', '项目已经结项。'),
    ('检查', 'jiancha', '交付之前还要复核一遍。'), ('整理', 'zhengli', '这批资料有点乱。'),
    ('复制', 'fuzhi', '下次可能还会用到旧版本。'), ('重看', 'chongkan', '讨论中有几处遗漏。'),
)
CHINESE_ACTION_ENDS = (
    ('以后再发给负责人', 'yihouzaifageifuzeren'), ('以后先发到群里', 'yihouxianfadaoqunli'),
    ('再通知大家', 'zaitongzhidajia'), ('之后发我一份', 'zhihoufawoyifen'),
    ('再发给项目组', 'zaifageixiangmuzu'), ('以后再做决定', 'yihouzaizuojieding'),
    ('后发到共享目录', 'houfadaogongxiangmulu'), ('后发给值班同事', 'houfageizhibantongshi'),
    ('然后安排评审', 'ranhouanpaipingshen'), ('后及时通知我', 'houjishitongzhiwo'),
    ('后再安排下一步', 'houzaianpaixiayibu'), ('之前先和我确认', 'zhiqianxianhewoqueren'),
    ('完成后发到邮箱', 'wanchenghoufadaoyouxiang'), ('后记得给我留言', 'houjidegeiwoliuyan'),
)


def vocabulary():
    chinese, english = {}, {}
    with ZH.open(encoding='utf-8', newline='') as stream:
        for row in csv.DictReader(stream):
            target, reading, weight = row['text'], row['reading'].replace('v', 'ü'), int(row['weight'])
            if HAN.fullmatch(target) and PINYIN.fullmatch(reading) and weight > 0:
                parts = tuple(reading.split("'"))
                if len(parts) == len(target):
                    key = target, parts
                    chinese[key] = max(chinese.get(key, 0), weight)
    with EN.open(encoding='utf-8', newline='') as stream:
        for row in csv.DictReader(stream):
            target, spelling, weight = row['text'], row['reading'], int(row['weight'])
            if ASCII_WORD.fullmatch(spelling) and target.lower() == spelling and weight > 0:
                previous = english.get(spelling)
                if previous is None or (weight, target) > previous:
                    english[spelling] = weight, target
    ranked = sorted(chinese, key=lambda key: (-chinese[key], key))
    words = sorted(english.items(), key=lambda pair: (-pair[1][0], pair[0]))
    return chinese, ranked, words


def corrupt(spelling, kind, rng):
    positions = list(range(1, len(spelling) - 1))
    rng.shuffle(positions)
    for index in positions:
        head, key, tail = spelling[:index], spelling[index], spelling[index + 1:]
        if kind == 'missing-key':
            yield head + tail
        elif kind == 'neighbor-key':
            for replacement in NEIGHBORS.get(key, ''):
                yield head + replacement + tail
        elif key != tail[0]:
            yield head + tail[0] + key + tail[1:]


def document_scenarios(ranked, rng):
    documents = {}
    subjects = set(CHINESE_DOCUMENTS)
    for word, parts in ranked:
        if word in subjects:
            documents.setdefault(word, ''.join(parts))
    phrases = [
        (left + modifier + word + right, first + modifier_keys + keys + last)
        for left, first, right, last in CHINESE_DOCUMENT_FRAMES
        for modifier, modifier_keys in CHINESE_MODIFIERS for word, keys in documents.items()
    ]
    contexts = [
        (action + word + end, first + keys + last, context)
        for action, first, context in CHINESE_ACTIONS for end, last in CHINESE_ACTION_ENDS
        for word, keys in documents.items()
    ]
    rng.shuffle(phrases)
    rng.shuffle(contexts)
    return phrases, contexts


def generate(validation, test, previous=()):
    rng = random.Random(SEED + bool(previous))
    lexicon, ranked, english = vocabulary()
    excluded = [*validation, *test, *previous]
    blocked_input = {normalized(row['input']) for row in excluded}
    blocked_target = {normalized(ref) for row in excluded for ref in row['references']}
    cases, used_targets, requests = [], set(), set()
    counts = Counter()

    def add(kind, source, target, **metadata):
        if counts[kind] >= QUOTAS[kind]:
            return False
        key = normalized(target)
        request = source, metadata.get('context', ''), tuple(metadata.get('languages', ('zh-Hans', 'en')))
        if (normalized(source) in blocked_input or key in blocked_target or key in used_targets
                or request in requests):
            return False
        row = {'input': source, 'references': [target], **metadata}
        if kind != 'chinese':
            row['category'] = 'pinyin-correction' if kind in ('missing-key', 'neighbor-key', 'adjacent-swap') else kind
        counts[kind] += 1
        used_targets.add(key)
        requests.add(request)
        cases.append((kind, row))
        return True

    spelling_counts = Counter(''.join(parts) for _, parts in ranked)
    first_homophone = {}
    for target, parts in ranked:
        first_homophone.setdefault(''.join(parts), target)
    for target, parts in ranked:
        if counts['context'] == QUOTAS['context']:
            break
        for size in (3, 2, 4, 5):
            if len(target) < size + 2:
                continue
            before, after = target[:-size], target[-size:]
            suffix = parts[-size:]
            if (before, parts[:-size]) not in lexicon or (after, suffix) not in lexicon:
                continue
            source = ''.join(suffix)
            if spelling_counts[source] > 1 and add('context', source, after, context=before):
                break

    edit_kinds = ('missing-key', 'neighbor-key', 'adjacent-swap')
    for target, parts in ranked:
        if not 2 <= len(parts) <= 4 or 'ü' in ''.join(parts):
            continue
        spelling = ''.join(parts)
        for kind in sorted(edit_kinds, key=counts.__getitem__):
            if counts[kind] < QUOTAS[kind]:
                for typo in corrupt(spelling, kind, rng):
                    if add(kind, typo, target):
                        break
                else:
                    continue
                break
        if all(counts[kind] == QUOTAS[kind] for kind in edit_kinds):
            break

    for target, parts in ranked:
        spelling = ''.join(parts)
        if 'ü' in spelling and len(parts) > 1:
            alias = ('v', 'u:', 'ü')[counts['alias'] % 3]
            add('alias', spelling.replace('ü', alias), target)
    for target, parts in ranked:
        if 2 <= len(parts) <= 5:
            source = "'".join(parts) + ("'" if counts['separator'] % 5 == 0 else '')
            add('separator', source, target, syllable_paths=[' '.join(source.rstrip("'").split("'"))])
        if 2 <= len(parts) <= 4:
            mode = counts['abbreviation'] % 3
            short = ''.join(s if (mode == 1 and index == len(parts) - 1)
                            or (mode == 2 and index == 0) else s[0]
                            for index, s in enumerate(parts))
            if short != ''.join(parts):
                add('abbreviation', short, target)
        if len(parts) >= 6:
            add('phrase', ''.join(parts), target)

    if previous:
        document_phrases, document_contexts = document_scenarios(ranked, rng)
        for target, source in document_phrases:
            add('phrase', source, target)
            if counts['phrase'] == QUOTAS['phrase']:
                break
        for target, source, context in document_contexts:
            add('context', source, target, context=context)
            if counts['context'] == QUOTAS['context']:
                break

    mixed_left = ADDITIONAL_MIXED_LEFT + MIXED_LEFT if previous else MIXED_LEFT
    mixed = [
        (before + token + after, f'{left} {token}' + (f' {right}' if right else ''), token)
        for left, before in mixed_left for token in MIXED_TERMS for right, after in MIXED_RIGHT
    ]
    rng.shuffle(mixed)
    for index, (source, target, token) in enumerate(mixed):
        metadata = {'context': rng.choice(MIXED_CONTEXTS)} if index % 4 == 0 else {}
        if index % 11 == 0:
            metadata['prior_choices'] = [{'text': token, 'language': 'en', 'token_spelling': token,
                                           'bonus': 1 + index % 8}]
        add('mixed', source, target, **metadata)
        if counts['mixed'] == QUOTAS['mixed']:
            break

    english_sentences = ADDITIONAL_ENGLISH_SENTENCES if previous else ENGLISH_SENTENCES
    phrases = [
        f'{start} {descriptor} {topic} {end}'
        for start, end in english_sentences for descriptor in ENGLISH_DESCRIPTORS for topic in ENGLISH_TOPICS
    ]
    rng.shuffle(phrases)
    for index, phrase in enumerate(phrases[:QUOTAS['english-segmentation'] * 2]):
        context = ('Thanks for the update.', 'Here is the next step.')[index % 2]
        add('english-segmentation', phrase.replace(' ', ''), phrase,
            languages=['en'], **({'context': context} if index % 5 == 0 else {}))
        if counts['english-segmentation'] == QUOTAS['english-segmentation']:
            break

    for spelling, (_, target) in english:
        if len(spelling) >= 6:
            prefix = spelling[:-(1 + counts['completion'] % 3)]
            add('completion', prefix, target, languages=['en'])
        if counts['completion'] == QUOTAS['completion']:
            break
    for spelling, (_, target) in english:
        add('english', spelling, target, **({'languages': ['en']} if counts['english'] % 2 else {}))
        if counts['english'] == QUOTAS['english']:
            break

    lengths = Counter()
    length_limits = (0, 25000, 14500, 7500) if previous else (400, 27000, 13100, 6500)
    for target, parts in ranked:
        length = len(parts)
        if length not in (1, 2, 3, 4) or lengths[length] >= length_limits[length - 1]:
            continue
        metadata = {}
        index = counts['chinese']
        if index % 9 == 0:
            metadata['languages'] = ['zh-Hans']
        if index % 23 == 0:
            metadata['context_available'] = True
        if index % 31 == 0 and spelling_counts[''.join(parts)] > 1:
            previous = first_homophone[''.join(parts)]
            metadata['prior_choices'] = [{'text': previous, 'language': 'zh-Hans', 'bonus': 1 + index % 8}]
        if add('chinese', ''.join(parts), target, **metadata):
            lengths[length] += 1
        if counts['chinese'] == QUOTAS['chinese']:
            break

    if counts != QUOTAS:
        raise ValueError(f'Quotas not met: {dict(counts)}')
    rng.shuffle(cases)
    return cases


def append_training_batches(destination, previous, additional):
    with destination.open('wb') as stream:
        with previous.open('rb') as source:
            source.seek(-1, 2)
            final = source.read(1)
            source.seek(0)
            shutil.copyfileobj(source, stream)
            if final != b'\n':
                stream.write(b'\n')
        with additional.open('rb') as source:
            shutil.copyfileobj(source, stream)


def build(output, previous_path=None):
    if output.exists():
        raise ValueError('Use a new output directory')
    paths = [ZH, EN, VALIDATION, TEST, Path(__file__)]
    if previous_path is not None:
        paths.append(previous_path.resolve())
    hashes = {path: sha(path) for path in paths}
    validation, test = read_queries(VALIDATION), read_queries(TEST)
    previous = read_queries(previous_path) if previous_path is not None else []
    if previous_path is not None:
        validate_sets(previous, validation, test)
    cases = generate(validation, test, previous)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='.rank-data-', dir=output.parent) as temp:
        stage = Path(temp) / 'collection'
        stage.mkdir(mode=0o700)
        train = stage / 'train.jsonl'
        with train.open('w', encoding='utf-8') as stream:
            for _, row in cases:
                stream.write(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n')
        rows = read_queries(train)
        splits = validate_sets(rows, validation, test)
        expansion = {}
        if previous_path is not None:
            validate_sets(previous, rows, validation + test)
            combined_splits = validate_sets(previous + rows, validation, test)
            combined = stage / 'train-combined.jsonl'
            append_training_batches(combined, previous_path, train)
            expansion = {'previous_train_sha256': hashes[previous_path.resolve()],
                         'combined': {'file': combined.name, 'splits': combined_splits,
                                      'sha256': sha(combined)}}
        if any(sha(path) != checksum for path, checksum in hashes.items()):
            raise ValueError('A generation resource changed')
        write_json(stage / 'manifest.json', {
            'seed': SEED + bool(previous), 'splits': splits,
            'train_cases': dict(Counter(kind for kind, _ in cases)),
            'source_sha256': {str(path.relative_to(ROOT) if path.is_relative_to(ROOT) else path): checksum
                              for path, checksum in hashes.items()},
            'train_sha256': sha(train),
            'with_preceding_text': sum(bool(row['context']) for row in rows),
            'known_field_start': sum(row.get('context_available') is True and not row['context'] for row in rows),
            'with_synthetic_prior_choices': sum(bool(row.get('prior_choices')) for row in rows),
            'language_configurations': dict(Counter(','.join(row['languages']) for row in rows)),
            'provenance': [
                'Chinese and English base dictionaries derived from maintained Wanxiang vocabulary (CC BY 4.0).',
                'SI-authored sentence templates, spelling transformations, and synthetic choice observations.',
                'No live history or user profile was consulted in generating this input dataset.',
            ],
            'notices': ['mac/SI/Core/Resources/Chinese/NOTICE.txt',
                        'mac/SI/Core/Resources/English/Wanxiang-NOTICE.txt',
                        'mac/SI/Core/Resources/English/Wanxiang-CC-BY-4.0.txt'],
            **expansion,
        })
        if output.exists():
            raise ValueError('Use a new output directory')
        stage.rename(output)
    print(json.dumps({'output': str(output), 'cases': splits['train'], 'sha256': sha(output / 'train.jsonl')}))


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--extend', type=Path, help='Previous training JSONL to exclude and combine')
    parser.add_argument('--output', type=Path)
    args = parser.parse_args()
    try:
        build(args.output or (SECOND_BATCH if args.extend else FIRST_BATCH), args.extend)
    except (OSError, ValueError) as error:
        parser.exit(1, f'{error}\n')
