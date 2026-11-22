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

One connection per request, one JSON value per line, with the codecs from
is_effects. The caller sends one request and closes its side:

- `{"kind": "run", "programToRun": encodeProgramToRun(program, args)}`: the
  service answers a `Reported` for each piece the program prints, as it
  prints it, then one `Finished` with the outcome (`encodeProgramMessage`
  with `encodeExecResult`), and closes;
- `{"kind": "list"}`: the service answers one line, the names of the
  programs it runs as a sorted list, and closes.

Anything else is answered with a `Finished` whose outcome is
`Refused("not a start: …")`. `ProgramDriverSocket` is that caller, for the
airlock.

## The programs it runs

It runs only the programs in the box's programs folder, never one found on
the PATH. Each entry is named after its program and is that program or a
symlink to it: `ln -s /usr/bin/git programs/git`, or a binary put there
whole. The folder is read once, as the driver starts, so the list
loop_launcher checks a trajectory against as it starts it is the list the
driver keeps to.

It will not start if its own user could change what runs: if that user
owns, or anyone besides the owner may write, the folder, an entry's
program, or any folder above either. A suit's home is the suit's, so no
entry may lead there.

The list says what the airlock may ask for; it confines nothing. The suit
is the wall: a listed `sh`, `dart` or `git` can do anything the suit can.

## Running it

systemd starts it once per suit, from `program-contained@.service`
and `program-open@.service` (infra's), which set:

- `PROGRAM_DRIVER_SOCKET`: where it listens, inside its `RuntimeDirectory`;
  it makes the socket `0660`, so the suit's group, which the airlock's
  user is in, can reach it;
- `PROGRAM_DRIVER_CALLER`: the one user, by name or id, whose programs it
  runs;
- `PROGRAM_DRIVER_ROOT`: `/home/%i`; every run's folder must resolve inside it;
- `PROGRAM_DRIVER_PROGRAMS`: the box's programs folder, which the box's
  install fills. It is required: without it, or with a folder it will not
  start with, it exits 78.
