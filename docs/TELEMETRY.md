# Pindrop Diagnostics

Last updated: 2026-10-05

Pindrop is a privacy-first dictation app. It has no telemetry, sends no usage data,
and collects no training data.

This document is the complete description of what Pindrop stores beyond your
transcripts and settings. If a field is not listed here, Pindrop does not collect it.

---

## Diagnostics logs

Pindrop writes local log files
(`~/Library/Application Support/Pindrop/Logs/`, rotated, capped). Log messages are
redacted at write time — transcript text is never logged. **Open Logs in Finder**
in Settings → About reveals the folder so you can attach them to a GitHub issue. Logs never leave your machine unless you send them.
