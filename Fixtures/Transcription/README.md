# Transcription benchmark fixtures

This manifest defines 12 consent-safe clips for comparing transcription backends on identical audio. It contains scripts and scoring terms, but no recordings or claimed references yet.

For each clip:

1. Record only synthetic material with informed participants.
2. Keep audio outside the repository under a local `audio/` folder.
3. Hash the recorded file, set `status` to `recorded`, set `consentStatus` to `informed-participants`, and update its local audio path and hash in the manifest.
4. Have a human create the verbatim reference after capture and before viewing any model output. Do not copy the script as the reference without checking what was actually said. Set `status` to `reference-ready` only after that review.
5. Run every backend against the same file. Store generated output under `results/`.

The clean and phone-speaker clips share a `pairId`. Record the clean version first, then replay that exact recording through the phone at the real call distance and volume. This isolates capture loss from recognizer loss.

The normal test suite only validates this plan. It does not record audio, open the microphone, download speech models, or run transcription.
