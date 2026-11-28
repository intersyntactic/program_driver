# Changelog

## 0.5.0

- BREAKING for Dart callers: depends on is_program_request_vocabulary
  `^0.1.0` and is_outcome_vocabulary `^0.1.0` in place of is_effects, so
  `ProgramName` and the other types it takes and returns come from those
  packages. A report is a `Printed` and a message is
  `ProgramMessage<Printed, ExecResult>`.
- The wire is unchanged: every key and `kind` is the same, so a 0.5.0
  driver can run beside an airlock still on is_effects.

## 0.4.1

- Requires is_effects `^0.17.0`. Its wire is the same as 0.15's, so a
  0.4.0 and a 0.4.1 driver answer byte for byte alike, and either can run
  beside an airlock on 0.15 or 0.17.

## 0.4.0

- BREAKING: a program that never started (a request too large, not a
  start, a program not installed, or one the executor could not start)
  ends `NothingRan(why)`, not `Refused(why)`. On the wire the outcome's
  kind is `"nothingRan"`; each `why` is unchanged. A reader on is_effects
  0.14 cannot decode it, so the airlock must run is_effects 0.15 first.
- Requires is_effects `^0.15.0`.

## 0.3.1

- `close()` and the output limit kill a run through is_executor's
  `Running.kill()`: the group and the process itself, then the group again
  until it is empty. 0.3.0 sent one signal to the group, and only once the
  program had reported its pid, so a program started just before `close()`
  ran on; `close()` now also waits until every run is gone.
- A run killed by `close()` ends `Killed("killed as the program driver
  stopped")`.
- The output limit is is_executor's (`maxOutputBytes` on `start`, each
  channel on its own): the driver no longer counts or cuts what a program
  prints itself. What it keeps, reports and answers is unchanged.
- Requires is_executor `^0.3.0`.

## 0.3.0

- BREAKING: `ProgramDriverSocket`, `OutcomeUnknown` and
  `InstalledProgramsUnknown` are gone; the airlock writes its own caller.
  The request is is_effects' `ProgramRequest` (`RunProgramRequest`,
  `ListInstalledProgramsRequest`, `encodeProgramRequest`,
  `decodeProgramRequest`). The wire is unchanged.
- Finds `stat`, `chmod` and `id` in `/usr/bin` or `/bin` only, never on the
  PATH, so a `stat` placed earlier on the PATH can no longer vouch for a
  programs folder; without one of them the service exits 78.
- Says on stderr why it turned a peer away (`refused a peer: …`).
- Requires is_effects `^0.14.4` and is_unix_socket_user_check `^0.2.1`.

## 0.2.2

- The service exits 78, not 255, when the programs folder cannot be listed
  or a path's owner cannot be read: `InstalledPrograms.read` throws
  `UnsafeProgramsFolder` for both, so a restart policy that skips 78 leaves
  them stopped.
- Requires is_effects `^0.14.3`.

## 0.2.1

- Kills a program's group by sending the signal itself
  (`Process.killPid` on the negated pid) instead of running the `kill`
  program, which a box without procps does not have. On such a box 0.2.0
  could not kill a program past its output limit, and `close()` threw.
- Requires is_effects `^0.14.2`.

## 0.2.0

- BREAKING: runs only the programs in the box's programs folder
  (`PROGRAM_DRIVER_PROGRAMS`, read once into `InstalledPrograms`), never one
  found on the PATH; any other name is `Refused`. It will not start with a
  folder its own user could change.
- BREAKING: requests are tagged. `{"kind": "run", "programToRun": …}` runs
  a program; `{"kind": "list"}` answers the installed programs' names.
- `ProgramDriverSocket` implements is_effects' `ListsInstalledPrograms`:
  `installedPrograms()` is the programs the driver runs.
- Requires is_effects `^0.13.0`.
- A program that prints more than `maxOutputBytes` on stdout or stderr
  (`PROGRAM_DRIVER_MAX_OUTPUT_BYTES`, 8 MiB unless set) is killed with its
  group and ends `Killed`, keeping that much, cut where a character ends.

## 0.1.0

- `ProgramDriver`: a service on a Unix socket, answering only its caller's
  user, that starts programs under one root and streams a run's
  `ProgramMessage`s. Closing it kills every program still running.
- `ProgramDriverSocket`: the airlock's side of that socket, its
  `RunsPrograms`.
- `ProgramDriver.start` takes its caller as a `UserId` from
  is_unix_socket_user_check, and a connection whose user the kernel can't
  name is turned away. The service exits 78 when `PROGRAM_DRIVER_CALLER`
  resolves to a uid that names no one user (65534, 4294967294, 4294967295).
- Requires is_effects `^0.12.0`, the version the airlock depends on.
