# Changelog

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
