# Call Companion

A local macOS app that transcribes calls through the Mac microphone and displays short, private suggestions. Choose any project folder and describe the call; the companion finds relevant excerpts locally and uses them to ground answers. General calls also work without a project. This is a standalone project. It has no fixed project context and does not depend on another repository.

**Experimental developer preview.** Build from source on your own Mac. Real-audio transcription quality, grounded-suggestion accuracy and microphone-to-suggestion latency have not been measured. All 12 benchmark clips remain planned, with no recordings or human-verified references. Passing synthetic tests verifies selected code paths and the benchmark plan, not real-call performance. The source is available under the [MIT license](LICENSE).

## Use

1. Open `~/Applications/Call Companion.app`, or `.build/Call Companion.app` after building.
2. Choose a **Project** from the dropdown (folders under `~/Projects` plus recent choices), or use the folder button to choose another location. **General call** uses no project files. Every launch starts in general mode; recent folder paths are remembered, but their contents are not automatically loaded.
3. Write a short **What is this call about?** brief: who you are meeting, topics, and what you want to learn. Spell uncommon names, acronyms and product terms carefully; the app prioritizes distinctive terms from this brief during recognition. For example, “A customer discovery call with Nia Okafor about XR-17 onboarding. Understand where people get stuck and discuss the current roadmap.”
4. **Review context** shows the excerpts selected from that folder. **Exclude** removes a file for the current project selection; **Restore excluded files** includes it again. **Refresh files** reindexes after edits. Brief and conversation changes rerank the in-memory index; they do not silently reread files from disk.
5. Put your phone on speaker beside the Mac and let every participant know you are using transcription. Click **Start listening**, review the disclosure, confirm that everyone has been told, and allow microphone access. The acknowledgement lasts until you choose **New call**, switch projects, or quit; pause/resume keeps it for the same call. It does not verify consent or determine whether use is lawful. Check the input meter and visible transcript. The app captures the microphone, not a direct Zoom/Teams/system-audio stream.

**Auto help** checks new speech after a pause, at least 10 seconds between requests. Long utterances are checked after about 20 seconds. It stays quiet for greetings and discussion that needs no help. **Help now / ⌘Return** answers your typed question, or the latest conversation. The call brief and latest speech guide fresh reference selection for every answer. Source labels identify supplied files, general knowledge, or unsupported facts.

**⌘L** starts or pauses listening. **Cancel** stops a pending answer. **Keep on top** keeps suggestions visible. Earlier answers remain in the picker. **Pause listening** stops capture and cancels a pending answer. Closing the app releases the microphone. **Save notes** explicitly writes the brief, transcript and suggestions to a chosen text file. **New call** clears conversation/answers and the acknowledgement while paused, and keeps the project/brief. Changing projects after a conversation asks to start a new call and clears the old transcript, answers and brief; choosing a project before a conversation preserves draft inputs.

## Retrieval and limits

Search uses local term, filename, heading and phrase relevance, with excerpts labeled by line or PDF page. It is lexical retrieval, not semantic embeddings. With no useful matches, README/router/overview files are preferred. Only selected files are indexed; linked documents outside the chosen folder are not followed. Only up to seven files and 22,000 characters of reference paths/excerpts enter an answer request. Review shows the current preview or the latest request's excerpts; selection can change as the conversation changes.

Supported: UTF-8 Markdown, text, common source/config files, CSV/TSV, and text-extractable PDFs. Word/Excel/PowerPoint files, images and scanned PDFs are not extracted; export relevant content to text or PDF first. There is no OCR. Hidden files, dependency/build/cache folders, generated output, credential-like filenames and symlinks are excluded. Text files are also checked for recognized private-key markers; extracted PDF text currently bypasses that check. These filters do not guarantee that ordinary documents contain no sensitive material; review/exclude sources when needed.

Bounds: 700 indexed files; 16 MB extracted text total; 1.5 MB per text file; 12 MB per PDF; 180 PDF pages; depth 12; 16,000 visited entries. Large folders can have incomplete coverage. The context panel reports skipped files, caps, unsupported content and read failures. Indexing and retrieval run off the UI thread and support cancellation. Switching project generations discards stale work.

## Data and model

- Apple `SpeechAnalyzer` / `SpeechTranscriber` handles audio on this Mac. The live path uses volatile partial results without Apple's faster, less-accurate `fastResults` option. The English model may download from Apple on first use. The app does not save or upload audio.
- Call brief, transcript excerpts, recent suggestions, project name and selected reference excerpts are sent to Codex using the existing signed-in account and its usage limits. Selecting/indexing a folder alone makes no model request.
- Briefs, indexed file content, transcripts and suggestions stay in memory until **Save notes**. Only recent folder paths are saved in preferences. Codex runs with `--ephemeral`; provider handling remains governed by account policies.
- Each request runs in an empty temporary directory with read-only sandbox, no user configuration, project instructions, plugins or MCP servers; shell, browser, computer-use, hooks and multi-agent features are disabled. The model receives excerpts rather than filesystem tools. Speech and file contents are data, not authorization to execute actions.
- The selected Codex model is read from user config without copying credentials. Low reasoning effort and a 55-second deadline keep requests bounded. Authentication/network failures disable Auto help. Cancel terminates the ephemeral subprocess.
- No voice output, meeting bot, participant contact, speaker diarization, or direct audio stream into the currently open Codex conversation. Transcription can mishear words and suggestions can be wrong.

## Build and test

