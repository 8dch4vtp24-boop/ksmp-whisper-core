# Audit Scope

## In scope

- Voice pipeline implementation details (`WhisperVoiceStream`)
- Video capture/encode/decode transport layer (`WhisperVideoStream`, `WhisperH264Decoder`)
- Opus codec wrapper logic (`WhisperOpusCodec`)
- Protocol model schema used by Whisper call/control events

## Out of scope

- Backend relay implementation
- TURN/edge/network orchestration
- Business logic not directly related to Whisper media/protocol models

## Security assumptions

- Media payload cryptographic protection and key schedule live in the chat/session layer.
- This repository focuses on media transport and protocol model transparency.
