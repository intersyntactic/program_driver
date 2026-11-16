# Changelog

## 0.1.0 (unreleased)

- `ProgramDriverService`: the program driver as a service on a Unix socket,
  answering only its caller's user, streaming a run's `ProgramMessage`s.
- `SocketProgramDriver`: the airlock's side of that socket.
