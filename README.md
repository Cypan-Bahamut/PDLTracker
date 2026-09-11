# PDL Tracker

A small draggable window for Windower that answers one question in real time:
**"is it PDL gear time?"**

`pDIF: 4.77` in **green** = your estimated cRatio is past your job's pDIF cap
threshold — swap to your Physical Damage Limit+ WS sets. **White** = you're
under it — attack/WSD gear wins. The addon only measures and displays; you
toggle your own sets.

## Install
Drop the `PDLTracker` folder into `Windower/addons/` and `//lua load pdltracker`.
No configuration required — it starts working on your first engaged target.
Trivial targets (Too Weak / Incredibly Easy Prey) just read `pDIF: Too Weak`
in green — you are past cap by definition. NMs in the built-in defense
table are resolved by name and are never auto-`/check`ed.

## What it does under the hood
- Reads your **actual attack** from the game's char-stats packets (buffed,
  geared, rolled — the server's own number). Until the first packet arrives
  it falls back to a buff model (Chaos Roll by rolled number, Minuets
  identified per cast with Soul Voice detection, party DRK bonus) — the
  window's status mode shows `cal~` during fallback, `cal` once measured.
- Tracks **enemy defense down**: Dia (+Light Shot), Box Step daze level,
  Armor Break / Full Break / Shell Crusher / Tachi: Ageha / Angon with
  TP-scaled durations, and damaging pet moves that carry Defense Down —
  automaton Armor Shatterer plus the BST Ready moves (Corrosive Ooze,
  Rhinowrecker, Sweeping Gouge, Swooping Frenzy, Tortoise Stomp), booked
  on landed damage since these emit no additional-effect message —
  and Frailty (Sylvie-entrust aware). Frailty is
  party-filtered: casts from players outside your party/alliance are
  ignored, and an unidentifiable caster books at Sylvie potency, not
  the full player-GEO (Idris) assumption. On bosses that nerf offensive
  Geomancy the booked Frailty is scaled by target NAME: all 17 Odyssey
  Sheol Gaol Atonement NMs at -85%, the Sortie basement bosses
  (Dhartok, Gartell, Triboulex, Aita, Aminon) at -50%, and the Dynamis
  Divergence wave bosses at -50%.
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
| `//pdl save` | save the window position + Vengeance rank |
| `//pdl base <n>` | static anchor ratio for unchecked/ITG mobs (default 1.10) |
| `//pdl atk <n>` | your buffless attack (fallback scale; default 1500) |
| `//pdl v <0-25>` | Sheol Gaol Vengeance rank (default 25; `//pdl save` persists) |
| `//pdl htmb <ve\|e\|n\|d\|vd>` | HTMB difficulty tier (default vd; auto-set on battlefield entry) |
| `//pdl seed <n>` | pin the targeted NM's base defense (persists) |
| `//pdl headroom` | toggle the signed %-vs-threshold readout (default on) |
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
level). A seeded name resolves by NAME alone — no /check is issued and no
gauge verdict is needed; the estimate runs in [seed] mode:
def = base + per_v x Vengeance. Set your Gaol
Vengeance rank with //pdl v <0-25> (defaults V25; //pdl save persists it).
Pin a measured base defense for the targeted NM with //pdl seed <def> --
pins persist in settings and override the shipped rows on load.
Offensive-geomancy nerfs live in a single name-keyed table (GEO_NERF):
Gaol Atonement NMs 0.15, Sortie basement bosses 0.50, Dynamis Divergence
wave bosses 0.50 — Frailty booked on those names is scaled to match the
zone mechanics (frailty only; Fury is unaffected). Edit either table
in-file to add or correct NMs; seed entries carry kind =
tested/measured/modeled provenance. HTMB entries resolve by difficulty
tier, auto-detected from the battlefield entry lines ("Current
difficulty level: ...") with //pdl htmb <ve|e|n|d|vd> as the manual
override; the ladder rescales Cloud of Darkness, Shinryu, and Lilith
(VE 1052 / E 1086 / N 1155 / D 1293 / VD 1540, from menu levels
119/124/129 with D 134 / VD 139 assumed; tier defaults to VD).

## Support

These addons are free and always will be. If one of them saved you some time
and you'd like to buy me a coffee, it's appreciated but never expected:

[![Buy Me a Coffee](https://img.shields.io/badge/Buy%20Me%20a%20Coffee-cypan-FFDD00?logo=buymeacoffee&logoColor=black)](https://buymeacoffee.com/cypan)

Bug reports and pull requests are worth more than donations. Open an issue if
something's broken.
