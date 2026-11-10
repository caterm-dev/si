#!/usr/bin/env python3
"""Build/check SI's authored ranking queries without reading an engine or old suite."""

import argparse
from collections import Counter
from dataclasses import dataclass
import hashlib
import json
from pathlib import Path
import random
import re

ROOT = Path(__file__).resolve().parents[1]
DESTINATION = ROOT / 'eval/ranking'
SEED = 20261109
COUNT = 120
MAX_PER_FAMILY = 2


@dataclass(frozen=True)
class Fragment:
    text: str
    syllables: tuple[str, ...]


def fragments(source):
    result = []
    for item in source.split(';'):
        text, reading = item.strip().split('=', 1)
        syllables = tuple(reading.split())
        if len(text) != len(syllables) or any(not re.fullmatch('[a-zv]+', s) for s in syllables):
            raise ValueError('Invalid authored fragment: ' + item)
        result.append(Fragment(text, syllables))
    return result


def fragment(source):
    return fragments(source)[0]


ACTORS = fragments('我=wo;我们=wo men;你们=ni men;大家=da jia;朋友们=peng you men;同事们=tong shi men;他们=ta men;家人们=jia ren men')
TIMES = fragments('今天=jin tian;明天=ming tian;下周=xia zhou;周末=zhou mo;今天上午=jin tian shang wu;明天下午=ming tian xia wu;下个月=xia ge yue;这周五=zhe zhou wu')
DAILY = fragments('早餐=zao can;午饭=wu fan;晚饭=wan fan;面条=mian tiao;饺子=jiao zi;米饭=mi fan;牛肉面=niu rou mian;蔬菜汤=shu cai tang;水果沙拉=shui guo sha la;南瓜粥=nan gua zhou;小米粥=xiao mi zhou;番茄鸡蛋面=fan qie ji dan mian')
HOME = fragments('书房=shu fang;客厅=ke ting;厨房=chu fang;卧室=wo shi;阳台=yang tai;餐厅=can ting;储物间=chu wu jian;走廊=zou lang')
ITEMS = fragments('书架=shu jia;桌子=zhuo zi;椅子=yi zi;窗帘=chuang lian;地毯=di tan;台灯=tai deng;沙发=sha fa;衣柜=yi gui;鞋柜=xie gui;茶几=cha ji')
DOCS = fragments('项目说明=xiang mu shuo ming;会议记录=hui yi ji lu;需求文档=xu qiu wen dang;设计方案=she ji fang an;测试计划=ce shi ji hua;发布公告=fa bu gong gao;操作手册=cao zuo shou ce;版本说明=ban ben shuo ming;接口文档=jie kou wen dang;故障报告=gu zhang bao gao;评审意见=ping shen yi jian;工作总结=gong zuo zong jie')
TEAM = fragments('研发团队=yan fa tuan dui;测试团队=ce shi tuan dui;设计团队=she ji tuan dui;运营团队=yun ying tuan dui;项目经理=xiang mu jing li;产品经理=chan pin jing li;值班同事=zhi ban tong shi;技术负责人=ji shu fu ze ren')
TECH = fragments('候选列表=hou xuan lie biao;拼音解析器=pin yin jie xi qi;缓存模块=huan cun mo kuai;日志模块=ri zhi mo kuai;查询接口=cha xun jie kou;排序算法=pai xu suan fa;导出工具=dao chu gong ju;配置文件=pei zhi wen jian;网络连接=wang luo lian jie;后台任务=hou tai ren wu;用户界面=yong hu jie mian;数据库连接=shu ju ku lian jie;文件索引=wen jian suo yin;权限检查=quan xian jian cha;输入缓冲区=shu ru huan chong qu;分词模块=fen ci mo kuai')
FAULTS = fragments('超时问题=chao shi wen ti;内存泄漏=nei cun xie lou;排序错误=pai xu cuo wu;边界错误=bian jie cuo wu;并发问题=bing fa wen ti;编码问题=bian ma wen ti;显示异常=xian shi yi chang;连接失败=lian jie shi bai;重复提交=chong fu ti jiao;缓存失效=huan cun shi xiao')
CITIES = fragments('南京=nan jing;杭州=hang zhou;成都=cheng du;苏州=su zhou;厦门=xia men;青岛=qing dao;昆明=kun ming;长沙=chang sha;武汉=wu han;合肥=he fei;宁波=ning bo;珠海=zhu hai')
PLACES = fragments('博物馆=bo wu guan;图书馆=tu shu guan;植物园=zhi wu yuan;美术馆=mei shu guan;海洋馆=hai yang guan;科技馆=ke ji guan;古镇=gu zhen;公园=gong yuan;展览馆=zhan lan guan;动物园=dong wu yuan')
ROUTES = fragments('地铁=di tie;公交车=gong jiao che;出租车=chu zu che;高铁=gao tie;火车=huo che;长途汽车=chang tu qi che')
SUBJECTS = fragments('数学=shu xue;物理=wu li;化学=hua xue;生物=sheng wu;地理=di li;历史=li shi;英语=ying yu;语文=yu wen;计算机基础=ji suan ji ji chu;统计学=tong ji xue')
STUDENTS = fragments('学生们=xue sheng men;同学们=tong xue men;我们=wo men;学习小组=xue xi xiao zu;新同学=xin tong xue;小组成员=xiao zu cheng yuan')
MONEY = fragments('采购预算=cai gou yu suan;旅行预算=lv xing yu suan;年度预算=nian du yu suan;设备费用=she bei fei yong;运输费用=yun shu fei yong;项目成本=xiang mu cheng ben;培训费用=pei xun fei yong;维护成本=wei hu cheng ben;装修预算=zhuang xiu yu suan;办公费用=ban gong fei yong')
FREQUENCIES = fragments('每周=mei zhou;每月=mei yue;每季度=mei ji du;每年=mei nian;月底=yue di;年底=nian di')

