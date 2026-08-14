# Host baseline test failures implementation

## Current evidence

The 2026-08-14 host baseline reproduced two portable failures and two real-Herdr failures.
The installed Pi 0.84.0 runtime calls a markdown-transformer method from its stock user-message path, while the Calm test's partial interactive-mode fixture did not provide that method.
After that fixture reached the live export path, the test twice waited six seconds for a completion status that never remained visible.
Five manual Calm-on exports on Pi 0.84.0 completed their durable HTML artifacts in 29, 30, 33, 37, and 41 milliseconds, while every final screen showed `Tool output: collapsed` instead of the transient export status.
The command was fast and consistent, so this was an assertion-observation defect rather than a slow or hanging Pi export.
The installed default Python is 3.9.6 and cannot import `tomllib`, while the Kimi hook intentionally requires `python3` with `tomllib` before it edits global configuration.
The installed Herdr 0.7.5 pane bootstrap did not reach every strict lone-idle-shell condition within the production ten-sample settle deadline, so the production proof correctly refused the pane-death cleanup path.
Live sampling showed the fresh pane transition through one to seven reported foreground processes, running and sleeping shell states, and transient child processes before settling.
The real-Herdr concurrency test observed the two simultaneous task workspaces in the opposite relative order from its call-log-derived expectation while preserving the required primary block, secondmate order, and focus.
After correcting that scheduler-derived assertion, the live layout still placed all projected primary children after both secondmates, proving that the owning block itself was broken.
The spawn path already serializes projected creation and placement under one named-session lock and passes the exact created workspace identifier plus desired owning-block index to a narrow `workspace.move` transport.
The installed Herdr session socket path was 108 to 110 bytes, and Python's absolute AF_UNIX connection failed with `AF_UNIX path too long` before Herdr received the requested move.
A counterfactual connection from the already-validated socket directory using only `herdr.sock` succeeded and Herdr immediately returned and retained the requested owning-block order.
The defect therefore belongs to Firstmate's socket transport rather than Herdr's ordering implementation.

The remote lifecycle history shows that one five-second inheritance wait was already increased to 30 seconds when the remote job worker added readiness and earlier inheritance stages.
A second five-second wait remained and reproduced under host load while the worker process was still alive and progressing.
That is a premature timing assertion rather than evidence that two inheritance writers entered their critical section together.

The remote trace-context test passed on this host in 72 seconds when its remote job queue, execution, and grace windows were explicitly reduced to 5, 10, and 2 seconds.
Without test-local values it inherits production windows of 360, 360, and 30 seconds for every remote command, allowing repeated stalls to accumulate into hours.
The first complete-suite run executed 119 tests in 4,455 seconds and reproduced two additional watcher assertion races after every listed baseline case had passed or self-skipped.
The dead-agent pause fixture sometimes killed its first watcher after the durable wake was appended but before the matching throttle marker was committed, which either erased the proof under load or caused the next round to emit a duplicate.
The healthy-peer fixture could send `SIGTERM` before its Node peer installed the intended ignore handler, so the peer died and a replacement watcher correctly started instead of being attached.
Both watcher production paths passed independently; the failures belonged to their fixture synchronization.
The next complete-suite run exposed one more assertion race in the remote-job queue test.
The worker correctly writes a fresh execution deadline only after claiming a queued job, but that deadline also correctly bounds tracked-command validation before the payload starts.
The fixture gave its second payload a three-second execution window and deliberately slept for 1.8 seconds, leaving too little margin for whole-second deadline truncation plus validation under full-suite load.
This was not evidence that queue time consumed the execution window.

## Transition from current behavior

The Calm fixture will provide the current stock markdown-transformer dependency while continuing to execute Pi's real installed rendering path.
This changes only the fixture shape and preserves the compatibility assertion.
The live export assertion will wait for the completed HTML document instead of an ephemeral status line that Calm's redraw replaces.
Its existing six-second deadline remains unchanged because the measured Pi 0.84.0 operation completed in at most 41 milliseconds.

The Kimi suite will probe the exact default `python3` dependency before any test setup.
When `tomllib` is unavailable, it will emit a self-explaining environment skip naming the interpreter version and the requirement.
Compatible hosts will continue to execute every Kimi assertion.

The Herdr focus-flash suite will call the production idle-shell proof against a fresh named-lab pane before claiming that the pane-death mitigation is exercisable.
An incompatible live settle window will produce a behavior-derived skip that names the installed Herdr version, production sample deadline, and final foreground-process count.
Supported hosts will continue through the explicit-close reproduction and mitigation assertions.

The Herdr concurrent-order assertions will compare exact member sets and owning-block boundaries while allowing either concurrent worker to win first.
Existing exact-ID move targets, contiguous insert indexes, secondmate relative order, and focus assertions remain authoritative.
The raw workspace mover will resolve the validated absolute socket directory and connect by the short socket basename, avoiding Darwin's AF_UNIX address-length ceiling without changing the exact `workspace.move` request.
A focused regression will bind a socket from a relative name whose absolute path exceeds the platform ceiling and verify the exact request and response.
The same real-Herdr run exposed a separate five-second presentation-lock race during exact-husk recovery.
The production lock wait will remain bounded but increase to 30 seconds, while the two explicit contention fixtures pin the old five-second window so fallback coverage stays fast and intentional.

The remaining remote inheritance poll will use the same 30-second loaded-runner deadline as the equivalent spawn and launch polls.
The test still fails if the worker exits early or never reaches the deliberately blocked write.

The remote trace-context fixture will set short test-local queue, execution, and grace deadlines at its SSH boundary.
Those values leave the normal observed path unchanged and bound a stalled command to 17 seconds rather than 750 seconds.

The dead-agent pause fixture will wait for both halves of the production transaction, the durable wake and its throttle marker, before ending the first watcher and starting unchanged rounds.
The healthy-peer fixture will publish an explicit ready file after installing its signal handler before the restart begins.
The original one-second watcher confirmation bound remains unchanged because the defect was peer readiness, not slow confirmation.

The remote-job regression will queue its second job for longer than that job's entire three-second execution budget, then run a near-instant payload.
This continues to fail any implementation that consumes the execution budget while queued, while leaving legitimate validation comfortably inside the fresh post-claim deadline.

## Verification

Each previously failing test will be rerun directly through the canonical test runner.
The Herdr tests will run only inside guarded named non-default labs and must preserve the default-session fleet tripwire through teardown.
The remote lifecycle test will be repeated to exercise the former timing flake as a scheduling-sensitive transition.
The complete suite will then run on this host, with every remaining environment limitation required to appear as an explicit skip reason.
The documentation audience check and repository lint passed before commit.
The corrected dead-agent pause suite passed in 177.4 seconds, and the corrected watcher-lock suite passed in 114.6 seconds with its original confirmation bound.
The corrected remote-job suite passed three consecutive focused runs in 48.43, 47.55, and 48.92 seconds, then passed under complete-suite load in 47.61 seconds.
The final host suite ran all 119 tests in 3,972.159 seconds with zero failures and 14 explicit gate skips.
In that run the Pi Calm test passed in 49.59 seconds, Herdr presentation passed in 394.95 seconds, remote lifecycle passed in 337.17 seconds, remote trace context passed in 79.32 seconds, watcher triage passed in 168.25 seconds, and watcher lock passed in 112.29 seconds.
