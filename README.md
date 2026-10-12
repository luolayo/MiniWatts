# MiniWatts

**English** · [简体中文](README.zh-Hans.md)

[![Build](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml/badge.svg)](https://github.com/ResistanceTo/MiniWatts/actions/workflows/build.yml)

An iPhone battery and charging monitor built on Apple's private APIs. It reads the
phone's own power-management sensors — the ones iOS uses to run the charge — and shows
what the charger is delivering, how much of it reaches the cell, the power difference,
and component temperatures. It also shows device upload and download rates.

> These screenshots show the previous layout. The new tabs are Overview, History and
> Settings. Battery and power-path readings remain on Overview, with temperature
> and charger details available one level deeper.

| Power | Thermal | Adapter | History |
|:-:|:-:|:-:|:-:|
| <img src="docs/screenshots/power.jpg" width="200" alt="Power"> | <img src="docs/screenshots/thermal.jpg" width="200" alt="Thermal"> | <img src="docs/screenshots/adapter.jpg" width="200" alt="Adapter"> | <img src="docs/screenshots/history.jpg" width="200" alt="History"> |

> **Sideload only.** Private APIs mean this can never be on the App Store — you sign
> and install it yourself. Measurement data stays on your phone. Network rates come
> from local interface counters. The traffic consumer only downloads from a supplied
> link after you explicitly start it.

## Install

Download the latest `MiniWatts-unsigned.ipa` from
[Releases](https://github.com/ResistanceTo/MiniWatts/releases) and sign it with your own
Apple ID — [Sideloadly](https://sideloadly.io), [AltStore](https://altstore.io),
[SideStore](https://sidestore.io) and Xcode all do this. A free Apple ID works; the app
then expires after seven days and you re-sign it.

Requires iPhone, iOS 17 or later.

Or add the source to SideStore or AltStore — including the SideStore bundled with
LiveContainer — and install from there, so new versions show up as updates:

```
https://github.com/ResistanceTo/MiniWatts/releases/latest/download/apps.json
```

LiveContainer cannot run app extensions, so installed inside it MiniWatts has no widget
and no Live Activity.

MiniWatts includes a Home Screen and Lock Screen widget, and a power/network Live Activity
on the Dynamic Island and Lock Screen. The widget extension is one more App ID when you sign — a free Apple ID gets
ten a week — and if your signing tool offers to remove extensions, doing so removes the
widget.

## What it can't do

Sensor names, scales and even which sensors exist differ by iPhone model, and none of
it is documented. This build was written and verified on an iPhone Air; on another
model a reading can be missing or mean something other than its name suggests.
Impossible values — a charge IC at −9199 °C, which someone really did see — are hidden
rather than shown, but a wrong value that looks plausible cannot be caught that way.
Please report anything surprising with your model identifier.

Only what iOS actually hands a sandboxed app. Battery health and cycle count are
filtered out of the registry; accessory batteries (Watch, AirPods) come back empty;
wireless charging exposes no input current, so on MagSafe you only see what reaches the
cell; discharge power has no sensor and is estimated from the percentage. Charging holds
can only be inferred, and the app labels them `inferred` when that is what happened.

Charger details shows USB-PD as `inferred` only when a valid advertised power profile
has an explicit active selection. An advertised menu alone, voltage, wattage or the
charger's name cannot identify the active protocol. PD revision, PPS use, QC and the
wireless standard (Qi, Qi2 or MagSafe) remain unidentified with the available data.

Widgets refresh when iOS decides to. While the app runs, connecting a charger starts a
Live Activity and submits a reading about once per second. iOS controls when the Dynamic
Island actually redraws. If the app is suspended without approved background runtime,
the last reading remains visible with a paused marker and measurement time.

To start while the app is closed, create a Shortcuts **Charger Is Connected** automation
that runs MiniWatts’ **Show Charging Activity** action. Add **End Charging Activity** to a
**Charger Is Disconnected** automation. The intent wakes the app process and starts the
activity without opening its interface. Continuous background readings require a
separately approved background monitoring task. A Live Activity alone cannot keep the
app running.

Network rates count Wi-Fi, cellular and Ethernet interface traffic, including other apps
and local traffic. They are not a bandwidth test or a per-app breakdown. VPN tunnel
interfaces are excluded to avoid double counting. Switching interfaces, resuming and
counter resets establish a fresh baseline. Unavailable readings show a dash.
1 MB/s is 1,000,000 bytes per second. iOS counter visibility and VPN behavior still
need verification on the target device.

## Traffic consumer

Open **Traffic consumer** from Overview's network card. Built-in provider groups have
been removed. Enter a name, HTTPS link, amount/unit, concurrency and redirect settings,
then use **Save settings**. Named configurations can be selected, edited or deleted on
later launches. Data stays in the app's private preferences container.

Choose MB or GB (decimal units, 1 GB = 1000 MB). Fractional amounts and goals such as
400 GB are supported without the old 10 GB cap. The default time limit is now **No
time limit**; the transfer still stops at its byte goal, on terminal errors or cancellation.
Amounts and worker reservations use checked Int64 arithmetic. Concurrency remains 1–64.
**Max speed** starts a run with all 64 worker slots, independent of the saved manual
thread count. Short files refill slots immediately. The source server, file size,
connection and iOS can still limit throughput, so this cannot guarantee line rate.
Saved configurations checkpoint progress roughly once a minute and on stop; choose
**Resume remaining** after a restart, or **Start download** to start over. App launch
never starts a transfer automatically. Unsaved runs only retain progress in memory.

Received payload is streamed through ephemeral URLSession data tasks, counted and discarded.
No download file, resume-data blob, or response disk cache is created. Settings, small
checkpoints, charge history and system bookkeeping still cause small storage writes;
this is not a promise of zero device I/O. Repeated identical settings are not rewritten.

Requests are capped at 32 MiB, including servers that ignore Range. A successful short
file immediately starts the next request in its worker slot, keeping the selected
concurrency available while data remains. Healthy workers continue when another loses
its connection. Timeouts, connection loss and transient
HTTP 408/429/500/502/503/504 responses retry with 1/2/4/8/16/30-second backoff (up to six
consecutive retries per worker), retaining all counted bytes. Successful chunks reset
the budget. Retry-After is honored up to five minutes; longer waits stop with the HTTP
status. Authentication, certificate, origin and permanent HTTP failures remain terminal.
The page shows retry counts, reconnection status and URL error codes without exposing
private query strings. Stop, goal, time limit and background cancellation cancel retries.

### Independent background monitoring

In Dynamic Island settings, start a 1-, 4- or 8-hour monitoring window while charging,
wait for approval, and then switch apps. The system task card shows power and battery
level. Unplugging ends monitoring; starting a download ends it before showing the
download task card, so the two tasks do not create two cards.

The operating system may deny or revoke runtime and controls display timing. There is
no guarantee of indefinite execution or one-second rendering. Force-quitting ends the
work. A one-time Refresh action remains available. Re-signing tools must preserve or
update the bundle-ID prefixes for both permitted background task identifiers. Device
validation is still required; denied runtime is reported rather than disguised as live.

Same-origin redirects are the default: HTTPS host and effective port must match the
initial link, including subdomains. The optional **Allow HTTPS redirects** rule can
follow other hosts and displays the actual destination. HTTP downgrades are always
blocked; redirect chains are bounded. Credentials, cookies and referrers are not
forwarded, and webpages/playlists are not opened or used to load other resources.

The system chooses the network. Disable Wi-Fi yourself if you intend to use cellular
data. Carrier-specific allowances may only apply inside the provider's official app;
link grouping cannot establish eligibility. Check your actual plan before starting.

## Build

Xcode 26 or later, iOS 17 deployment target, no dependencies.

```bash
./scripts/check-network.sh                         # portable macOS Swift checks
./scripts/check-charging-protocol.sh               # protocol evidence and unknown readings
./scripts/check-traffic-consumer.sh                # intercepted local responses, no external traffic
./scripts/check-background-lifecycle.sh            # independent monitoring/download runtime
./scripts/check-traffic-settings.sh                # saved profiles, resuming and large-target arithmetic
./scripts/build-ipa.sh                             # unsigned, what Releases ships
TEAM_ID=ABCDE12345 ./scripts/build-ipa.sh signed   # signed, for your own device
```

[`CLAUDE.md`](CLAUDE.md) is the engineering notebook: which APIs the sandbox blocks and
how that was established, what each sensor turned out to be, and the Swift 6 isolation
traps this project has already fallen into.

## Licence

Apache 2.0 — see [LICENSE](LICENSE). The method for reading the PMU is derived from
[ios-charging-monitor](https://github.com/gregsramblings/ios-charging-monitor) (MIT);
`BatteryCenterBridge` owes two details to [Batsie](https://github.com/leptos-null/Batsie).
Both are credited in [NOTICE](NOTICE), which carries the upstream MIT notice.

Private APIs can change or disappear in any iOS update.
