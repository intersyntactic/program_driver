# Changelog

## 0.1.0 (unreleased)

- `ProgramDriver`: a service on a Unix socket, answering only its caller's
  user, that starts programs under one root and streams a run's
  `ProgramMessage`s. Closing it kills every program still running.
- `ProgramDriverSocket`: the airlock's side of that socket, its
  `RunsPrograms`.
- Requires is_effects `^0.12.0`, the version the airlock depends on.
- `ProgramDriver.start` takes its caller as a `UserId` from
  is_unix_socket_user_check, so uids that can never be a caller (the overflow
  uid, `(uid_t)-1`) are refused at the boundary, and allows a connection only
  when the kernel names its user.
