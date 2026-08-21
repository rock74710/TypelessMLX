# Breeze quantization benchmark

`benchmark_models.py` is a reproducible, sequential benchmark harness for
`mlx-whisper 0.4.3` with `MLX 0.31.1`. It is intended to compare the FP16
Breeze-ASR-25 artifact with later quantized artifacts without changing the
decoder settings between models.

## Corpus

[`corpus_manifest.json`](./corpus_manifest.json) contains five Taiwan
Mandarin/English code-switch prompts: a short Mandarin utterance,
Chinese-start mixed speech, English-start mixed speech, technical/API terms
and numbers, and a longer sentence. The manifest is deliberately marked
`synthetic_macos_say` and `accuracy_evidence: false`. The harness generates
16 kHz mono PCM WAV files with the installed macOS `Meijia (zh_TW)` voice and
`afconvert`; no internet download or third-party speech recording is needed.
Synthetic output is suitable for timing and regression checks only, not WER,
mixed-speech accuracy, or product quality claims.

The default generated corpus directory is
`/tmp/typelessmlx-breeze-quant-corpus-v1`. Use `--audio-dir` to choose another
directory. The manifest text, audio SHA-256, and generation metadata are
recorded in every result JSON.

The driver also accepts an external manifest with an `items` array containing
`audio_file` and `reference_transcript` fields (the ASCEND subset uses this
form). Relative audio paths resolve from the external manifest's directory;
absolute paths are accepted. External audio is validated for existence,
duration, and the manifest SHA-256 but is never generated or overwritten. The
dataset, revision, license, URLs, selection metadata, and complete per-item
source metadata are carried into the result JSON.

## Fixed decoding configuration

Every model/config uses the same `zh_fp16_greedy` configuration:

```json
{
  "language": "zh",
  "temperature": 0.0,
  "fp16": true,
  "verbose": null,
  "without_timestamps": true,
  "initial_prompt": "這是台灣中文與 English 混合語音辨識，請保留 API、MLX、Whisper、GitHub、URL、數字與英文大小寫。",
  "task": "transcribe",
  "condition_on_previous_text": true
}
```

`fp16=true` is passed as the `mlx-whisper` decoding option, which is also the
loader's dtype selector in 0.4.3. A model with quantization metadata still
uses the same decoding flags; only its artifact changes.

## Run a FP16 smoke benchmark

From the repository root, with the TypelessMLX venv installed:

```bash
/Users/schsu/.local/share/typelessmlx/venv/bin/python \
  benchmarks/breeze_quant/benchmark_models.py \
  --model breeze-fp16=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx \
  --sample-id short_zh \
  --hot-runs 3 \
  --output benchmarks/breeze_quant/results/fp16_smoke.json
```

The driver starts one fresh worker subprocess for each model/config pair and
waits for it before starting the next one. Within a worker it records cold
model load, cold load+first inference, one unmeasured warm-up per sample, and
three or more timed hot inferences per sample. `--hot-runs` refuses values
below three. There is no model concurrency.

The result records:

- audio duration, WAV SHA-256, transcript, blank-output flag, elapsed time and
  RTF for every inference;
- when `reference_transcript` is present, a mixed-token edit metric: NFKC text,
  one token per CJK ideograph, contiguous ASCII Latin word runs and numeric
  runs, punctuation/whitespace excluded from the main score, ASCII Latin
  casefolded for the main score; case-sensitive score and punctuation edit
  details are recorded separately;
- hot median/p95 elapsed time and RTF, blank count/rate, and all hot
  transcripts per sample;
- MLX peak/active/cache memory for model load and each inference;
- complete model file hashes (including `config.json` and weights), parsed
  model config, decoder config/hash, manifest/harness hashes, Python/OS and
  package versions, worker PID, and the exact worker command.

The cold load and cold first inference are separate measurements. The first
sample is then run through the normal warm-up and hot-run sequence as well,
so cold timing does not consume one of the requested hot runs.

## Compare additional artifacts

Pass each local artifact as a separate `--model` option. A `LABEL=PATH` form
keeps result labels stable:

```bash
/Users/schsu/.local/share/typelessmlx/venv/bin/python \
  benchmarks/breeze_quant/benchmark_models.py \
  --model fp16=/Users/schsu/.local/share/typelessmlx/models/breeze-asr-25-mlx \
  --model int8=/path/to/breeze-asr-25-mlx-int8 \
  --model int4=/path/to/breeze-asr-25-mlx-int4 \
  --hot-runs 3 \
  --output benchmarks/breeze_quant/results/breeze_precision_comparison.json
```

Models are required to be local directories containing `config.json` and
`weights.safetensors` or `weights.npz`; this keeps artifact hashes exact and
avoids silently benchmarking a mutable remote snapshot. Run `--prepare-corpus-only`
to generate/check WAVs without loading a model. Use `--force-corpus` only when
you intentionally want to regenerate synthetic audio after changing the
manifest or macOS voice.

Do not interpret the synthetic corpus as accuracy measurements. An external
real-speech result is directional when it is a small subset (for example, 17
utterances from two speakers); use a larger, consented Taiwan Mandarin/English
speech set before making quality, WER, or release-mode claims.
