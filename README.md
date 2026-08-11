# PDL Tracker

A small draggable window for Windower that answers one question in real time:
**"is it PDL gear time?"**

`PDL: 4.77` in **green** = your estimated cRatio is past your job's pDIF cap
threshold — swap to your Physical Damage Limit+ WS sets. **White** = you're
under it — attack/WSD gear wins. The addon only measures and displays; you
toggle your own sets.

## Install
Drop the `PDLTracker` folder into `Windower/addons/` and `//lua load pdltracker`.
No configuration required — it starts working on your first engaged target.

## What it does under the hood
- Reads your **actual attack** from the game's char-stats packets (buffed,
  geared, rolled — the server's own number). Until the first packet arrives
  it falls back to a buff model (Chaos Roll by rolled number, Minuets
  identified per cast with Soul Voice detection, party DRK bonus) — the
  window's status mode shows `cal~` during fallback, `cal` once measured.
- Tracks **enemy defense down**: Dia (+Light Shot), Box Step daze level,
  Armor Break / Full Break / Shell Crusher / Tachi: Ageha / Angon with
  TP-scaled durations, and Frailty (Sylvie-entrust aware).
- Tracks **enemy defense swings in both directions**: mob self-buffs
  (Scissor Guard, Water Wall, Harden Shell, Cocoon — plus a generic
  Defense Boost catch-all), mob-cast Protect/Protectra (flat, per tier),
  Rage-type self defense-downs, and Defense Down landed by anyone —
  Blue Magic, pet ready moves, bolt/weapon procs — with dispel/wear-off
  clearing and duration fallbacks throughout. Defense Boost and the
  Defense Down family mutually overwrite (Dia, steps, and Frailty are
  separate and stack); Dia III duration assumes endgame gear when
  player-cast, base when trust-cast.
- Auto-issues **/check** once per mob and converts the defense verdict into
  bounds on the mob's base defense; re-checks automatically when your attack
  changes materially. "Impossible to gauge" NMs use a static anchor instead.
- Knows your **threshold**: per-job pDIF caps + Damage Limit traits (main
  and qualifying sub jobs), lifted dynamically when Aria of Passion is up
  (Soul Voice doubling detected automatically).

## Commands
| Command | Effect |
|---|---|
| `//pdl` | toggle the window |
| `//pdl save` | save the window's current position |
| `//pdl base <n>` | static anchor ratio for unchecked/ITG mobs (default 1.10) |
| `//pdl atk <n>` | your buffless attack (fallback scale; default 1500) |
| `//pdl status` | echo the full decomposition for your current target |
| `//pdl debug` | packet tracing on/off |

Position is saved automatically when you drag the window.

## Credits
Built by Cypan (Bahamut). Debuff-tracking lineage: Debuffed by Xathe.
Attack modifier / pDIF math per bg-wiki's PDIF documentation and community
testing. Share freely.

## Support

First and foremost: Please support the original author if this is an addon modification. 
If you enjoy the addon and you'd like to buy me a coffee, it's appreciated but never expected:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-cypan-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/cypan)

Bug reports and pull requests are worth more than donations, so open an issue if something's broken please.