# A template is a sequence of independently authored fragments or typed slot pools.
# No dictionary, model, corpus sentence or former evaluation row chooses a target.
TEMPLATES = []


def template(name, category, *parts):
    TEMPLATES.append((name, category, tuple(fragment(p) if isinstance(p, str) else p for p in parts)))


template('meal-plan', 'daily', ACTORS, TIMES, '想吃=xiang chi', DAILY)
template('meal-prepare', 'daily', ACTORS, TIMES, '准备做=zhun bei zuo', DAILY)
template('meal-share', 'daily', ACTORS, '商量=shang liang', TIMES, '一起吃=yi qi chi', DAILY)
template('room-clean', 'daily', ACTORS, TIMES, '打算打扫=da suan da sao', HOME)
template('furniture-move', 'daily', ACTORS, TIMES, '准备把=zhun bei ba', ITEMS, '搬到=ban dao', HOME)
template('furniture-order', 'daily', ACTORS, TIMES, '打算订购=da suan ding gou', ITEMS)
template('doc-read', 'work', ACTORS, TIMES, '需要仔细阅读=xu yao zi xi yue du', DOCS)
template('doc-revise', 'work', TEAM, TIMES, '准备修改=zhun bei xiu gai', DOCS)
template('doc-review', 'work', TEAM, TIMES, '一起讨论=yi qi tao lun', DOCS)
template('doc-send', 'work', '请把=qing ba', DOCS, '发给=fa gei', TEAM)
template('doc-wait', 'work', ACTORS, '正在等待=zheng zai deng dai', TEAM, '确认=que ren', DOCS)
template('doc-save', 'work', ACTORS, TIMES, '记得保存=ji de bao cun', DOCS)
template('tech-inspect', 'technology', TEAM, TIMES, '需要检查=xu yao jian cha', TECH)
template('tech-rewrite', 'technology', ACTORS, TIMES, '准备重构=zhun bei chong gou', TECH)
template('tech-issue', 'technology', TEAM, '正在排查=zheng zai pai cha', TECH, '中的=zhong de', FAULTS)
template('tech-fix', 'technology', ACTORS, TIMES, '优先解决=you xian jie jue', TECH, '中的=zhong de', FAULTS)
template('tech-test', 'technology', TEAM, TIMES, '计划测试=ji hua ce shi', TECH)
template('tech-document', 'technology', '请在=qing zai', DOCS, '中补充=zhong bu chong', TECH, '的说明=de shuo ming')
template('city-plan', 'travel', ACTORS, TIMES, '计划去=ji hua qu', CITIES, '旅行=lv xing')
template('city-visit', 'travel', ACTORS, TIMES, '想去=xiang qu', CITIES, '的=de', PLACES)
template('city-arrive', 'travel', ACTORS, TIMES, '打算乘坐=da suan cheng zuo', ROUTES, '前往=qian wang', CITIES)
template('city-weather', 'travel', '请帮=qing bang', ACTORS, '查询=cha xun', CITIES, TIMES, '的天气=de tian qi')
template('city-guide', 'travel', ACTORS, TIMES, '准备整理=zhun bei zheng li', CITIES, '的旅行攻略=de lv xing gong lve')
template('city-ticket', 'travel', ACTORS, TIMES, '需要购买前往=xu yao gou mai qian wang', CITIES, '的车票=de che piao')
template('study-review', 'education', STUDENTS, TIMES, '准备复习=zhun bei fu xi', SUBJECTS)
template('study-material', 'education', STUDENTS, TIMES, '需要整理=xu yao zheng li', SUBJECTS, '的学习资料=de xue xi zi liao')
template('study-problem', 'education', STUDENTS, TIMES, '一起讨论=yi qi tao lun', SUBJECTS, '的练习题=de lian xi ti')
template('study-note', 'education', STUDENTS, TIMES, '记得带上=ji de dai shang', SUBJECTS, '笔记=bi ji')
template('study-prepare', 'education', STUDENTS, TIMES, '计划预习=ji hua yu xi', SUBJECTS, '的下一章=de xia yi zhang')
template('study-ask', 'education', STUDENTS, TIMES, '想请教老师=xiang qing jiao lao shi', SUBJECTS, '方面的问题=fang mian de wen ti')
template('budget-check', 'finance', TEAM, TIMES, '需要核对=xu yao he dui', MONEY)
template('budget-plan', 'finance', ACTORS, TIMES, '准备重新计算=zhun bei chong xin ji suan', MONEY)
template('budget-summary', 'finance', TEAM, FREQUENCIES, '汇总=hui zong', MONEY)
template('budget-discuss', 'finance', ACTORS, TIMES, '一起讨论=yi qi tao lun', MONEY)
template('budget-reduce', 'finance', TEAM, TIMES, '考虑减少=kao lv jian shao', MONEY)
template('budget-approve', 'finance', ACTORS, '正在等待=zheng zai deng dai', TEAM, '确认=que ren', MONEY)

