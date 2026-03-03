#!/usr/bin/env bash
set -euo pipefail

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
cd "$ROOT"

echo "[check] scanning for obvious embedded secret patterns"
if rg -n --hidden -S "BEGIN (RSA|EC|OPENSSH|PRIVATE) KEY|AWS_SECRET|S3_SECRET|JWT_SECRET|MASTER_KEY|CALL_RELAY_SECRET" Sources README.md AUDIT_SCOPE.md SECURITY.md SNAPSHOT_METADATA.md TEST_PLAN.md >/dev/null; then
  echo "[fail] secret-like pattern found"
  exit 1
fi

echo "[check] required files"
for f in Sources/WhisperModels.swift Sources/WhisperVoiceStream.swift Sources/WhisperVideoStream.swift Sources/WhisperOpusCodec.swift Sources/WhisperH264Decoder.swift Sources/KSMPCallModels.swift; do
  [[ -f "$f" ]] || { echo "[fail] missing $f"; exit 1; }
done

echo "[check] media symbols presence"
rg -n "Opus|H264|WhisperVoiceStream|WhisperVideoStream" Sources/*.swift >/dev/null

echo "[ok] audit sanity checks passed"
