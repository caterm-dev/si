"""Export Python/Rust inference with student and teacher provenance kept together."""

from pathlib import Path
import shutil

import torch

from corpus.common import new_directory
from llm.export_rust import export as export_rust
from llm.reranker_small.runtime import atomic_checkpoint, load_checkpoint
from .data import checked_file, manifest_at
from .prepare import finish_manifest
from .settings import file_hash, read_json


def export(checkpoint_path, lm_data, output, pools_path=None):
    checkpoint_path = Path(checkpoint_path)
    pin = file_hash(checkpoint_path)
    checkpoint, _, tokenizer = load_checkpoint(checkpoint_path, torch.device('cpu'))
    manifest = manifest_at(lm_data, 'si-character-lm')
    if manifest['dataset_id'] != checkpoint['dataset_id'] or manifest['tokenizer_digest'] != tokenizer.digest:
        raise ValueError('Export requires the matching LM dataset provenance')
    pool_manifest = None
    if checkpoint.get('stage') == 'distill':
        if not pools_path:
            raise ValueError('Distilled export also needs its frozen teacher cache')
        pool_manifest = manifest_at(pools_path, 'si-student-pools')
        if (pool_manifest['dataset_id'] != checkpoint['training_data_id']
                or pool_manifest['teacher'] != checkpoint['teacher']):
            raise ValueError('Export teacher provenance differs from checkpoint')
    with new_directory(output) as staged:
        fields = ('schema_version', 'kind', 'config', 'model', 'tokenizer', 'tokenizer_digest',
                  'dataset_id', 'training_data_id', 'stage', 'step', 'code_identity', 'teacher', 'initial_checkpoint')
        payload = {k: checkpoint[k] for k in fields if k in checkpoint}
        payload['inference_only'] = True
        atomic_checkpoint(staged / 'model.pt', payload)
        export_rust('reranker', checkpoint_path, staged / 'rust')
        for namespace, root, source in [('pretraining', lm_data, manifest),
                                         ('distillation', pools_path, pool_manifest)]:
            if source is None:
                continue
            destination = staged / 'metadata' / namespace
            destination.mkdir(parents=True)
            shutil.copyfile(Path(root) / 'manifest.json', destination / 'manifest.json')
            if read_json(destination / 'manifest.json') != source:
                raise ValueError('Source manifest changed during export')
            for name in source['files']:
                if name in ('NOTICE.md', 'source-lock.json', 'tokenizer.json') or name.startswith(('metadata/', 'licenses/')):
                    path = checked_file(root, source, name)
                    target = destination / name
                    target.parent.mkdir(parents=True, exist_ok=True)
                    shutil.copyfile(path, target)
                    if file_hash(target) != source['files'][name]:
                        raise ValueError('Attribution changed during export')
        if file_hash(checkpoint_path) != pin:
            raise ValueError('Checkpoint changed during export')
        return finish_manifest(staged, dict(schema_version=1, kind='si-student-inference',
            checkpoint_sha256=pin, dataset_id_parent=manifest['dataset_id'],
            stage=checkpoint['stage'], step=checkpoint['step'],
            teacher=checkpoint.get('teacher'), initial_checkpoint=checkpoint.get('initial_checkpoint'),
            note='Inference only. Data and teacher terms remain separate; no blanket weights license.'))