# These source spellings/targets are explicitly requested regression coverage.
# They are newly recorded from product documentation, not copied from retired suites.
RECENT = '''
zhaojichujuzi|找几处句子|zhao ji chu ju zi|terminal-retention
erbeizuoduo|二倍做多|er bei zuo duo|terminal-retention
woxianganzhao|我想按照|wo xiang an zhao|syllable-boundary
cichuxiande|词出现的|ci chu xian de|prefix-ambiguity
sheguofennudehai|涉过愤怒的海|she guo fen nu de hai|character-prefix
heshangcibi|和上次比|he shang ci bi|segmentation
xianzaitianjiazimu|现在添加字幕|xian zai tian jia zi mu|homophone
dierye|第二页|di er ye|ordinal
diqiye|第七页|di qi ye|ordinal
dijiuye|第九页|di jiu ye|ordinal
dishiye|第十页|di shi ye|ordinal
yuliao|语料|yu liao|dictionary-weight
taiguo|泰国|tai guo|dictionary-weight
ling|零|ling|cross-language
ma|吗|ma|cross-language
nengxiangbanfayouhuama|能想办法优化吗|neng xiang ban fa you hua ma|sentence
'''
HARD_CASES = [('goon', 'go on'), ('into', 'into'), ('also', 'also'), ('maybe', 'maybe'), ('cannot', 'cannot'), ('myself', 'myself')]


def case(name, spelling, references, category, origin, family, syllables=None, note=None):
    row = {'id': name, 'input': spelling, 'references': references, 'category': category,
           'origin': origin, 'family': family, 'languages': ['zh-Hans', 'en'], 'context': []}
    if syllables is not None:
        row['syllables'] = list(syllables)
    if note:
        row['note'] = note
    return row


def chinese_case(name, pieces, category, family, origin='seeded-composition'):
    text = ''.join(p.text for p in pieces)
    syllables = tuple(s for p in pieces for s in p.syllables)
    return case(name, ''.join(syllables), [text], category, origin, family, syllables)


