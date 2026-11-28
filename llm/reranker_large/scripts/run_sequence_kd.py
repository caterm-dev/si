"""Run the explicitly requested experiment using its verified frozen Python code."""
import hashlib
import json
import argparse
from pathlib import Path
import sys

REPO = Path(__file__).resolve().parents[3]
LARGE = REPO/'llm/reranker_large'
POOLS = LARGE/'data/prepared/student-15m-v1/teacher-app-v4-sequence-kd-v1'
META = POOLS/'metadata/sequence-kd'
RUN = LARGE/'runs/student-15m-extra-v1/distill-app-v4-sequence-kd-v1'
CHECKPOINT = LARGE/'runs/student-15m-extra-v1/snapshots/continued-step-019167/best.pt'
CHECKPOINT_SHA256 = 'd8b62715b60064256cbb3c9c5fc5a9651e395ae3e1c73c22faab2f51ac8e74ba'


def digest(path):
    with Path(path).open('rb') as stream:
        return hashlib.file_digest(stream,'sha256').hexdigest()


def main():
    if '--help' in sys.argv[1:] or '-h' in sys.argv[1:]:
        parser = argparse.ArgumentParser(description=__doc__)
        parser.add_argument('--resume',action='store_true',help='Resume the same frozen run; place this option first')
        parser.add_argument('--check-only',action='store_true',help='Check initialization and data on CPU without creating a run')
        parser.add_argument('--device',choices=('mps','cpu','cuda','auto'),default='mps')
        parser.add_argument('--threads',type=int,default=4)
        parser.add_argument('--max-steps',type=int,help='Override the update budget; the frozen learning-rate schedule stays fixed')
        parser.add_argument('--max-tokens',type=int)
        parser.parse_args()
        return
    if not (META/'runtime-identity.json').is_file():
        raise ValueError('Prepare the frozen data/runtime first with scripts/prepare-sequence-kd.sh')
    runtime = (META/'runtime').resolve()
    identity = json.loads((META/'runtime-identity.json').read_text())
    for name,pin in identity['files'].items():
        path = (runtime/name).resolve()
        if Path(name).is_absolute() or not path.is_relative_to(runtime) or digest(path)!=pin:
            raise ValueError('Frozen runtime file changed: '+name)
    sys.path.insert(0,str(runtime))
    from llm.reranker_large.settings import code_identity
    from llm.reranker_large.data import checked_file, manifest_at
    manifest = manifest_at(POOLS,'si-student-pools')
    for name in manifest['files']:
        if name.startswith('metadata/sequence-kd/'):
            checked_file(POOLS,manifest,name)
    if code_identity()!=identity['code_identity'] or manifest['generation']['code_identity']!=code_identity():
        raise ValueError('Frozen runtime identity differs from prepared data')
    if digest(REPO/'config/si.conf')!=digest(META/'si.conf'):
        raise ValueError('App configuration changed; prepare a separately versioned experiment')
    if digest(CHECKPOINT)!=CHECKPOINT_SHA256:
        raise ValueError('The selected 19,167-step pretrained archive changed')
    extra = sys.argv[1:]
    resume = bool(extra and extra[0]=='--resume')
    if resume:
        extra = extra[1:]
    args = ['resume','--stage','distill'] if resume else ['distill']
    args += ['--config',str(META/'config.json'),'--data',str(LARGE/'data/prepared/student-15m-v1/lm'),
             '--pools',str(POOLS),'--run',str(RUN)]
    if not resume:
        args += ['--init-checkpoint',str(CHECKPOINT),
                 '--init-data',str(LARGE/'data/prepared/student-15m-extra-v1/lm')]
    from llm.reranker_large.cli import main as cli_main
    sys.argv = ['sequence-kd',*args,*extra]
    cli_main()


if __name__=='__main__':
    main()
