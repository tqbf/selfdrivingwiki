# Troubleshooting

The `wikid` daemon owns all wiki data. The app, the `wikictl` command, and the
Finder projection are clients. They read and write through the daemon. This
page shows what happens when the daemon stops, and how to restore it.

## What the daemon owns

The daemon owns the wiki database, the queue database, the search index, and
all workload execution: extraction, ingestion, chat turns, and index builds.
No client opens a wiki file. This design has one writer, so the data stays
consistent across the app, the CLI, and Finder.

## When the daemon is unavailable

The daemon runs as a launchd agent. It starts on demand and exits after five
idle minutes. A restart on your Mac also brings it back at the next connection.
You rarely see an unavailable state. You see it when the daemon crashes twice
in a row, when a build replaces the binary under it, or when you stop it on
purpose.

When the daemon is unavailable:

- The app shows a reconnecting banner in each wiki window.
- Edits and other writes fail with an explicit error. Nothing queues locally.
- The queue activity window shows its unavailable state. It does not fall
  back to in-app execution.
- The Finder projection stops serving files. Finder shows the standard
  unavailable state for the extension.

There is no local fallback and no read-only local mode. This is deliberate:
a fallback would create a second writer and risk split data. Your data is
safe on disk. Clients pick up where they left off when the daemon returns.

On recovery, the app reconnects, compares change tokens, and reloads any
changes it missed. You do not need to redo writes that failed; do them again
after the banner clears.

## Restart the daemon

Condition: the app shows the reconnecting banner, or the Finder projection is
unavailable.

1. Wait one minute. Most cases recover on their own, because launchd restarts
   the daemon at the next connection.
2. Check the daemon state:

   ```sh
   launchctl print gui/$(id -u)/com.selfdrivingwiki.wikid | head -5
   ```

3. Force a restart if the state shows a crash loop:

   ```sh
   launchctl kickstart -k gui/$(id -u)/com.selfdrivingwiki.wikid
   ```

4. Confirm recovery: the banner clears, and the activity window shows lanes
   again.

If the daemon stays down after a restart, rebuild and relaunch the app. The
build installs the current daemon binary with the LaunchAgent plist.

## Stop the daemon on purpose (operator check)

Use this check to see the degraded states before you rely on them. The
daemon comes back at the next connection, so this check is safe.

1. Note the page you have open in the app.
2. Stop the daemon:

   ```sh
   launchctl kill SIGTERM gui/$(id -u)/com.selfdrivingwiki.wikid
   ```

3. Edit a page in the app. The write fails with an explicit error, and the
   reconnecting banner appears.
4. Open the queue activity window. It shows the unavailable state.
5. Open a Finder window on the projected wiki folder. Finder shows the
   unavailable state.
6. Bring the daemon back:

   ```sh
   launchctl kickstart -k gui/$(id -u)/com.selfdrivingwiki.wikid
   ```

7. Confirm recovery: the banner clears, the edit works again, and a change
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
