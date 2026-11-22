# Changelog

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
