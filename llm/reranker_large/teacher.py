"""Explicit local-only Qwen scoring; teacher loading is never a training side effect."""

import importlib.metadata
from pathlib import Path
import shutil

import torch
from torch.nn import functional as F

from corpus.common import new_directory
from llm.reranker_small.data import load_bundle
from llm.reranker_small.runtime import select_device
from .data import PoolWriter, checked_file, load_pools
from .prepare import finish_manifest
from .scoring import validate_pool
from .settings import file_hash, load_config

PROTOCOL = 'qwen-bos-context-separate-candidate-sum-logp-no-eos-v1'


class QwenTeacher:
    def __init__(self, path, device_name='mps', threads=4):
        from transformers import AutoConfig, AutoModelForCausalLM, AutoTokenizer

        path = Path(path)
        if not path.is_dir() or threads <= 0:
            raise ValueError('Select a local teacher directory and positive thread count')
        self.files = {p.name: file_hash(p) for p in sorted(path.iterdir()) if p.is_file()}
        self.path = path
        torch.set_num_threads(threads)
        self.device = select_device(device_name)
        dtype = torch.float32 if self.device.type == 'cpu' else torch.float16
        config = AutoConfig.from_pretrained(path, local_files_only=True, trust_remote_code=False)
        if (config.model_type != 'qwen2' or config.hidden_size != 896
                or config.num_hidden_layers != 24 or config.vocab_size != 151936):
            raise ValueError('This adapter expects the Qwen2.5-0.5B Base architecture')
        self.tokenizer = AutoTokenizer.from_pretrained(path, local_files_only=True, trust_remote_code=False)
        self.model = AutoModelForCausalLM.from_pretrained(
            path, local_files_only=True, trust_remote_code=False,
            torch_dtype=dtype, attn_implementation='sdpa').to(self.device).eval()
        self.identity = dict(model_id='local-qwen2-0.5b', intended_model_id='Qwen/Qwen2.5-0.5B', protocol=PROTOCOL,
            files=self.files, dtype=str(dtype), device=str(self.device), threads=threads,
            torch=str(torch.__version__), transformers=importlib.metadata.version('transformers'),
            tokenizers=importlib.metadata.version('tokenizers'),
            safetensors=importlib.metadata.version('safetensors'),
            huggingface_hub=importlib.metadata.version('huggingface-hub'),
            origin='https://huggingface.co/Qwen/Qwen2.5-0.5B',
            note='Local bytes are identified by hashes. Upstream model identity/revision is not inferred from architecture or directory name.')

    @torch.inference_mode()
    def score(self, row):
        prefix = [self.model.config.bos_token_id] + self.tokenizer.encode(row['context'], add_special_tokens=False)
        sequences = [prefix + self.tokenizer.encode(c['text'], add_special_tokens=False) for c in row['candidates']]
        length = max(map(len, sequences)) - 1
        if length > self.model.config.max_position_embeddings:
            raise ValueError('Teacher request exceeds its context; truncation is not allowed')
        inputs = torch.full((len(sequences), length), self.model.config.eos_token_id,
                            dtype=torch.long, device=self.device)
        labels, mask = torch.full_like(inputs, -100), torch.zeros_like(inputs)
        for i, sequence in enumerate(sequences):
            n = len(sequence) - 1
            inputs[i, :n] = torch.tensor(sequence[:-1], device=self.device)
            labels[i, len(prefix) - 1:n] = torch.tensor(sequence[len(prefix):], device=self.device)
            mask[i, :n] = 1
        logits = self.model(input_ids=inputs, attention_mask=mask, use_cache=False).logits
        nll = F.cross_entropy(logits.float().transpose(1, 2), labels, reduction='none', ignore_index=-100)
        return (-nll.sum(-1)).cpu().tolist()

    def verify(self):
        if self.files != {p.name: file_hash(p) for p in sorted(self.path.iterdir()) if p.is_file()}:
            raise ValueError('Teacher files changed during scoring')


def cache_teacher(config_path, lm_data, pools, output, teacher):
    config = load_config(config_path)
    lm_manifest, tokenizer, _ = load_bundle(lm_data, config, ('train',))
    manifest, datasets = load_pools(pools, config, lm_manifest, tokenizer, ('train', 'validation'), scored=False)
    with new_directory(output) as staged:
        for split, data in datasets.items():
            writer = PoolWriter(staged, split)
            try:
                for i in range(len(data)):
                    row = data[i]
                    row['teacher_scores'] = teacher.score(row)
                    if not validate_pool(row, tokenizer, config):
                        raise ValueError('Unexpected unscorable prepared pool')
                    writer.append(row)
            finally:
                writer.close()
        # Never send final-test cases to the teacher during training preparation.
        for name in ('test.jsonl', 'test.index.bin'):
            source = checked_file(pools, manifest, name)
            shutil.copyfile(source, staged / name)
            if file_hash(staged / name) != manifest['files'][name]:
                raise ValueError('Test pool changed while copying')
        for name in manifest['files']:
            if name in ('NOTICE.md', 'source-lock.json') or name.startswith('metadata/'):
                source = checked_file(pools, manifest, name)
                destination = staged / name
                destination.parent.mkdir(parents=True, exist_ok=True)
                shutil.copyfile(source, destination)
                if file_hash(destination) != manifest['files'][name]:
                    raise ValueError('Attribution changed while copying')
        write_sources = staged / 'metadata/teacher'
        if isinstance(teacher, QwenTeacher):
            write_sources.mkdir(parents=True, exist_ok=True)
            for name in ('LICENSE', 'README.md'):
                if name in teacher.files:
                    shutil.copyfile(teacher.path / name, write_sources / name)
                    if file_hash(write_sources / name) != teacher.files[name]:
                        raise ValueError('Teacher attribution changed while copying')
        teacher.verify()
        for split in ('train', 'validation', 'test'):
            for extension in ('jsonl', 'index.bin'):
                checked_file(pools, manifest, f'{split}.{extension}')
        return finish_manifest(staged, dict(schema_version=1, kind='si-student-pools',
            lm_dataset_id=manifest['lm_dataset_id'], tokenizer_digest=manifest['tokenizer_digest'],
            limits=manifest['limits'], splits=manifest['splits'],
            parent_pool_dataset_id=manifest['dataset_id'], teacher=teacher.identity,
            scored_splits=['train', 'validation'], teacher_code=file_hash(Path(__file__))))
