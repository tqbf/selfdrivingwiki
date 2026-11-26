# Troubleshooting

The `wikid` daemon owns all wiki data. The app, the `wikictl` command, and the
Finder projection are clients. They read and write through the daemon. This
page shows what happens when the daemon stops, and how to restore it.

## How the daemon runs

The daemon is an XPC service inside the app bundle
(`Contents/XPCServices/wikid.xpc`). macOS launches it at the first connection
and stops it after an idle period. It runs only while the app needs it. It
does not survive quitting the app; the next launch of the app brings it back.
There is no launchd agent and no `launchctl` job to manage.

## When the daemon is unavailable

You rarely see an unavailable state, because macOS starts the service on
demand. You see it when the daemon crashes twice in a row, when a build
replaces the binary under the running service, or when you stop it on purpose.

When the daemon is unavailable:

- The app shows a reconnecting banner in each wiki window.
- Edits and other writes fail with an explicit error. Nothing queues locally.
- The queue activity window shows its unavailable state. It does not fall
  back to in-app execution.
- The Finder projection stops serving files. Finder shows the standard
  unavailable state for the extension.
- `wikictl` commands fail fast with an explicit error while the daemon is
  down.

There is no local fallback and no read-only local mode. This is deliberate:
a fallback would create a second writer and risk split data. Your data is
safe on disk. Clients pick up where they left off when the daemon returns.

On recovery, the app reconnects, compares change tokens, and reloads any
changes it missed. Writes that failed while the daemon was down were not
queued. Do them again after the banner clears.

## Restore the daemon

Condition: the app shows the reconnecting banner, or the Finder projection is
unavailable.

1. Quit the app and open it again. The first connection relaunches the
   daemon. This fixes most cases.
2. Check the menu-bar status item. Its tooltip reports the daemon state,
   and names the activity lanes that are active or paused, so you can see
   whether the app holds a live connection.
3. If the banner persists after a relaunch, a stale daemon process may be
   wedged. Stop it, then relaunch the app:

   ```sh
   killall wikid
   ```

   macOS starts a clean daemon at the app's next connection.

4. If the daemon still fails to come up, rebuild and relaunch the app. The
   build installs the current daemon binary inside the app bundle.

## Stop the daemon on purpose (operator check)

Use this check to see the degraded states before you rely on them. The
system relaunches the daemon at the next connection, so this check is safe.

1. Note the page you have open in the app.
2. Stop the daemon:

   ```sh
   killall wikid
   ```

3. Edit a page in the app. The write fails with an explicit error, and the
   reconnecting banner appears.
4. Open the queue activity window. It shows the unavailable state.
5. Open a Finder window on the projected wiki folder. Finder shows the
   unavailable state.
6. Run any `wikictl` command. It fails fast with an explicit error.
7. Bring the daemon back: interact with the app (open a page), or run

   ```sh
   killall wikid
   ```

   first if the dead process blocks a fresh launch. The next connection
   starts a clean daemon.

8. Confirm recovery: the banner clears, the edit works again, and a change
   made by `wikictl` while the app was disconnected appears in the app
   without a restart.

## Read wiki data in an emergency

The SQLite database is the source of truth. One `<ulid>.sqlite` file per wiki
lives in the App Group container. The container is protected, so a plain shell
cannot read it.

- Full option: give your terminal Full Disk Access (System Settings,
  Privacy & Security), then read the files with `sqlite3`.
- Simple option: use the bundled `wikictl` against a running daemon. It has
  access and needs no extra permissions. Run `wikictl --help` for commands.

Do not edit the database by hand while the daemon runs. Stop the daemon first,
and let the app or the daemon do the write.