Requires Apple Silicon, macOS 26+, a Swift toolchain and macOS SDK supporting SpeechAnalyzer, plus `codex` on PATH with an existing login. The current invocation was checked against Codex CLI 0.160.0. No npm dependencies or API key.

```bash
git clone https://github.com/mctatge/call-companion.git
cd call-companion
bash build.sh
open '.build/Call Companion.app'
bash test.sh
```

The build uses the selected Xcode compiler/SDK directly; `SWIFTC`, `SDKROOT`, and `CODEX_BINARY` can override paths. The bundle records only the Codex executable location, not a repository path. Rebuild if Codex moves. The existing bundle identifier `co.margilo.call-companion` is retained so the folder change does not create a new app identity or preferences namespace. The app is locally ad-hoc signed, not notarized.

`test.sh` runs synthetic retrieval, budget, PDF, exclusion, cancellation, process-isolation, response-decoding and transcript-merging tests. It does not use the microphone or a real model account. For optional integration checks after building the smoke runner:

```bash
./.build/smoke --speech
./.build/smoke --answer './.build/Call Companion.app/Contents/Resources' 'What should I ask on a kickoff call?'
```

`--speech` checks/prepares the speech model without activating the microphone. `--audio PATH` transcribes a synthetic file containing “spreadsheet”. `--answer RESOURCES QUESTION [--project FOLDER]` makes a real Codex request and uses account usage; use synthetic project content for testing. Speech/model diagnostics need the normal macOS environment outside restricted agent sandboxes.

To compare the former fast configuration with the current live configuration on exactly the same file, run:

```bash
./.build/smoke --benchmark-audio /path/to/consent-safe.wav \
  --pace realtime --context 'Asteria,XR-17,Nia Okafor' \
  --output /path/to/result.json
```

The benchmark reopens the same file for `speech-fast` and `speech-accurate`, uses the live conversion bridge, and records the input hash, raw recognizer events, final-only transcript and timing. `--pace realtime` approximates live buffer arrival; `--pace offline` measures throughput and reports a real-time factor. It never requests microphone access. The output is raw recognizer evidence, not the UI's merged transcript. `Fixtures/Transcription/manifest.json` defines the planned 12-clip clean/phone/noise/overlap comparison; audio and generated results stay outside version control.

There is no automated accuracy scorer or end-to-end suggestion-latency benchmark yet. The two recognition modes run once in a fixed order, so timing comparisons can include model-warming and order effects. Record consent-safe clips, create human references before inspecting recognizer output, and repeat runs in alternating order before claiming a quality or speed improvement.

`refresh-instructions.py` updates the built bundle's prompt; every subsequent answer rereads it. Re-sign afterward with `codesign --force --sign - --identifier co.margilo.call-companion './.build/Call Companion.app'`. An installed copy must be updated separately.

Implementation: `ProjectContext.swift` owns local indexing/ranking; `SpeechCapture.swift` owns audio; `Models.swift` merges hypotheses; `AnswerEngine.swift` owns isolated model requests; `CompanionModel.swift` owns call/context lifecycle; `App.swift` owns native UI. Prompts and JSON schema are separate files. Preserve the compact native setup strip and the large answer/smaller transcript hierarchy; use the existing plum/neutral palette, native controls and 4px spacing rhythm.

## Known issues

- **PDF screening:** extracted PDF text bypasses the private-key-marker check applied to text files. A synthetic marker was retrievable from a PDF while its text-file equivalent was excluded. Review PDF excerpts before requesting suggestions; exclude files that contain sensitive material.
- **Source selection:** the brief, question and recent conversation share one lexical query. In a synthetic mixed-topic fixture, a broad brief displaced the file answering the explicit question. Keep the brief focused and check the selected excerpts; source-selection reliability has not been measured on real calls.
- **Pause:** pausing cancels pending recognition instead of draining and finalizing accepted audio. Buffered words or corrected final text can be lost, and the latest partial hypothesis can remain in notes or suggestions.
- **Cancel:** canceling a manual request clears its typed question instead of restoring it. This was reproduced with a mock answer process.
- **Benchmark failures:** failed runs discard accumulated events and timing fields. Empty failed records do not establish that the recognizer produced no speech. Offline feeding also uses an unbounded audio queue and lacks cancellation checks inside the feed loop; use short clips.
- **Citations:** prompt instructions request citations to supplied files, but returned source strings are not checked against those paths. A source label alone does not establish that an answer is supported.
- **Setup:** the app records an external Codex executable path at build time. Rebuild if it moves. `test.sh` currently assumes the full Xcode toolchain layout unless compiler and SDK paths are supplied explicitly. Clean-machine setup has not been verified.

## App icon

`Resources/AppIcon.png` is the generated transparent source; `Resources/AppIcon.icns` contains the macOS icon sizes. The exact built-in imagegen prompt is preserved in `Resources/AppIcon.prompt.txt`. `build.sh` always packages the icon and sets `CFBundleIconFile`, so rebuilding keeps the Dock/Finder icon. The installed app is `~/Applications/Call Companion.app`.

## Project location

The source project became independent on 2026-10-07 and can be cloned to any local folder. Build and test scripts resolve their inputs relative to their own location. Build output stays in `.build/`; fixture recordings and benchmark results are ignored. An installed app can run after the source folder moves, provided its recorded Codex executable remains available.

This is a source preview, with no supported consumer installer or notarized binary release. Clean-machine setup verification, a demonstration and representative real-audio measurements remain open. Keep call audio, real transcripts, exported notes, generated benchmark output and private project files out of commits.
