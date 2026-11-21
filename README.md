# is_program_driver

intersyntactic's `RunsPrograms` (from [is_effects](https://github.com/intersyntactic/effects)):
it starts the programs the airlock has decided, such as `git` or `dart`, and
reports what each prints while it runs, then how it ended.

`ProgramDriver` is a service of its own, run as the OS user a trajectory's
agent wears: a suit (`suit-N`), an identity the agent puts on, so a program it
starts can do what that suit can and no more. One agent wears a suit at a time, and its home
is wiped between wearers. Whether it is sealed is chosen when it is worn: a
contained trajectory's driver starts from `program-contained@.service`, which
cuts the network off, and an open trajectory's from `program-open@.service`,
visor up. Infra keeps the pool and hands the suits out. Each driver is a wall
of its own: it answers only the airlock's user, read from the socket as the
kernel reports it, never from the request.

## The wire

One connection per run, one JSON value per line, with the codecs from
is_effects:

- the caller sends `encodeProgramToRun(program, args)` and closes its side;
- the service answers a `Reported` for each piece the program prints, as it
  prints it, then one `Finished` with the outcome (`encodeProgramMessage`
  with `encodeExecResult`), and closes.

`ProgramDriverSocket` is that caller, for the airlock.

## Running it

systemd starts it once per suit, from `program-contained@.service`
and `program-open@.service` (infra's), which set:

- `PROGRAM_DRIVER_SOCKET`: where it listens, inside its `RuntimeDirectory`;
  it makes the socket `0660`, so the suit's group, which the airlock's
  user is in, can reach it;
- `PROGRAM_DRIVER_CALLER`: the one user, by name or id, whose programs it
  runs;
- `PROGRAM_DRIVER_ROOT`: `/home/%i`; every run's folder must resolve inside it.
