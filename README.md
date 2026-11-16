# is_program_driver

intersyntactic's `ProgramDriver` (from [is_effects](https://github.com/intersyntactic/effects)):
it starts the programs the airlock has decided, such as `git` or `dart`, and
reports what each prints while it runs, then how it ended.

It runs as a service of its own, as the journey's OS user (`journey-N`), so a
program it starts can do what that user can and no more. Each driver is a wall
of its own: it answers only the airlock's user, read from the socket as the
kernel reports it, never from the request.

## The wire

One connection per run, one JSON value per line, with the codecs from
is_effects:

- the caller sends `encodeStart(program, args)` and closes its side;
- the service answers a `Reported` for each piece the program prints, as it
  prints it, then one `Finished` with the outcome, and closes.

`SocketProgramDriver` is that caller, for the airlock.

## Running it

systemd starts it once per journey user, from `program-contained@.service`
and `program-open@.service` (infra's), which set:

- `PROGRAM_DRIVER_SOCKET`: where it listens, inside its `RuntimeDirectory`;
  it makes the socket `0660`, so the journey user's group, which the airlock's
  user is in, can reach it;
- `PROGRAM_DRIVER_CALLER`: the one user, by name or id, whose starts it
  carries out;
- `PROGRAM_DRIVER_ROOT`: `/home/%i`; every run's folder must resolve inside it.
