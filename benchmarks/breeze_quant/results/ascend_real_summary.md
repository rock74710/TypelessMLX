# ASCEND real code-switch subset comparison

Full result: [`ascend_real_comparison.json`](./ascend_real_comparison.json).

**Directional limitation:** this is a bounded subset of 17 official ASCEND test utterances (77.95 s), two speakers (`3`, `17`), with 8 Chinese-leading and 9 English-leading items. It is not the full ASCEND test set and is not sufficient for a production accuracy claim.

## Corpus and provenance

- Dataset: `CAiRE/ASCEND`, config `main`, split `test`, revision `737e9800ae31be9932ba8464c80366559bd28424`.
- License: `CC BY-SA 4.0` ([license](<https://creativecommons.org/licenses/by-sa/4.0/>)); attribution and dataset/paper URLs are preserved in the JSON manifest metadata and every sample `source_item`.
- The source manifest/audio paths, per-file hashes, references, speaker IDs, selection counts, and retrieval metadata are preserved in `ascend_real_comparison.json`.
- Audio validation before the run: 17/17 manifest SHA-256 matches; 16 kHz mono WAV; total duration 77.95 s.

## Method

- Runtime: macOS 27.0 arm64, Python 3.12.11, `mlx-whisper 0.4.3`, MLX `0.31.1`.
- Fixed decoding for every model: `language="zh"`, `temperature=0.0`, `fp16=true`, `verbose=null`, `without_timestamps=true`, `task="transcribe"`, `condition_on_previous_text=true`, and the same bilingual initial prompt.
- Five local artifacts ran in CLI order, one fresh subprocess per model/config, strictly sequential. Each of 17 samples had one warm-up and 3 timed hot runs; aggregate hot metrics pool 51 runs/model. p95 uses linear interpolation.
- Main mixed error is token-level Levenshtein distance divided by reference token count, pooled as `sum(edit_distance) / sum(reference_tokens)` across hot runs. Normalization is Unicode NFKC; one token per CJK ideograph; whitespace-separated ASCII English word runs (CJK/Latin boundaries are also split); contiguous numeric runs; punctuation and whitespace excluded; ASCII Latin tokens casefolded. Case-sensitive token error and punctuation signature edit/exact results are recorded separately.

Exact command:

```bash
/Users/schsu/.local/share/typelessmlx/venv/bin/python benchmarks/breeze_quant/benchmark_models.py --manifest /tmp/typelessmlx-real-codeswitch-v1/manifest.json --audio-dir /tmp/typelessmlx-real-codeswitch-v1 --model breeze-fp16=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx --model breeze-8bit=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx-8bit --model breeze-6bit=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx-6bit --model breeze-hybrid=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx-hybrid --model breeze-4bit=/Users/schsu/.cache/huggingface/hub/models--BRlin--Breeze-ASR-25-mlx-4bit/snapshots/ba89325dcf6911c3fcd1ba7c7e813b1907f2a9e5 --hot-runs 3 --output benchmarks/breeze_quant/results/ascend_real_comparison.json
```

## Aggregate results

Peak MLX memory is the maximum `mx_peak_memory` observed across cold load, cold first inference, warm-up, and hot runs. Blank counts and exact disagreements below are hot outputs only.

| Model | Weights GiB | Cold load (s) | Cold first (s) | Hot median (s) | Hot p95 (s) | RTF median | RTF p95 | Peak MLX GiB | Blank | Exact vs FP16 | Mixed error | Case-sensitive | Punct exact |
|---|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|---:|
| breeze-fp16 | 2.871 | 0.520 | 1.041 | 0.713 | 0.913 | 0.175 | 0.448 | 3.680 | 0/51 | 0/51 | 34.93% | 37.87% | 42/51 |
| breeze-8bit | 1.532 | 0.089 | 0.781 | 0.723 | 0.869 | 0.173 | 0.452 | 2.352 | 0/51 | 3/51 (00211) | 35.29% | 38.24% | 42/51 |
| breeze-6bit | 1.174 | 0.081 | 0.797 | 0.703 | 0.845 | 0.174 | 0.462 | 1.995 | 0/51 | 3/51 (00211) | 35.66% | 38.60% | 42/51 |
| breeze-hybrid | 2.175 | 0.249 | 0.878 | 0.784 | 0.954 | 0.181 | 0.462 | 2.988 | 0/51 | 0/51 | 34.93% | 37.87% | 42/51 |
| breeze-4bit | 0.817 | 0.067 | 0.787 | 0.699 | 0.833 | 0.165 | 0.449 | 1.638 | 0/51 | 27/51 (00009, 00028, 00211, 00233, 00295, 00299, 00346, 00361, 00388) | 36.03% | 38.97% | 42/51 |

## Start-language stratification

Weighted mixed error uses the same pooled edit/reference-token definition; each group has 3 hot runs per item.

| Model | Chinese-leading (8 items, 24 runs) | English-leading (9 items, 27 runs) |
|---|---:|---:|
| breeze-fp16 | 41.06% (186/453) | 27.27% (99/363) |
| breeze-8bit | 41.72% (189/453) | 27.27% (99/363) |
| breeze-6bit | 42.38% (192/453) | 27.27% (99/363) |
| breeze-hybrid | 41.06% (186/453) | 27.27% (99/363) |
| breeze-4bit | 43.05% (195/453) | 27.27% (99/363) |

## Per-sample references and hot transcripts

Each model cell shows the unique hot transcript; all 3 hot repetitions were identical within each cell in this run.

| ID | Start | Spk | Dur (s) | Reference | FP16 | 8-bit | 6-bit | Hybrid | 4-bit |
|---|:---:|---:|---:|---|---|---|---|---|---|
| 00009 | en | 17 | 4.030 | no我专业是那个i s m information systems management | 那我專業是那個 ISM Information Systems Management | 那我專業是那個 ISM Information Systems Management | 那我專業是那個 ISM Information Systems Management | 那我專業是那個 ISM Information Systems Management | 我專業是那個 ISM Information Systems Management |
| 00028 | en | 17 | 1.020 | ok福建 | OK food 錢 | OK food 錢 | OK food 錢 | OK food 錢 | OK 附件 |
| 00207 | en | 3 | 2.740 | ok所以我come from福建 | OK 所以我 come from 福建 | OK 所以我 come from 福建 | OK 所以我 come from 福建 | OK 所以我 come from 福建 | OK 所以我 come from 福建 |
| 00208 | zh | 3 | 7.920 | 所以我的我的parents我的妈妈是chemistry老师and我的爸爸是history老师 | 所以我的 parents 我的 mama 是 chemistry 老師 and 我的爸爸是 history 老師 | 所以我的 parents 我的 mama 是 chemistry 老師 and 我的爸爸是 history 老師 | 所以我的 parents 我的 mama 是 chemistry 老師 and 我的爸爸是 history 老師 | 所以我的 parents 我的 mama 是 chemistry 老師 and 我的爸爸是 history 老師 | 所以我的 parents 我的 mama 是 chemistry 老師 and 我的爸爸是 history 老師 |
| 00211 | zh | 3 | 7.900 | 那个玩basketball的然后我有时候有时候会邀我的friends啊一起打在就是after class的时候 | 那個玩 basketball 的然後我就說了說會邀我的 friends 一起打在就是 after class 的時候 | 那個玩 basketball 的然後有時候會邀我的 friends 一起打在 after class 的時候 | 那個玩 basketball 的然後我就說了說會邀我的 friends 一起打在 after class 的時候 | 那個玩 basketball 的然後我就說了說會邀我的 friends 一起打在就是 after class 的時候 | 那個玩 basketball 的然後有時候會邀我的 friends 一起打在 after class 的時候 |
| 00228 | zh | 3 | 5.900 | 哦我我在u g的时候念的是electric engineering | 我在 UG 的時候念的是 electric engineering | 我在 UG 的時候念的是 electric engineering | 我在 UG 的時候念的是 electric engineering | 我在 UG 的時候念的是 electric engineering | 我在 UG 的時候念的是 electric engineering |
| 00233 | zh | 3 | 3.440 | 对台湾的台湾大学National Taiwan University念 | 台灣的台灣大學 National Taiwan University 唸 | 台灣的台灣大學 National Taiwan University 唸 | 台灣的台灣大學 National Taiwan University 唸 | 台灣的台灣大學 National Taiwan University 唸 | 台灣的台灣大學 National Taiwan University 裡面 |
| 00258 | zh | 3 | 2.420 | 对带我们认识new friends之类的 | 帶我們認識 new friends 之類的 | 帶我們認識 new friends 之類的 | 帶我們認識 new friends 之類的 | 帶我們認識 new friends 之類的 | 帶我們認識 new friends 之類的 |
| 00295 | en | 3 | 4.000 | tell一些你现在做什么research方向 | 挑一些你現在做什麼 research 方向 | 挑一些你現在做什麼 research 方向 | 挑一些你現在做什麼 research 方向 | 挑一些你現在做什麼 research 方向 | 調一些你現在做什麼 research 方向 |
| 00299 | zh | 3 | 6.780 | 所以我我现在主要在做啊就是dialogue system相关就对话系统的研究 | 所以我現在主要在做 dialogue system 相關就是對話系統的研究 | 所以我現在主要在做 dialogue system 相關就是對話系統的研究 | 所以我現在主要在做 dialogue system 相關就是對話系統的研究 | 所以我現在主要在做 dialogue system 相關就是對話系統的研究 | 所以我現在主要在做 dialogue system 相關的就是對話系統的研究 |
| 00346 | zh | 3 | 3.260 | 去念研究所那为什么选择来Hong Kong | 去念研究所那為什麼選擇來 Hong Kong | 去念研究所那為什麼選擇來 Hong Kong | 去念研究所那為什麼選擇來 Hong Kong | 去念研究所那為什麼選擇來 Hong Kong | 去念研究所 那為什麼選擇來 Hong Kong |
| 00360 | zh | 3 | 4.900 | 那我当初其实来选择来 [UNK] 是一个i'll say it's like a mistake | 那我當初其實來選擇來 Hong Kong 其實是一個 I would say is like a mistake. | 那我當初其實來選擇來 Hong Kong 其實是一個 I would say is like a mistake. | 那我當初其實來選擇來 Hong Kong 其實是一個 I would say is like a mistake. | 那我當初其實來選擇來 Hong Kong 其實是一個 I would say is like a mistake. | 那我當初其實來選擇來 Hong Kong 其實是一個 I would say is like a mistake. |
| 00361 | en | 3 | 9.140 | mistake is because我当初其实原本是想要往US去走但我那时候是在the third i remember third year | mistake is because 我當初其實原本是想要往 US 去走到那時候是在 the third I remember it's third year | mistake is because 我當初其實原本是想要往 US 去走到那時候是在 the third I remember it's third year | mistake is because 我當初其實原本是想要往 US 去走到那時候是在 the third I remember it's third year | mistake is because 我當初其實原本是想要往 US 去走到那時候是在 the third I remember it's third year | mistake is because 我當初其實原本是想要往 US 去走 到那時候是在 the third I remember it's third year. |
| 00368 | en | 3 | 2.960 | from our department如果我们要去申请 | From our department 如果我們要去申請 | From our department 如果我們要去申請 | From our department 如果我們要去申請 | From our department 如果我們要去申請 | From our department 如果我們要去申請 |
| 00377 | en | 3 | 2.520 | like所有的教授什么都会说中文 | 所有的教授什麼都是說中文 | 所有的教授什麼都是說中文 | 所有的教授什麼都是說中文 | 所有的教授什麼都是說中文 | 所有的教授什麼都是說中文 |
| 00388 | en | 3 | 4.640 | not what I expected in the beginning but just对最后就回到这里 | It's not what I expected in the beginning, but just...最後就回到這裡 | It's not what I expected in the beginning, but just...最後就回到這裡 | It's not what I expected in the beginning, but just...最後就回到這裡 | It's not what I expected in the beginning, but just...最後就回到這裡 | It's not what I expected in the beginning, but just 最後就回到這裡 |
| 00437 | en | 3 | 4.380 | that's the reason我来就是最后决定做那个 | That's the reason 我來就是最後決定做那個 | That's the reason 我來就是最後決定做那個 | That's the reason 我來就是最後決定做那個 | That's the reason 我來就是最後決定做那個 | That's the reason 我來就是最後決定做那個 |

## Interpretation limits

- FP16 and hybrid had exact transcript matches across all 51 hot comparisons; 8-bit and 6-bit each differed from FP16 on 3/51 outputs (sample `00211`); 4-bit differed on 27/51 outputs across 9 samples. All models had 0/51 blank hot outputs.
- The mixed-token metric intentionally ignores punctuation and case in its main score; case-sensitive and punctuation variants are shown separately. This is not a substitute for the dataset authors’ official scoring protocol.
- Two speakers and 17 utterances are directional only. Use the full licensed ASCEND evaluation and additional Taiwan Mandarin/English speakers/noise conditions before release decisions.

Result metadata includes the exact model/config hashes, external manifest SHA-256, source/license/reference metadata, per-sample metrics/transcripts, worker PIDs, and exact worker commands.
