# Chinese Chatbot Corpus provenance

The local reader follows the [codemayq collection layout at
`3e1aaf3`](https://github.com/codemayq/chinese-chatbot-corpus/tree/3e1aaf381fc971997a585c2571af050660331f48).
That revision identifies the layout, and the prepared manifest identifies the
actual data bytes by file size and SHA-256. The upstream Git repository contains
Apache-2.0 processing code. Its README describes a noncommercial compilation and
credits the underlying collections individually. Review the data terms of each
subcorpus before reuse or redistribution.

| ID | Upstream credit and data terms |
| --- | --- |
| `chatterbot` | [Gunther Cox, ChatterBot Corpus Chinese data](https://github.com/gunthercox/chatterbot-corpus/tree/master/chatterbot_corpus/data/chinese), published in the [BSD-3-Clause repository](https://github.com/gunthercox/chatterbot-corpus). |
| `douban` | [Yu Wu et al., Sequential Matching Network, ACL 2017](https://github.com/MarkWuNLP/MultiTurnResponseSelection). The authors provide the dataset for reproduction and request citation. No separate redistribution grant was verified. |
| `ptt` | [Kai-Chou Yang, PTT Gossiping Corpus](https://github.com/zake7749/Gossiping-Chinese-Corpus), DOI 10.34740/DVS/676336. The publisher's repository includes an Apache-2.0 license. |
| `qingyun` | Qingyun chat corpus. The collection cites a chatbot discussion group and lists no original release or data license. |
| `subtitle` | [dgk_lost_conv](https://github.com/fateleak/dgk_lost_conv), also listed in [Dialog Corpus](https://github.com/candlewill/Dialog_Corpus). The latter attributes copyright to original authors. Subtitle redistribution rights are unverified. |
| `tieba` | Baidu Tieba forum replies. The collection cites a Baidu Netdisk share without an original license. |
| `weibo` | Huawei Noah's Ark Lab short-text conversation data. The collection cites the original `Noah_NRM_Data` server. Data redistribution rights are unverified. |
| `xiaohuangji` | Unsegmented Xiaohuangji archive from [Dialog Corpus](https://github.com/candlewill/Dialog_Corpus). It attributes copyright to original authors. Data redistribution rights are unverified. |

Keep raw and derived data local. Preserve any notices received with the download
under `licenses/` or `metadata/` alongside the raw data so they are copied into
the prepared bundle. The importer excludes the supplementary SMS and Egret Q&A
folders, which upstream's eight-source processing entry point does not read.
