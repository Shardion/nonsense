# Nonsense

Very rough tool to run processes with arbitrary names inside Discord's Flatpak
sandbox.

## Why is this necessary?

The only way for Discord to discover running games, assuming they don't support
Rich Presence, is to scan all running processes. When Flatpak is in use, Discord
can't see any other processes on the system. This is great for security, but
also means that you can't set a Playing status for any process not running
inside Discord's sandbox.

I don't think Flatpak supports applications sharing PID namespaces with the
host. Nonsense's approach has no security benefit, since it requires the
application running the game to be able to break out of the Flatpak sandbox,
which breaks sandboxing, by definition...

## Limitations

- Requires to manually set up every single game that you want playing statuses
  for.
- Discord release channels other than stable will not work. (It's OK, they're
  all identical now, since everything is an A/B test, anyways...)
- I think that's it...?

## How to use

Install the `nonsense` binary to a place that Discord and your game launcher
have access to. This is your \<nonsense binary\>. You'll likely need to make a
new directory for it, say `~/.local/bin/`, and use Flatseal or the Flatpak CLI
to give the relevant permissions to every Flatpak that needs access.

The game launcher application needs to have permission to talk
`org.freedesktop.Flatpak` on the session bus as well. This grants a lot of
powers, including the ability to break right out of the sandbox, so maybe don't
use Nonsense on applications you don't trust...?

You'll need to instruct your game launcher to run Nonsense alongside your game.
Yes, each game, individually. How you do this depends on what launcher you use,
but generally, you'll have to go into the game-specific settings, and add either
a pre- and post-launch script, or a wrapper command.

Take a second to think of a short name for your game that doesn't use spaces.
This is your \<gamename\>. (Technically, you can use spaces, and any other
character except `/`, but that will make it slightly more annoying.)

Wrapper commands are generally preferred, since they handle multiple instances
of a single game properly.

Steam supports wrappers by replacing any instance of `%command%` in a game's
launch options with the actual command that will be run, so you'll have to open
the properties window for your game, and set the launch options to
`<nonsense binary> wrap <gamename> %command%`.

Bottles supports wrappers in the same way as Steam. Open the options menu for
your game, click *Change Launch Options...*, and set *Command Arguments* to
`<nonsense binary> wrap <gamename> %command%`.

Start your game, open Discord's Registered Games menu, click the tiny link text
reading *Add it!*, and then select `<gamename>.nonsense-game` from the list.
(Do not click the one that ends in ` (deleted)`. It might work, but not
intentionally.) You can then scroll down to the list of Added Games, click the
name `<gamename>.nonsense-game`, and change it to the title of any game
listed on [IGDB](https://www.igdb.com/).

## Notes

- Discord determines the process name from the link target of
  `/proc/<pid>/exe`. It does not use `/proc/<pid>/comm`, or
  `/proc/<pid>/cmdline`, in any way.

