# Call Companion

This file is a router, not a store. Facts and procedures go in the relevant docs; keep one-line pointers here. `AGENTS.md` links to this file.

## Universal rules

- Follow the current user request and preserve existing work. Quote paths: the checkout name contains a space.
- Keep call audio, real transcripts and private project files out of source control. Use synthetic or explicitly cleared material for tests and demonstrations.
- Preserve the distinction between local audio processing and selected text sent to Codex. Do not claim unmeasured recognition quality or suggestion accuracy.
- Run `bash test.sh` and `bash build.sh` for relevant source/build changes. The ordinary tests do not use the microphone or a real model account.
- Preserve the existing app identifier and preferences unless the user requests an identity migration.

## Where things live

| Path | Covers | Read when |
| --- | --- | --- |
| `README.md` | Setup, workflows, data boundaries, architecture and project location | Before implementation or release work |
| `ProjectContext.swift`, `ProjectContextTests.swift` | Local retrieval, exclusions, budgets and PDF handling | Changing project context |
| `SpeechCapture.swift`, `Models.swift`, `TranscriptionBenchmark.swift` | Audio capture, transcript merging and same-audio comparison | Changing transcription |
| `AnswerEngine.swift`, `AnswerEngineTests.swift`, `assistant-instructions.md`, `answer.schema.json` | Isolated Codex requests and grounded suggestions | Changing model behavior or process boundaries |
| `CompanionModel.swift`, `App.swift` | Call lifecycle and native UI | Changing interaction or cancellation |
| `Fixtures/Transcription/README.md` | Benchmark plan, consent-safe capture and reference creation | Measuring recognition quality |
| `build.sh`, `test.sh`, `refresh-instructions.py`, `Resources/` | Local packaging, verification and app assets | Building or updating the app |
| `~/Second Brain/Projects/Call Companion/Call Companion Hub.md` | Cross-session status and history | Before project work; update after meaningful changes |
