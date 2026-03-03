#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/../../.." && pwd)"
OUT_DIR="$(cd "$(dirname "$0")/.." && pwd)"

cp "$ROOT/Kasty2/Models/WhisperModels.swift" "$OUT_DIR/Sources/"
cp "$ROOT/Kasty2/Helpers/WhisperVoiceStream.swift" "$OUT_DIR/Sources/"
cp "$ROOT/Kasty2/Helpers/WhisperVideoStream.swift" "$OUT_DIR/Sources/"
cp "$ROOT/Kasty2/Helpers/WhisperOpusCodec.swift" "$OUT_DIR/Sources/"
cp "$ROOT/Kasty2/Helpers/WhisperH264Decoder.swift" "$OUT_DIR/Sources/"
cp "$ROOT/Kasty2/Models/KSMPCallModels.swift" "$OUT_DIR/Sources/"

(cd "$OUT_DIR" && find . -type f ! -path './.git/*' ! -name 'MANIFEST.sha256' | LC_ALL=C sort | xargs shasum -a 256 > MANIFEST.sha256)

echo "ksmp-whisper-core export refreshed (MANIFEST.sha256 updated)."
