# Kraken Game Art

NZXT CAM web integration for Kraken LCD coolers. It shows art for the game Discord says you're playing.

**Web integration URL:** https://slaterdamian.github.io/kraken-game-art/

## Setup

1. Join the [Lanyard Discord server](https://discord.gg/lanyard). That's how the page can see your Discord activity.
2. In Discord, turn on **Settings → Activity Privacy → Share your detected activities**.
3. In NZXT CAM, add a custom web integration with the URL above and add it as a card.
4. In the integration's configuration window, enter your Discord user ID, pick your options and click **Apply to Kraken**.

To get your Discord user ID, turn on **Settings → Advanced → Developer Mode**, then right-click your name → **Copy User ID**.

## Styles while playing

| Style | What it shows |
| --- | --- |
| Icon | The game's Discord icon. A solid background colour is continued into the whole circle, and busy icons fade out at the edges. The size is adjustable. |
| Box | The Steam cover art as a floating box. |
| Smart zoom | The cover art cropped to its most interesting region by [smartcrop.js](https://github.com/jwagner/smartcrop.js). |
| Logo on banner | The Steam logo over the Steam banner art. |

Games not on Steam fall back to the Discord icon or the game's rich presence art.

## When nothing is playing

Choose one: a clock (12 or 24 hour, date optional), the last game you played (dimmed), music playing on this PC, a custom image, or a black screen.

## Music on this PC

A web page can't see what Windows is playing, so this option needs `media-bridge.ps1` running on your PC. It reads the Windows media controls, the same info shown in the volume flyout, so it works with Apple Music, browsers and most players. It serves that info at `http://localhost:8766`.

Install it once. The bridge copies itself to `%LOCALAPPDATA%\KrakenGameArt` and starts hidden at every logon:

```powershell
powershell -ExecutionPolicy Bypass -File media-bridge.ps1 -Install
```

Remove it with `-Uninstall`. To check it's working, open http://localhost:8766/media while music plays.
