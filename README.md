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
  TP-scaled durations, and Frailty (Sylvie-entrust aware). Frailty is
  party-filtered: casts from players outside your party/alliance are
  ignored, and an unidentifiable caster books at Sylvie potency, not
  the full player-GEO (Idris) assumption.
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
  bounds on the mob's base defense, then re-checks on its own when your
  attack shifts or when defense buffs/debuffs change on the target. Checks
  only ever go to monsters, never a sub-targeted party member, and a check
  that gets no response retries on its own.
  "Impossible to gauge" NMs use a static anchor instead (`//pdl base <n>`).
- Knows your **threshold**: the pDIF cap of the weapon you actually have
  equipped + Damage Limit traits (main
  and qualifying sub jobs), lifted dynamically when Aria of Passion is up
  (Soul Voice doubling detected automatically).

## Commands
| Command | Effect |
|---|---|
| `//pdl` | toggle the window |
| `//pdl save` | save the window's current position |
| `//pdl base <n>` | static anchor ratio for unchecked/ITG mobs (default 1.10) |
| `//pdl atk <n>` | your buffless attack (fallback scale; default 1500) |
| `//pdl v <0-25>` | Sheol Gaol Vengeance rank (session-local; default 25) |
| `//pdl htmb <ve\|e\|n\|d\|vd>` | HTMB difficulty tier (default vd) |
| `//pdl status` | echo the full decomposition for your current target |
| `//pdl debug` | packet tracing on/off |

Position is saved automatically when you drag the window.

## Credits
Built by Cypan (Bahamut). Debuff-tracking lineage: Debuffed by Xathe.
Attack modifier / pDIF math per bg-wiki's PDIF documentation and community
testing. Share freely.


## ITG NM defense seeds and Vengeance

For endgame NMs that check Impossible to Gauge, the tracker carries a
name-keyed seed table (PDL_NM_DEFENSE, 50 entries: Sheol Gaol, Sortie,
Omen, Dynamis Divergence, HELM/Kouryu/Warder of Courage, HTMB VD trio)
built on a level-scaling model (Arebati V0 = 1320 tested, 55 defense per
level). When a seeded name returns the ITG check verdict, the estimate
switches to [seed] mode: def = base + per_v x Vengeance. Set your Gaol
Vengeance rank with //pdl v <0-25> (session-local, defaults V25). Dynamis
Divergence entries carry geo_mult 0.50: Frailty booked on those bosses
is halved to match JP-tested zone nerfs. Edit the table in-file to add
or correct NMs; entries carry kind = tested/measured/modeled provenance. HTMB entries resolve by difficulty tier: //pdl htmb <ve|e|n|d|vd>
(defaults vd) rescales Cloud of Darkness, Shinryu, and Lilith through
the tier-halving ladder (1036/1042/1052/1086; generic VD 1155 at CL 129, with Cloud of Darkness, Shinryu, and Lilith anchoring VD at 135 = 1320; tier defaults to VD).

## Support

These addons are free and always will be. If one of them saved you some time
and you'd like to buy me a coffee, it's appreciated but never expected:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-cypan-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/cypan)

Bug reports and pull requests are worth more than donations. Open an issue if
something's broken.
