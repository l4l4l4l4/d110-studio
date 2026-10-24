# Foreground printer reconnection

The owner requested continuous saved-printer discovery/reconnection while the app is open, including a printer switched on after launch.

The controller now schedules non-overlapping attempts three seconds after transient failures, pauses in the background or for manual selection, and resumes on foreground/adapter recovery. Passive connection never requests permission, enables Bluetooth or replays printing. The editor remains usable during passive I/O. Explicit disconnection pauses recovery until an explicit connection or the next foreground resume; newer adapter-loss states take precedence over operation completion.

The patch changes the connection controller, client/native permission contract, lifecycle/picker/editor integration and regression tests. README documents the behavior. Behavioral regressions covered late power-on, single-flight recovery, permission changes, explicit disconnection and adapter event ordering. The final standalone check passed all 178 tests with clean formatting and analysis, including delayed disconnect completion after a newer radio-loss event. Independent code and security review found no remaining blockers after the reproduced defects were fixed. Actual native radio/late-power-on behavior still requires the new signed Android CI APK; no new physical print was sent.

The transcript is a limited relevant-message excerpt, not a complete harness capture. The manifest binds the submission to its code tree and the canonical pohuy digest. The checker verifies form/digests, not client honesty; signing and publication are independently observable.
