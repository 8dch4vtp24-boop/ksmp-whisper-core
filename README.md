# ksmp-whisper-core (public audit snapshot)

Public source-available snapshot of KSMP Whisper / WhisperStreamVoice
client-side media and call-model components.

## What this snapshot guarantees (in scope)

- Exported files cover protocol-adjacent media primitives for external review.
- Snapshot is sufficient to inspect voice/video pipeline-adjacent implementation surface.
- No deployment credentials or private infrastructure config are included.

## Included files

- `Sources/WhisperModels.swift`
- `Sources/WhisperVoiceStream.swift`
- `Sources/WhisperVideoStream.swift`
- `Sources/WhisperOpusCodec.swift`
- `Sources/WhisperH264Decoder.swift`
- `Sources/KSMPCallModels.swift`

## Out of scope

- Backend relay implementation and network edge orchestration
- TURN/infra private topology
- Product modules unrelated to KSMP Whisper call/media review

## How to verify snapshot integrity

1. Refresh export: `scripts/export_from_kasty.sh`
2. Run sanity checks: `scripts/audit_sanity_checks.sh`
3. Verify checksums: compare files with `MANIFEST.sha256`

## Metadata and audit docs

- Snapshot metadata: `SNAPSHOT_METADATA.md`
- Audit scope: `AUDIT_SCOPE.md`
- Audit test plan: `TEST_PLAN.md`
- Security reporting: `SECURITY.md`

## License

Source-available for audit and research only (rights holder: Kasty Vladimir Usanov).
Reuse, redistribution, commercial use, and open-source integration are prohibited
without separate written permission.
See `LICENSE`.
