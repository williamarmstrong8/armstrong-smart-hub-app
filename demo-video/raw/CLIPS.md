# Clips

The raw recordings sit next to this file. They're gitignored, and you can re-record them any time with the scripts listed under "How to re-record" below.
Device: iPhone 18 Pro simulator (iOS 27.0), 1206×2622, H.264. Status bar reads 9:41, full battery, full bars.
Demo mode: `-DemoMode YES`. Data is the same in every take.

**Chosen take** is the one I'm using. **Use** is the in/out range (seconds) worth using from that take. Timings were read from extracted frames.

| Clip | Chosen take | Length | Use (s) | What happens |
|---|---|---|---|---|
| Fitness hero | `fitness-hero-dark-t2.mp4` | 20.1 | 9.4 – 16.5 | The app draws with empty rings (–). About 4 s later the data lands and the three rings fill to 86 / 91 / 78. The 0–9.4 s stretch is launch: home screen, then black. Cut it. |
| Fitness hero (light) | `fitness-hero-light-t2.mp4` | 22.5 | 12.0 – 18.5 | Same in light mode |
| Watch sync | `fitness-sync-dark-t1.mp4` | 6.0 | 1.5 – 6.0 | A green progress ring sweeps around the watch face (about 2.6 s, eases out) and then clears |
| Fitness scroll | `fitness-scroll-dark-t1.mp4` | 4.9 | 0.8 – 4.9 | A slow scroll from the watch hero, through the week strip, down to heart rate, Body Battery, Strain, Endurance, Recovery, Hub age and Steps. The scroll is a real drag. |
| Sleep page | `fitness-sleep-dark-t2.mp4` | 5.8 | 2.3 – 5.8 | Tapping the Sleep ring pushes the Sleep page: 91 "Optimal", 7h 48m asleep, contributors all "Optimal" |
| Lights | `home-lights-dark-t4.mp4` | 10.1 | 4.0 – 10.1 | Living Room turns on (~5.3), its sheet opens (6.6), brightness glides to 85 % (~7.8), the sheet closes and the card reads "On · 85%" (9.3) |
| Lights (light) | `home-lights-light-t3.mp4` | 10.1 | 3.8 – 10.1 | Same in light mode |
| Lock | `home-lock-dark-t7.mp4` | 9.4 | 2.5 – 6.5 | The Front Door card goes from red "Unlocked" to grey "Locked" (~4.3); "2 active" becomes "1 active" |
| Focus start | `focus-start-dark-t1.mp4` | 6.8 | 1.5 – 6.8 | A white circle with "Ready to focus". On the tap (2.5) the circle becomes a ring, the title changes to "Deep Work", "Focused for 0:01" starts counting, and sessions go from 3 to 4 |
| Focus start (light) | `focus-start-light-t1.mp4` | 6.9 | 1.5 – 6.9 | Same in light mode (a black circle becomes a grey ring) |

Other takes stay in the folder: hero t1, sync t2, lights t1–t3, lock t1–t6, focus t2, sleep t1.
- **Don't use:** lock t1–t6. The door locks after the clip ends, or the takes come from before the layout change.
- **Old layout:** lights t1–t3 and the light-mode t1/t2 takes still show the TV and thermostat cards that demo mode now hides.

## Tour clips (second cut)
All dark mode, take 1, converted to 30 fps in `public/clips/<name>.mp4`. Times are in the converted clip.

| Clip | Length | What happens |
|---|---|---|
| `tab-tour` | 7.5 | Home, then one tab a second: Finance (3), Calendar (4), Fitness (5), Focus (6), Home (7) |
| `fitness-scroll2` | 11 | The watch hero, then a 6 s scroll (3–9) through the week, every metric and the workouts |
| `fitness-pages` | 21.7 | Sleep (5–7, scrolls to stages), Heart (9–12, scrolls to HRV), VO2 max / race times (15–18) |
| `fitness-workout` | 19.9 | Pull workout detail (5–8, scrolls through sets with heart rate), then a live Push workout: sets checked off, rest timer (11–18) |
| `home-scroll` | 5.4 | Devices, scrolling down to today's habits (2–4) |
| `finance-tour` | 21 | Three tags in one tap (3–8), the tag picker (9–10), budgets and accounts (12–14), All transactions with the cash-flow chart (15–19) |
| `calendar-tour` | 9.9 | "Next up", to-dos, the habit month (0–4), then the agenda for the week (5–9) |
| `focus-tour` | 19.8 | NFC "Ready to Scan" (3–4), Deep Work (5–7), today's card (8–10), Weekly Activity (11–12), back, NFC again to end (16–17), "Ready to focus" |

## Stills (`stills/`, 1206×2622 PNG)
`fitness-dark`, `fitness-light`, `fitness-overview-dark` (metrics list), `fitness-metrics-dark` (week strip + metrics),
`fitness-sleep-dark`, `fitness-workouts-dark`, `home-dark`, `home-light`, `home-light-sheet-dark`, `home-devices-dark`,
`home-habits-dark`, `focus-idle-dark`, `focus-on-dark`, `focus-light`.
- **Old Home layout:** `home-light-sheet-dark`, `home-devices-dark` and `home-habits-dark` were taken before the TV and thermostat were hidden.

## How to re-record
```
demo-video/scripts/record_flows.sh fitness-hero|fitness-sync|home-lights|home-lock|focus-start <take> [dark|light]
demo-video/scripts/rec.sh launch|start|stop|frames …     # gesture clips (scroll, sleep tap) around a manual drag/tap
demo-video/scripts/cue.sh sync|light.toggle|light.sheet|light.bright|light.close|lock|focus|scroll.down|scroll.top
```
Notes:
- Recording starts about 1–3 s after `rec.sh start` and lags the cues a little, so the flows pad both ends.
- The first injected touch after a pause is often ignored, so gesture clips start with a throwaway tap.
