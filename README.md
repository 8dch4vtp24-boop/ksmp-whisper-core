# ksmp-whisper-core (public audit snapshot)

This repository contains a public audit snapshot of Whisper StreamVoice and
protocol-adjacent client components used by Kasty.

## Scope

Included:
- `Sources/WhisperModels.swift`
- `Sources/WhisperVoiceStream.swift`
- `Sources/WhisperVideoStream.swift`
- `Sources/WhisperOpusCodec.swift`
- `Sources/WhisperH264Decoder.swift`
- `Sources/KSMPCallModels.swift`

Excluded:
- Backend/services and deployment code
- Credentials and environment-specific values
- Unrelated app/UI modules

## Purpose

- Independent technical review of media transport primitives and protocol models
- Better transparency for encryption and call-media pipeline claims

## Integrity

Regeneration from the main monorepo:
- `scripts/export_from_kasty.sh`

## License

Source-available for audit and research only.
See `LICENSE`.
