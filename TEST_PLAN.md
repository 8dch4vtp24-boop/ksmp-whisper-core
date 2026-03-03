# Test Plan (Audit-Focused)

## Goal

Verify that call/media protocol-adjacent snapshot remains stable and free from
obvious secret leaks.

## Checks

1. Run `scripts/export_from_kasty.sh` and ensure the same source set is exported.
2. Run `scripts/audit_sanity_checks.sh` (secret-pattern guard + required file checks).
3. Re-generate `MANIFEST.sha256` and compare changes.
4. Validate presence of voice/video/media files (`WhisperVoiceStream`, `WhisperVideoStream`, `WhisperOpusCodec`, `WhisperH264Decoder`).
5. Validate call model schema file (`KSMPCallModels.swift`) remains included.

## Pass Criteria

- Export and sanity checks complete successfully.
- No obvious secret patterns are found.
- Manifest drift is explainable by intentional source updates only.