def generate():
    rng = random.Random(SEED)
    rows = []
    for i, line in enumerate(RECENT.strip().splitlines(), 1):
        spelling, target, reading, category = line.split('|')
        # Preserve the two examples removed from the maintained test file.
        if spelling == 'sheguofennudehai':
            continue
        syllables = reading.split()
        # Keep two page regressions overall rather than a series of page numbers.
        if category == 'ordinal' and spelling not in {'dierye', 'diqiye'}:
            continue
        variants = [('continuous', spelling)]
        if category != 'ordinal':
            variants.append(('separated', "'".join(syllables)))
        for alias, source in variants:
            if any(r['input'] == source for r in rows):
                continue
            rows.append(case(f'recent-{i:02d}-{alias}', source, [target], category, 'documented-regression',
                             ('ordinal-页' if category == 'ordinal' else f'recent-{i:02d}'), syllables,
                             'Intended target for a known ambiguous input; not a claim that alternatives are invalid.'))
    for i, (source, target) in enumerate(HARD_CASES, 1):
        rows.append(case(f'hard-{i:02d}', source, [target], 'english-segmentation', 'requested-hard-case',
                         f'hard-{i:02d}', note='Requested historical target; goon also has a valid whole-word reading.'))

    # One typical case for each additional ordinal unit; pages are covered above.
    for i, source in enumerate(['第十一章=di shi yi zhang', '第三节=di san jie',
                                '第四段=di si duan', '第六行=di liu hang'], 1):
        part = fragment(source)
        rows.append(chinese_case(f'ordinal-{i:03d}', [part], 'ordinal',
                                 'ordinal-' + part.text[-1], 'authored-ordinal'))

    # One target and two materially different source encodings, without slot expansion.
    for i, alias in enumerate(['ü', 'u:'], 1):
        row = chinese_case(f'umlaut-{i:03d}', [fragment('我想买绿色背包=wo xiang mai lv se bei bao')],
                           'umlaut-alias', 'umlaut-shopping', 'authored-alias')
        row['input'] = row['input'].replace('v', alias)
        rows.append(row)

    english_verbs = ['review', 'update', 'save', 'open', 'check', 'share', 'export', 'inspect', 'compare', 'download']
    english_objects = ['the report', 'the document', 'the project', 'the schedule', 'the invoice', 'the database',
                       'the archive', 'the configuration', 'the results', 'the summary', 'the checklist', 'the proposal']
    english_heads = ['please', 'we need to', 'they want to', 'you should', 'remember to', 'I need to', 'we plan to', 'can you']
    english_tails = ['', ' today', ' tomorrow', ' again', ' before lunch', ' this afternoon']
    seen = {row['input'] for row in rows}
    for i in range(MAX_PER_FAMILY):
        while True:
            verb, obj, head, tail = (rng.choice(english_verbs), rng.choice(english_objects), rng.choice(english_heads), rng.choice(english_tails))
            text = f'{head} {verb} {obj}{tail}'
            source = text.replace(' ', '')
            if source not in seen:
                break
        seen.add(source)
        rows.append(case(f'english-{i + 1:04d}', source, [text], 'english-sentence', 'seeded-composition', 'english-continuous'))

    tools = ['Swift', 'Python', 'Docker', 'Git', 'Linux', 'Redis', 'SQLite', 'Xcode', 'Rust', 'Kotlin']
    mixed_patterns = [
        ('learn', '学习=xue xi', '的基础知识=de ji chu zhi shi'),
        ('install', '安装=an zhuang', '的开发环境=de kai fa huan jing'),
        ('read', '阅读=yue du', '的官方文档=de guan fang wen dang'),
        ('inspect', '检查=jian cha', '的版本信息=de ban ben xin xi'),
        ('share', '分享=fen xiang', '的使用经验=de shi yong jing yan'),
    ]
    for i in range(len(mixed_patterns) * MAX_PER_FAMILY):
        while True:
            actor, when, tool = rng.choice(ACTORS), rng.choice(TIMES), rng.choice(tools)
            pattern, action, ending = mixed_patterns[i // MAX_PER_FAMILY]
            before = chinese_case('temporary', [actor, when, fragment('准备=zhun bei'), fragment(action)], '', '')
            after = fragment(ending)
            source = before['input'] + tool + ''.join(after.syllables)
            if source not in seen:
                break
        seen.add(source)
        rows.append(case(f'mixed-{i + 1:04d}', source,
                         [before['references'][0] + ' ' + tool + ' ' + after.text],
                         'mixed-technical', 'seeded-composition', 'mixed-' + pattern))

    # Sample at most two distinct instances of each sentence structure.
    # Never fill a global row quota by changing subjects, dates, nouns or numbers.
    for name, category, parts in TEMPLATES:
        for i in range(MAX_PER_FAMILY):
            while True:
                pieces = [rng.choice(p) if isinstance(p, list) else p for p in parts]
                row = chinese_case(f'{name}-{i + 1:02d}', pieces, category, name)
                if row['input'] not in seen:
                    break
            seen.add(row['input'])
            rows.append(row)
    rows.append(chinese_case('requested-houxuanchi', [fragment('候选池=hou xuan chi')],
                             'technical-term', 'requested-houxuanchi', 'user-requested-regression'))
    rows.append(chinese_case('requested-beihai-guzhen',
                             [fragment('大家下周想去北海古镇=da jia xia zhou xiang qu bei hai gu zhen')],
                             'travel', 'requested-beihai-guzhen', 'user-requested-regression'))
    validate(rows)
    return rows


def validate(rows):
    if len(rows) != COUNT:
        raise ValueError(f'Expected {COUNT} rows, got {len(rows)}')
    if len({r['id'] for r in rows}) != COUNT or len({r['input'] for r in rows}) != COUNT:
        raise ValueError('Repeated ID or exact input')
    if any(count > MAX_PER_FAMILY for count in Counter(r['family'] for r in rows).values()):
        raise ValueError('Too many near-duplicate cases in one family')
    for row in rows:
        if not row['input'] or not row['references'] or len(set(row['references'])) != len(row['references']):
            raise ValueError('Invalid input/references: ' + row['id'])
        if any(not isinstance(ref, str) or not ref for ref in row['references']):
            raise ValueError('Empty reference: ' + row['id'])
        if row['languages'] != ['zh-Hans', 'en'] or row['context']:
            raise ValueError('Unexpected configuration: ' + row['id'])
        if 'candidates' in row:
            raise ValueError('Candidate pools must be generated by the evaluated engine')
        if 'syllables' in row:
            canonical = row['input'].replace('u:', 'v').replace('ü', 'v').replace("'", '')
            if canonical != ''.join(row['syllables']) or len(row['references'][0]) != len(row['syllables']):
                raise ValueError('Source/target alignment failed: ' + row['id'])
    if not all(any(r['input'] == source and r['references'] == [target] for r in rows) for source, target in HARD_CASES):
        raise ValueError('Missing requested hard case')


def encoded(rows):
    return ''.join(json.dumps(row, ensure_ascii=False, separators=(',', ':')) + '\n' for row in rows).encode()


def manifest(rows, payload):
    return {
        'schema_version': 2, 'suite': 'ranking-20261109-compact-v4', 'cases': len(rows), 'seed': SEED,
        'test_sha256': hashlib.sha256(payload).hexdigest(),
        'generator_sha256': hashlib.sha256(Path(__file__).read_bytes()).hexdigest(),
        'categories': dict(sorted(Counter(r['category'] for r in rows).items())),
        'origins': dict(sorted(Counter(r['origin'] for r in rows).items())),
        'families': len({r['family'] for r in rows}),
        'maximum_cases_per_family': MAX_PER_FAMILY,
        'source': 'New SI-authored synthetic fragments/templates plus explicitly requested documented regressions and six hard cases.',
        'license': 'GPL-3.0-only',
        'limitations': [
            'Synthetic, AI-assisted labels; no independent human review or representative typing distribution.',
            'Each semantic/template family has at most two representative cases; this is not natural typing sampling.',
            'Single test suite, no train/dev split; do not train or select ranking settings against these targets.',
            'Intended exact outputs measure target availability/rank; other homophones can be valid.',
            'No model-training overlap audit; no claim of independent heldout quality.',
            'No frozen candidates, host events, personal data, runtime measurements or measured accuracy included.',
        ],
    }


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--check', action='store_true', help='Check frozen bytes, counts and reproducibility without writing')
    parser.add_argument('--output', type=Path, default=DESTINATION)
    args = parser.parse_args()
    rows = generate()
    payload = encoded(rows)
    metadata = (json.dumps(manifest(rows, payload), ensure_ascii=False, indent=2) + '\n').encode()
    files = {'test.jsonl': payload, 'manifest.json': metadata}
    if args.check:
        for name, content in files.items():
            if (args.output / name).read_bytes() != content:
                raise ValueError('Modified or nonreproducible evaluation file: ' + name)
    else:
        if any((args.output / name).exists() for name in files):
            parser.error('Refusing to overwrite a frozen dataset; select a new --output directory')
        args.output.mkdir(parents=True, exist_ok=True)
        for name, content in files.items():
            (args.output / name).write_bytes(content)
    print(json.dumps({'cases': len(rows), 'categories': manifest(rows, payload)['categories'], 'check': args.check}))


if __name__ == '__main__':
    main()
