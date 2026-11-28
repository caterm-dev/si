"""Derive active sequence-KL pools from a verified, immutable App v4 cache."""

import argparse
from collections import Counter
import copy
import json
from pathlib import Path
import shutil
import sys
import tomllib

REPO = Path(__file__).resolve().parents[3]
sys.path.insert(0, str(REPO))
from corpus.common import new_directory
from llm.pinyin_to_text.common import file_hash, fingerprint, read_json, write_json
from llm.reranker_small.data import load_bundle
from llm.reranker_large.app_scoring import bonus_values, pool_bonus_values
from llm.reranker_large.data import PoolWriter, checked_file, load_pools
from llm.reranker_large.prepare import finish_manifest
from llm.reranker_large.scoring import suffix, validate_pool
from llm.reranker_large.settings import (ROOT, REPO as CODE_REPO, SEQUENCE_KD, code_files,
    code_identity, load_config, score_mapping, training_objective)


def prepare(config_path, lm_data, source, output, engine_config):
    config = load_config(config_path)
    if training_objective(config) != SEQUENCE_KD:
        raise ValueError('Select candidate sequence KL configuration')
    legacy = copy.deepcopy(config)
    legacy['distillation'].pop('objective', None)
    lm, tokenizer, _ = load_bundle(lm_data, config, ('validation',))
    manifest, datasets = load_pools(source, legacy, lm, tokenizer, ('train','validation','test'), scored=True)
    if manifest.get('scored_splits') != ['train','validation']:
        raise ValueError('Source must preserve an unscored test split')
    native = tomllib.loads(Path(engine_config).read_text())['local_model_ranking']
    for key, value in config['scoring']['app'].items():
        if native[key] != value:
            raise ValueError('App parameter mismatch: ' + key)
    for local, name in (('max_candidates','model_candidate_limit'),('context_tokens','model_context_token_limit'),
                        ('candidate_tokens','model_candidate_token_limit')):
        if config['scoring'][local] != native[name]:
            raise ValueError('App token/pool bound mismatch: ' + local)
    frozen = read_json(Path(source)/'metadata/app-alignment/identity.json')
    for name, path in (('si.conf',engine_config),('main.silex',REPO/'Data/Engine/main.silex'),
                       ('words.sigram',REPO/'Data/Engine/words.sigram')):
        if file_hash(path) != frozen['resources'][name]['sha256']:
            raise ValueError('Source native resources/config differ from current App: ' + name)
    for name in manifest['files']:
        checked_file(source, manifest, name)
    source_pin = file_hash(Path(source)/'manifest.json')
    implementation_pin = code_identity()
    seen = set()
    stats = {}
    with new_directory(output) as staged:
        for name in manifest['files']:
            if name in ('NOTICE.md','source-lock.json') or name.startswith('metadata/'):
                path = checked_file(source, manifest, name)
                target = staged/name
                target.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(path, target)
        metadata = staged/'metadata/sequence-kd'
        metadata.mkdir()
        shutil.copyfile(Path(source)/'manifest.json', metadata/'parent-manifest.json')
        shutil.copyfile(config_path, metadata/'config.json')
        shutil.copyfile(engine_config, metadata/'si.conf')
        shutil.copyfile(__file__, metadata/'producer.py')
        runtime = metadata/'runtime'
        paths = code_files() + [CODE_REPO/'llm/__init__.py', CODE_REPO/'corpus/__init__.py']
        runtime_files = {}
        for path in paths:
            name = str(path.relative_to(CODE_REPO))
            target = runtime/name
            target.parent.mkdir(parents=True,exist_ok=True)
            shutil.copyfile(path,target)
            runtime_files[name] = file_hash(target)
        copied_identity = fingerprint({str(path.relative_to(CODE_REPO)):runtime_files[str(path.relative_to(CODE_REPO))]
                                       for path in code_files()})
        if copied_identity != implementation_pin:
            raise ValueError('Implementation changed while freezing the experiment')
        write_json(metadata/'runtime-identity.json',dict(code_identity=implementation_pin,files=runtime_files))
        for split, pools in datasets.items():
            counts = Counter()
            writer = PoolWriter(staged, split)
            try:
                for i in range(len(pools)):
                    row = pools[i]
                    if not validate_pool(row, tokenizer, config):
                        raise ValueError('Invalid source pool')
                    texts = list(dict.fromkeys(c['text'] for c, flag in zip(row['candidates'],row['model_mask']) if flag))
                    if len(texts) < 2:
                        counts['excluded_no_active_model_pool'] += 1
                        continue
                    context = suffix(row['context'], tokenizer, config['scoring']['context_tokens'])
                    if context != row['context']:
                        raise ValueError('Source effective context is not frozen to the same token budget')
                    query = fingerprint([context,row['input'],sorted((c['text'],c['language']) for c in row['candidates'])])
                    if query in seen:
                        raise ValueError('Duplicate native query across splits')
                    seen.add(query)
                    if split == 'test':
                        if any(k.startswith('teacher_') for k in row):
                            raise ValueError('Final-test rows must remain teacher-unscored')
                    else:
                        conditional, baseline = {}, {}
                        for c, flag, cond, base in zip(row['candidates'],row['model_mask'],
                                row['teacher_conditional_logp'],row['teacher_baseline_logp'],strict=True):
                            if flag:
                                text = c['text']
                                if text in conditional and (conditional[text] != cond or baseline[text] != base):
                                    raise ValueError('Identical text has inconsistent teacher raw scores')
                                conditional[text], baseline[text] = cond, base
                        bonuses = bonus_values([conditional[t] for t in texts],[baseline[t] for t in texts],texts,
                                               bool(context),config['scoring']['app'])
                        adjustments = pool_bonus_values(row['candidates'],row['model_adjustment_mask'],texts,bonuses)
                        expected = [b+a for b,a in zip(row['base_scores_bits'],adjustments,strict=True)]
                        if any(abs(a-b)>1e-9 for a,b in zip(expected,row['teacher_scores'],strict=True)):
                            raise ValueError('Source fused teacher scores do not match current App rule')
                    # Natural text is auxiliary LM supervision; never manufacture gold ranks.
                    row.pop('reference_indices', None)
                    row.pop('labels_reviewed', None)
                    writer.append(row)
                    counts.update(pools=1,unique_model_texts=len(texts),
                                  observed_model_scored=row['observed_text'] in texts)
                    counts['contextual' if context else 'bos_only'] += 1
                    counts['input:'+row.get('case',{}).get('input','unspecified')] += 1
            finally:
                writer.close()
            if not writer.count:
                raise ValueError('No eligible sequence-KL pools in ' + split)
            stats[split] = dict(counts)
        identity = dict(parent_dataset_id=manifest['dataset_id'],parent_manifest_sha256=source_pin,
                        training_objective=SEQUENCE_KD,score_mapping=score_mapping(config),
                        config_sha256=file_hash(config_path),engine_config_sha256=file_hash(engine_config),
                        producer_sha256=file_hash(Path(__file__)),code_identity=implementation_pin)
        write_json(metadata/'identity.json', identity)
        write_json(metadata/'report.json', dict(splits=stats,
            note='Active model pools only; exact raw Qwen and fused App scores retained. '
                 'No new Qwen scoring or model training. Test remains unscored; observed text is not ranking gold.'))
        lock = read_json(staged/'source-lock.json')
        lock['sequence_kd'] = identity
        write_json(staged/'source-lock.json', lock)
        with (staged/'NOTICE.md').open('a') as stream:
            stream.write('\nSequence-KL derivative: filters inactive native model pools and retains '
                         'the exact raw Qwen likelihoods and source notices. Inference uses frozen App v4; '
                         'training distills unique candidate sequence probabilities without hard clipping.\n')
        if file_hash(Path(source)/'manifest.json') != source_pin:
            raise ValueError('Parent manifest changed during preparation')
        if code_identity() != implementation_pin:
            raise ValueError('Implementation changed during preparation')
        return finish_manifest(staged, dict(schema_version=1,kind='si-student-pools',
            lm_dataset_id=manifest['lm_dataset_id'],tokenizer_digest=manifest['tokenizer_digest'],
            limits=manifest['limits'],score_mapping=manifest['score_mapping'],teacher=manifest['teacher'],
            parent_pool_dataset_id=manifest['dataset_id'],training_objective=SEQUENCE_KD,
            scored_splits=['train','validation'],splits={s:dict(pools=v['pools']) for s,v in stats.items()},
            generation=identity))


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--config',type=Path,default=ROOT/'configs/distill-app-v4-sequence-kd.json')
    parser.add_argument('--data',type=Path,default=ROOT/'data/prepared/student-15m-v1/lm')
    parser.add_argument('--source',type=Path,default=ROOT/'data/prepared/student-15m-v1/teacher-app-v4')
    parser.add_argument('--output',type=Path,default=ROOT/'data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1')
    parser.add_argument('--engine-config',type=Path,default=REPO/'config/si.conf')
    args = parser.parse_args()
    result = prepare(args.config,args.data,args.source,args.output,args.engine_config)
    print(json.dumps(dict(output=str(args.output),dataset_id=result['dataset_id'],splits=result['splits']),indent=2))


if __name__ == '__main__':
    main()
