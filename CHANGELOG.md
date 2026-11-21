# Changelog

## 0.1.0 (unreleased)

- `ProgramDriver`: a service on a Unix socket, answering only its caller's
  user, that starts programs under one root and streams a run's
  `ProgramMessage`s. Closing it kills every program still running.
- `ProgramDriverSocket`: the airlock's side of that socket, its
  `RunsPrograms`.
- Requires is_effects `^0.12.0`, the version the airlock depends on.
