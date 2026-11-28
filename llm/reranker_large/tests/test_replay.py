"""Synthetic replay budgeting, deterministic stream resume and acceptance gates."""
import copy
import io
import unittest
import numpy as np
import torch
from llm.reranker_large.scripts.replay_support import ReplayStream,replay_budget,eligible_selection,improves_selection
from llm.reranker_small.tokenizer import Tokenizer,PAD


class TinyWindows:
    def __init__(self,tokenizer,texts):
        values=[];windows=[]
        for text in texts:
            tokens=tokenizer.encode(text);windows.append((len(values),len(tokens)));values.extend(tokens)
        self.tokens=np.asarray(values,dtype='<u2');self.windows=np.asarray(windows,dtype='<u8')
    def __len__(self):return len(self.windows)
    def batch(self,indices,device):
        length=max(int(self.windows[i,1]) for i in indices)
        values=np.full((len(indices),length),PAD,dtype=np.int64)
        for r,i in enumerate(indices):
            start,count=map(int,self.windows[i]);values[r,:count]=self.tokens[start:start+count]
        tensor=torch.tensor(values,device=device)
        return tensor[:,:-1],tensor[:,1:]


class ReplayTests(unittest.TestCase):
    def fixture(self):
        texts=['保留验证文本不能回放','普通中文训练材料','另一个随机旧语料窗口']
        tok=Tokenizer(512,sorted(set(''.join(texts))))
        return tok,TinyWindows(tok,texts)
    def test_budget_means_fraction_of_actual_supervised_targets(self):
        self.assertEqual(replay_budget(900,.25),300)
        self.assertEqual(replay_budget(900,0),0)
        with self.assertRaises(ValueError):replay_budget(10,1)
    def test_stream_excludes_holdout_and_masks_to_exact_budget(self):
        tok,data=self.fixture();stream=ReplayStream(data,tok,42,['保留验证文本不能回放'])
        inputs,labels=stream.batch(37,torch.device('cpu'))
        self.assertEqual(int(labels.ne(PAD).sum()),37)
        self.assertEqual(stream.targets,37)
        for row in inputs:self.assertNotIn('保留验证文本',tok.decode(row.tolist()))
        self.assertGreater(stream.rejected,0)
    def test_stream_state_and_tiny_weight_update_resume_exactly(self):
        torch.set_num_threads(1);tok,data=self.fixture();stream=ReplayStream(data,tok,8)
        stream.batch(17,torch.device('cpu'));state=copy.deepcopy(stream.state())
        buffer=io.BytesIO();torch.save(state,buffer);buffer.seek(0);saved=torch.load(buffer,weights_only=True)
        restored=ReplayStream(data,tok,99);restored.restore(saved)
        a=stream.batch(39,torch.device('cpu'));b=restored.batch(39,torch.device('cpu'))
        self.assertTrue(all(torch.equal(x,y) for x,y in zip(a,b)))
        self.assertEqual(stream.state(),restored.state())
        torch.manual_seed(11)
        one=torch.nn.Sequential(torch.nn.Embedding(512,8),torch.nn.Linear(8,512));two=copy.deepcopy(one)
        for model,(inputs,labels) in ((one,a),(two,b)):
            opt=torch.optim.AdamW(model.parameters(),lr=.001)
            loss=torch.nn.functional.cross_entropy(model(inputs).flatten(0,1),labels.flatten(),ignore_index=PAD)
            loss.backward();opt.step()
        self.assertTrue(all(torch.equal(p,q) for p,q in zip(one.parameters(),two.parameters())))
    def test_selection_rejects_forgetting_and_preserves_ties(self):
        best=dict(native_top1=100,lm_loss=3.2)
        self.assertFalse(eligible_selection(dict(lm_loss=3.31),3.2,.1))
        self.assertFalse(improves_selection(dict(native_top1=101,lm_loss=3.31),best,3.2,.1))
        self.assertFalse(improves_selection(dict(native_top1=100,lm_loss=3.1),best,3.2,.1))
        self.assertTrue(improves_selection(dict(native_top1=101,lm_loss=3.25),best,3.2,.1))
        self.assertFalse(eligible_selection(dict(lm_loss=float('nan')),3.2,.1))


if __name__=='__main__':unittest.main()
