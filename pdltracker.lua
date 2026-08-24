_addon.name    = 'PDL Tracker'
_addon.author  = 'Cypan (Bahamut)'
_addon.version = '1.0.0.0'
_addon.command = 'pdl'

--------------------------------------------------------------------------------
-- PDL Tracker: a small draggable window showing your live estimated cRatio vs
-- your job's pDIF-cap threshold. GREEN = capping territory (equip your PDL
-- WS sets); WHITE = below (attack/WSD gear wins). Toggle sets manually --
-- this addon only measures and displays.
--
-- How it estimates (all packet-driven, zero configuration required):
--  * Your attack: MEASURED from char-stats packets (falls back to a buff
--    model -- rolls by actual number, minuets identified per cast with
--    Soul Voice detection, party-main-job DRK bonus -- until the first
--    measurement arrives; mode shows 'cal~' until then).
--  * Enemy defense-down: Dia (+Light Shot), Box Step daze level, Armor
--    Break-family WS/JA with TP-scaled durations, Frailty (Sylvie-aware).
--  * The anchor: /check is auto-issued once per mob; the response's
--    defense verdict converts to bounds on the mob's base defense, refined
--    by re-checks when your attack shifts materially. "Impossible to
--    gauge" NMs fall back to a static anchor (//pdl base <n>).
--  * Threshold: per-job pDIF caps + Damage Limit traits (main and
--    qualifying sub), lifted dynamically by Aria of Passion (SV-aware).
--
-- Commands:
--   //pdl            toggle the window
--   //pdl base <n>   static anchor for unchecked/ITG mobs (default 1.10)
--   //pdl atk <n>    your buffless attack (model fallback + assumed-defense
--                    scale; measured attack takes over automatically)
--   //pdl v <0-25>   Sheol Gaol Vengeance rank (session-local, default 25)
--   //pdl htmb <t>   HTMB difficulty tier: ve|e|n|d|vd (default vd)
--   //pdl save       save the current window position
--   //pdl status     echo full decomposition for the current target
--   //pdl debug      toggle packet tracing
--------------------------------------------------------------------------------

config = require('config')
texts  = require('texts')
require('pack')

defaults = {}
defaults.pos = { x = 300, y = 300 }
defaults.text = { font = 'Arial', size = 12 }
defaults.bg = { alpha = 150 }
defaults.flags = { draggable = true }
defaults.visible = true
defaults.base_ratio = 1.10
defaults.base_attack = 1500
-- Aria PDL by the bard's Songs+ bonus (bg-wiki):
--   +2=15.6% +3=16.9% +4=18.2% +5=19.5% +6=20.8% +7=22.1%
-- Set to your bard's gear (//pdl save persists it). Soul Voice doubles.
defaults.aria_pdl = 0.195
defaults.autocheck = true
defaults.debug = false

settings = config.load(defaults)
local hud = texts.new('PDL: --', settings)

-- Live player getter (defined first: used throughout the tracker below)
local function P() return windower.ffxi.get_player() end
--------------------------------------------------------------------------------
-- AUTO-PDL TRACKER (inlined; formerly pdl_tracker.lua)
-- Background enemy Defense Down tracker + PDL viability calculator.
-- Wrapped in do...end so every internal name stays local to this block;
-- only pdl_config and the pdl_* functions escape as globals.
--
-- Sources merged/adapted (both field-proven):
--   * Debuffed v1.0.0.4 (Xathe)           - cat-4 spell tracking, Light Shot,
--                                            0x029 wear-off/death handling
--   * Debuffed-Steps v1.0.0.5 (Cypan mod)  - step tracking via action messages
--                                            519/520/521/591, daze level param
--
-- IDs verified against github.com/Windower/Resources (resources_data/):
--   Box Step JA 202 (status 391 Sluggish Daze) | Angon JA 170 (status 149)
--   Dia 23/24/25 (status 134, dur 60/120/180)  | Bio 230/231/232 (status 135)
--   Indi-Frailty 788 (base dur 180) | Geo-Frailty 818
--   WS: Armor Break 83, Full Break 87, Tachi: Ageha 155, Shell Crusher 181
--   Buffs: Berserk 56, Minuet 198, Chaos Roll 317, Attack Boost 91/549
-- Names are still resolved from resources at load (robust to ID shifts); the
-- verified IDs above document expectations.
--
-- Public API:
--   pdl_get_defense_down(mob_id) -> total_fraction, breakdown
--   pdl_attack_multiplier()      -> mult, detail
--   pdl_estimated_ratio(mob_id)  -> est_cRatio, att_mult, defdown_total
--   pdl_is_viable(mob_id)        -> boolean
--   pdl_config                   -> all tunables
--------------------------------------------------------------------------------

local res = require('resources')
require('pack')  -- defensive: string:unpack('I',...) used by the 0x029 handler

--------------------------------------------------------------------------------
-- Config. All runtime-tunable. Fractions unless noted.
-- ASSUMED = design assumption; VERIFIED = bg-wiki / resources.
--------------------------------------------------------------------------------
local pdl_config = {
    ------------------------------------------------------------------
    -- PDL decision
    ------------------------------------------------------------------
    -- Per-job PDL thresholds: est cRatio at which capping begins for the
    -- job's primary weapon class, from VERIFIED bg-wiki PDIF caps + Damage
    -- Limit+ trait tiers at 99: onset = noncrit_cap + trait - 0.375, with a
    -- small lead for WS attack ftp / crits.
    -- Job FALLBACK thresholds (used when the equipped weapon can't be
    -- resolved): canonical weapon per job, PDIF-page caps + trait - 0.375.
    thresholds  = { DNC=3.075, THF=2.975, NIN=2.975, BST=3.075, BLU=2.875,
                    BRD=2.875, RDM=2.975, MNK=3.425, PUP=3.325, SAM=3.325,
                    WAR=3.575, DRG=3.675, RUN=3.375, DRK=4.125 },
    threshold_default = 3.075, -- 1H + tier II, fallback for unlisted jobs
    -- Pre-randomizer pDIF caps by WEAPON SKILL (bg-wiki PDIF page, pulled
    -- Aug 2026). Onset threshold = cap + Damage Limit trait - 0.375, where
    -- 0.375 is the randomizer upper-spread constant (same page: wRatio>=1.5
    -- band, UL = wRatio + 0.375).
    skill_caps = { [1]=3.5,  [2]=3.25, [3]=3.25, [4]=3.75, [5]=3.25,
                   [6]=3.75, [7]=4.0,  [8]=3.75, [9]=3.25, [10]=3.5,
                   [11]=3.25, [12]=3.75 },
    -- H2H | Dagger | Sword | GS | Axe | GA | Scythe | Polearm | Katana |
    -- GKT | Club | Staff
    -- Main-job Damage Limit trait value at 99 (trait page, pulled Aug 2026)
    main_trait = { DNC=0.2, THF=0.1, NIN=0.1, BST=0.2, BLU=0, BRD=0,
                   RDM=0.1, MNK=0.3, PUP=0.2, SAM=0.2, WAR=0.2, DRG=0.3,
                   RNG=0.3, DRK=0.5, RUN=0, WHM=0, BLM=0, SCH=0, GEO=0,
                   SMN=0, COR=0, PLD=0 },
    -- Aria of Passion: PDL% multiplicative with the pDIF cap (VERIFIED
    -- bg-wiki PDIF page). Potency ~15-20% by the bard's +All Songs gear
    -- (FFXIclopedia testing; +3 ~ +16%); Soul Voice doubles (auto-detected
    -- via the existing SV look-back on the singing bard).
    -- Damage Limit tier I via SUB job (+26/256 ~ +0.10 to the cap), granted
    -- when sub level reaches the trait level; lifts thresholds only for
    -- mains with no native Damage Limit trait.
    subjob_trait_level = { DRK=20, MNK=30, RNG=30, DRG=30, WAR=40, SAM=40,
                           BST=45, PUP=45, DNC=45, THF=50, NIN=50, RDM=60 },
    no_trait_mains = { BRD=true, BLU=true, RUN=true, SCH=true, SMN=true,
                       BLM=true, WHM=true, GEO=true, COR=true, PLD=true },

    ------------------------------------------------------------------
    -- Attack-side buff values (applied when the buff is on YOU)
    ------------------------------------------------------------------
    att_berserk = 0.25,          -- standard Berserk attack bonus
    -- Chaos Roll: tracked by ACTUAL rolled number from the roll/Double-Up
    -- action packets. Base % by roll: 1-6 and 11 from sourced legacy tables
    -- (FFXIclopedia Phantom Roll: 11 -> +31% COR main; 2007 with/without-DRK
    -- table for 1-6; Lucky 4 = 25%); 7/9/10 interpolated and unlucky 8
    -- ASSUMED low -- correct 7-10 in-game against bg-wiki if desired.
    chaos_roll_pct = { [1]=0.06, [2]=0.08, [3]=0.09, [4]=0.25, [5]=0.11,
                       [6]=0.13, [7]=0.14, [8]=0.03, [9]=0.17, [10]=0.19,
                       [11]=0.31 },
    chaos_drk_bonus   = 0.10,    -- DRK-in-party job bonus (legacy table ~+10pts)
    chaos_gear_bonus  = 0.05,    -- ASSUMED Roll+ gear on a full-bonus player COR
    chaos_crooked_mult = 1.2,    -- VERIFIED bg-wiki Crooked Cards: x1.2 applied
                                 -- AFTER job bonus and gear; players assumed
                                 -- crooked per design, Qultada never
    chaos_force_drk   = nil,     -- nil=auto-detect via DRK JA signature;
                                 -- true/false to override
    -- Fallbacks when the buff is up but no roll packet was seen (zoned in):
    att_chaos_player  = 0.50,
    att_chaos_qultada = 0.25,    -- ASSUMED Qultada (no Crooked Cards/gear)
    att_fury    = 0.373,         -- VERIFIED Sylvie Indi-Fury +37.3%
                                 -- (FFXIclopedia Trust: Sylvie (UC));
                                 -- raise for an Idris GEO
    -- Minuets are now IDENTIFIED per cast and tracked individually.
    -- Flat attack per tier, full-potency REMA bard per design:
    -- V/IV from VERIFIED bg-wiki figures (V full-build Marcato +372 ->
    -- ~250 non-Marcato; IV caps 112 natural + merits/JP/gear); I-III
    -- proportional estimates. Untracked minuet buff instances (missed the
    -- cast) are assumed tier V.
    att_minuet_tier   = { [1]=60, [2]=100, [3]=150, [4]=220, [5]=250 },
    soul_voice_mult   = 2.0,     -- Soul Voice doubles song potency
    soul_voice_window = 180,     -- SV look-back window (sec); VERIFY duration
    song_dur_default  = 360,     -- minuet track timer fallback (REMA bard);
                                 -- live buff count still gates presence
    att_food    = 0,             -- flat att from food; set to your food's value

    ------------------------------------------------------------------
    -- Frailty (per design: assume full potency AND full duration; no
    -- early-drop detection)
    ------------------------------------------------------------------
    frailty_player_pct = 0.418,  -- VERIFIED Idris max Indi/Geo-Frailty
                                 -- (bg-wiki: 14.8% skill + 27% Idris)
    frailty_player_dur = 360,    -- ASSUMED: 180 base (resources Indi-Frailty)
                                 -- x2 for a full-duration-geared GEO
    frailty_sylvie_pct = 0.125,  -- VERIFIED Sylvie Entrust Indi-Frailty
    frailty_sylvie_dur = 180,    -- resources base duration (Sylvie: no gear)
    -- Sheol Gaol: offensive Geomancy -85%% on the gaol bosses. Detected by
    -- BOSS NAME (project ruling, Aug 2026) -- see SHEOL_GAOL_BOSSES below.
    sheol_gaol_geo_mult = 0.15,

    ------------------------------------------------------------------
    -- Debuff potencies (VERIFIED bg-wiki unless noted)
    ------------------------------------------------------------------
    dia_pct        = { [1]=0.1016, [2]=0.1523, [3]=0.2031 },
    light_shot_pct = 0.0273,     -- caps after one shot
    daze_base_pct  = 0.05,       -- Box Step lvl 1
    daze_per_lvl   = 0.02,       -- per level after
    daze_dur       = 120,        -- fallback; 0x029 wear-off is authoritative

    -- ---- Enemy DEFENSE UP (mob self-buffs) ----------------------------
    -- Combined ADDITIVELY with defense-down (net = down - up), matching the
    -- community convention for defense modifiers. ASSUMPTION: flag for
    -- field verification if numbers ever look off.
    defup_moves = {                  -- pct by move name; SELF-buffs only
        -- source: bg-wiki Jug Pets page (pulled Aug 2026), per-pet tables:
        -- '+N% Defense for pet and Beastmaster. Duration varies with TP.'
        ['Scissor Guard'] = 1.00,
        ['Water Wall']    = 1.00,
        ['Harden Shell']  = 0.50,
        ['Cocoon']        = 0.50,    -- long-established crab/BLU value
    },
    -- Mob SELF defense-down moves (Rage-type: attack up, own defense down)
    -- -> tracked as a defense-down GAIN on the mob; PDL-positive.
    selfdefdown_moves = {
        ['Rage'] = 0.50,             -- same page: '+50% Attack & -50% Defense'
    },
    selfdefdown_default = 0.25,
    -- Unidentified Defense Down landings on the mob (bolt/weapon procs):
    -- bolt-class values from the Defense Down page
    defdown_generic_pct = 0.125,
    defdown_generic_dur = 60,  -- unknown self def-down: assume LOW
                                 -- (understating helps PDL later = safe)
    defup_default_pct = 0.50,  -- unknown Defense Boost move: assume GENEROUS
                               -- (overstating their defense delays PDL = the
                               -- safe error direction)
    defup_default_dur = 60,    -- standard 1 min (FFXIclopedia, Aug 2026)
    -- Re-check pacing. A /check prints to chat, so the public build is
    -- conservative; the shipped default is aggressive because catching the
    -- early-debuff window matters more than chat noise.
    check_timeout = 5,   -- seconds before a stranded /check retries
    recheck_gap = 10,
    recheck_max = 10,
    -- Protect/Protectra base flat defense per tier (bg-wiki, Aug 2026)
    protect_flat = { [43]=20,  [44]=50,  [45]=90,  [46]=140, [47]=220,
                     [125]=20, [126]=50, [127]=90, [128]=140, [129]=220 },
    protect_dur  = 1800,
    -- Dia duration = base (60/120/180, from spell resources) x this. Raise
    -- for a geared endgame caster once their duration bonus is known.
    dia_dur_mult = 1.0,
    -- Dia III player-cast duration: '50%% waypoint between base and endgame
    -- enfeebling-duration gear' (project ruling). Implemented as 1.5x assuming endgame
    -- ~2x base; adjust this one number if that assumption is off.
    dia3_player_mult = 1.5,
    defense_floor  = 0.95,       -- defense floors at 1 in-game
    tp_sample_int  = 0.5,

    ------------------------------------------------------------------
    -- /check calibration (dynamic path for checkable mobs; ITG NMs
    -- [message 249] stay on the static base_ratio path)
    ------------------------------------------------------------------
    check_hi_cap   = 8.0,    -- upper bound stand-in for the open low-def bracket
    -- Representative naked-low edge when 'low defense' shows, by toughness
    -- rating (1=Too weak .. 8=Incredibly tough). Rating field is read from
    -- packet param and is display/tier data pending live VERIFY; if it is
    -- not 1-8 we fall back to the documented hard floor of 1.25
    -- (bg-wiki Defense: low defense <=> atk/def >= 1.25).
    lowdef_lo_by_rating = { [1]=1.8, [2]=1.7, [3]=1.6, [4]=1.4,
                            [5]=1.35, [6]=1.25, [7]=1.25, [8]=1.25 },
}

--------------------------------------------------------------------------------
-- Known Defense Down WS / JA (bg-wiki Defense Down page). Family-exclusive.
-- Durations: full linear TP scaling assumed per design (1000->180s, 3000->540s
-- for the 3-9 min WS).
--------------------------------------------------------------------------------
local function tp_scaled_dur(tp)
    local t = math.min(math.max((tp - 1000) / 2000, 0), 1)
    return 180 + t * 360
end

local WS_DEFDOWN = {
    ['Armor Break']   = { pct = 0.25,  dur = tp_scaled_dur },
    ['Full Break']    = { pct = 0.125, dur = tp_scaled_dur },
    ['Shell Crusher'] = { pct = 0.25,  dur = tp_scaled_dur },
    -- bg-wiki Defense Down page (pulled Aug 2026):
    ['Garland of Bliss']  = { pct = 0.125, dur = function(tp)
        tp = math.max(1000, math.min(tp or 1000, 3000))
        return 60 + 120 * ((tp - 1000) / 2000)         -- 1-3 min TP-scaled
    end },
    ['Metatron Torment']  = { pct = 0.1875, dur = function(_) return 120 end },
    ['Tachi: Ageha']  = { pct = 0.25,  dur = function(_) return 180 end },
}

local JA_DEFDOWN = {
    -- bg-wiki: Angon -20~25%, 30-90s (resources base dur 30; merit-scaled).
    -- Per design ("assume full"): 90s. Conservative potency 0.20.
    ['Angon'] = { pct = 0.20, dur = function(_) return 90 end },
}

local DEFDOWN_STATUS = 149  -- shared Defense Down status (VERIFIED: Angon
                            -- status=149 in resources job_abilities)
local DIA_STATUS     = 134  -- VERIFIED resources spells (and Debuffed source)

--------------------------------------------------------------------------------
-- State
--------------------------------------------------------------------------------
local mobs      = {}   -- [id] = { dia={tier,shot,expires,status},
                       --          daze={level,expires,status},
                       --          defdown={name,pct,expires,status} }
local frailty   = { active=false, pct=0, expires=0, source=nil }
local chaos_state   = { num=nil, qultada=false, t=0 }  -- last Chaos Roll seen
local last_roll     = {}      -- [actor_id] = {ja, t} for Double-Up attribution
local party_jobs    = {}      -- [char_id] = MAIN job id (from 0x0DD updates)
local attack_now    = nil     -- measured attack from 0x061 char stats
local attack_now_t  = 0
local drk_in_party  = false   -- recomputed each sample: self or a current
                              -- party member with MAIN job DRK; anon (job 0)
                              -- or unknown defaults to no-DRK
local sv_actors     = {}      -- [actor_id] = Soul Voice window expiry
local aria_sv       = false   -- last Aria of Passion heard was Soul Voiced
local BUFF_ARIA     = 213     -- VERIFIED resources: Aria status
local minuet_tracks = {}      -- {tier, value, expires} per identified minuet
local party_tp  = {}   -- [actor_id] = { cur, prev }
local player_id = 0
local last_tp_sample = 0

-- Resolve IDs from resources at load (expectations documented in header).
local DIA_TIER, BIO_IDS, FRAILTY_SPELLS, MINUET_SPELLS = {}, {}, {}, {}
local ARIA_SPELL
local BOXSTEP_ID, DAZE_STATUS, CHAOS_JA, SOULVOICE_JA, DOUBLEUP_JA
local ROLL_JAS = {}
local DRK_JOB_ID = 8              -- resolved below from res.jobs; expect 8
do
    if res.jobs then
        for id, j in pairs(res.jobs) do
            if j.ens == 'DRK' then DRK_JOB_ID = id end
        end
    end
    local minuet_tiers = { ['Valor Minuet']=1, ['Valor Minuet II']=2,
                           ['Valor Minuet III']=3, ['Valor Minuet IV']=4,
                           ['Valor Minuet V']=5 }
    for id, sp in pairs(res.spells) do
        if     sp.en == 'Dia'     then DIA_TIER[id] = 1
        elseif sp.en == 'Dia II'  then DIA_TIER[id] = 2
        elseif sp.en == 'Dia III' then DIA_TIER[id] = 3
        elseif sp.en == 'Bio' or sp.en == 'Bio II' or sp.en == 'Bio III' then
            BIO_IDS[id] = true
        elseif sp.en == 'Indi-Frailty' or sp.en == 'Geo-Frailty' then
            FRAILTY_SPELLS[id] = sp.en
        elseif minuet_tiers[sp.en] then
            MINUET_SPELLS[id] = minuet_tiers[sp.en]
        elseif sp.en == 'Aria of Passion' then
            ARIA_SPELL = id           -- expect 418
        end
    end
    for id, ja in pairs(res.job_abilities) do
        if ja.en == 'Box Step' then
            BOXSTEP_ID  = id          -- expect 202
            DAZE_STATUS = ja.status   -- expect 391
        elseif ja.en == 'Chaos Roll' then
            CHAOS_JA = id             -- expect 105 (type CorsairRoll)
        elseif ja.en == 'Soul Voice' then
            SOULVOICE_JA = id
        elseif ja.en == 'Double-Up' then
            DOUBLEUP_JA = id          -- expect 123
        end
        if ja.type == 'CorsairRoll' then
            ROLL_JAS[id] = true       -- any phantom roll (Double-Up attribution)
        end
    end
end

-- Attack-side buff IDs (VERIFIED resources buffs.lua)
local BUFF_BERSERK = 56
local BUFF_MINUET  = 198
local BUFF_CHAOS   = 317
local BUFF_ATTBOOST = { [91]=true, [549]=true }  -- Fury shows as Attack Boost

local function dbg(fmt, ...)
    if settings.debug then
        windower.add_to_chat(8, ('[pdl] ' .. fmt):format(...))
    end
end

local function live(entry)
    return entry and entry.expires > os.clock()
end

local function mob_entry(id)
    if not mobs[id] then mobs[id] = {} end
    return mobs[id]
end

--------------------------------------------------------------------------------
-- Party TP sampler (n / n-1). Party sync is periodic, so the held sample is
-- normally the pre-WS value; when stale it is stale-LOW -> shorter duration
-- estimate (conservative direction).
--------------------------------------------------------------------------------
local function sample_party_tp()
    local pt = windower.ffxi.get_party()
    if not pt then return end
    local current = {}
    for i = 0, 5 do
        local m = pt['p' .. i]
        if m and m.mob and m.tp then
            current[m.mob.id] = true
            local rec = party_tp[m.mob.id]
            if not rec then
                party_tp[m.mob.id] = { cur = m.tp, prev = m.tp }
            elseif m.tp ~= rec.cur then
                rec.prev, rec.cur = rec.cur, m.tp
            end
        end
    end
    -- Prune leavers; recompute DRK-in-party from MAIN jobs only. Self counts
    -- via player.main_job; anon/unknown members read 0/nil -> no DRK.
    local selfp = P()
    drk_in_party = (selfp and selfp.main_job == 'DRK') or false
    for pid in pairs(party_tp) do
        if not current[pid] then
            party_tp[pid], party_jobs[pid] = nil, nil
        elseif party_jobs[pid] == DRK_JOB_ID then
            drk_in_party = true
        end
    end
end

local function estimate_tp(actor_id)
    if actor_id == player_id then
        local pl = windower.ffxi.get_player()
        local tp = pl and pl.vitals and pl.vitals.tp or 0
        if tp >= 1000 then return tp end
    end
    local rec = party_tp[actor_id]
    if rec then
        if rec.cur  >= 1000 then return rec.cur  end
        if rec.prev >= 1000 then return rec.prev end
    end
    return 1000
end

--------------------------------------------------------------------------------
-- Appliers
--------------------------------------------------------------------------------
-- Enemy self-buff tracking: Defense Boost (status 93) and Protect (status 40)
local MSG_GAIN      = { [166]=true, [186]=true, [194]=true, [205]=true,
                        [230]=true, [266]=true, [280]=true, [319]=true }
local BUFF_DEFBOOST = 93   -- VERIFIED resources/buffs.lua
local BUFF_PROTECT  = 40   -- VERIFIED resources/buffs.lua
local res_ma = (res and res.monster_abilities) or {}
-- Sheol Gaol bosses (Aug 2026): offensive Geomancy -85%% on these.
-- Atonement 1-4 complete set; name-matched at defense-computation time.
local SHEOL_GAOL_BOSSES = {
    ['Dealan-dhe']=true, ['Sgili']=true, ['U Bnai']=true, ['Gogmagog']=true,
    ['Aristaeus']=true, ['Raskovniche']=true, ['Marmorkrebs']=true,
    ['Gigelorum']=true, ['Procne']=true, ['Henwen']=true,
    ['Xevioso']=true, ['Ngai']=true, ['Kalunga']=true, ['Ongo']=true,
    ['Mboze']=true, ['Arebati']=true, ['Bumba']=true,
}

local MSG_AFFLICT = { [236]=true, [237]=true }  -- VERIFIED action_messages
-- bg-wiki Defense Down page (pulled Aug 2026): pct, duration (midpoints)
local DEFDOWN_SPELLS = {   -- Blue Magic, by spell name
    ['Benthic Typhoon']={0.10,30},  ['Bilgestorm']={0.25,45},
    ['Corrosive Ooze']={0.05,75},   ['Enervation']={0.10,30},
    ['Frightful Roar']={0.10,180},  ['Seedspray']={0.08,105},
    ['Sweeping Gouge']={0.15,90},   ['Tenebral Crush']={0.20,180},
    ['Tourbillion']={0.33,105},
}
local DEFDOWN_PETMOVES = { -- BST pet ready moves, by move name
    ['Corrosive Ooze']={0.33,77},   ['Rhinowrecker']={0.25,60},
    ['Sweeping Gouge']={0.25,60},   ['Swooping Frenzy']={0.25,105},
    ['Tortoise Stomp']={0.25,155},
}

local function pdl_protect_flat(mob_id)
    local m = mobs[mob_id]
    if m and m.protect and m.protect.expires > os.clock() then
        return m.protect.flat
    end
    return 0
end

local function apply_dia(target, tier, caster_id)
    local m = mob_entry(target)
    if m.dia and live(m.dia) and m.dia.tier > tier then return end
    -- Duration policy (project ruling, Aug 2026): Dia III from a PLAYER assumes
    -- the 50%% waypoint of endgame enfeebling-duration gear; Dia III from a
    -- TRUST (spawn_type 14) assumes job base; Dia I/II
    -- assume no duration gear. Any renewal cast resets the timer (the
    -- overwrite below does exactly that).
    local mult = 1.0
    if tier == 3 then
        -- Trust/fellow = spawn_type 14 (verified: Windower Trusts addon).
        -- Unknown actor resolves as trust, the conservative direction since
        -- the shorter duration drops Dia sooner and delays PDL.
        local cm = caster_id and windower.ffxi.get_mob_by_id(caster_id)
        local is_npc = (not cm) or cm.spawn_type == 14
        mult = is_npc and 1.0 or pdl_config.dia3_player_mult
    end
    local dur = (({ [1]=60, [2]=120, [3]=180 })[tier])  -- VERIFIED resources
                * mult * pdl_config.dia_dur_mult
    m.dia = { tier=tier,
              shot=(m.dia and live(m.dia) and m.dia.tier==tier)
                   and m.dia.shot or false,
              expires=os.clock()+dur, status=DIA_STATUS }
    dbg('Dia %d on %d', tier, target)
end

local function apply_bio(target)
    local m = mobs[target]
    if m and m.dia then m.dia = nil; dbg('Bio cleared Dia on %d', target) end
end

local function apply_daze(target, level)
    local m = mob_entry(target)
    m.daze = { level=level, expires=os.clock()+pdl_config.daze_dur,
               status=DAZE_STATUS }
    dbg('Box Step lvl %d on %d', level, target)
end

local function apply_defdown(target, name, pct, dur)
    -- 149-family application overwrites Defense Boost (mutual-overwrite rule)
    local m = mob_entry(target)
    if m.defdown and live(m.defdown) and m.defdown.pct > pct then return end
    m.defdown = { name=name, pct=pct, expires=os.clock()+dur,
                  status=DEFDOWN_STATUS }
    m.defup = nil
    dbg('%s (%.1f%%) on %d for %ds', name, pct*100, target, dur)
end

-- ITG NM defense seeds (level model 2026-08-23; NM_Defense_Table.md is
-- the sourced reference). Seed est: def = base + per_v * pdl_vengeance.
-- geo_mult marks zone geo-debuff nerfs (Dynamis D ~50%, ffxiah 52513 JP
-- testing); Sheol Gaol keeps its own 0.15 path.
local PDL_NM_DEFENSE = {
    -- Odyssey Sheol Gaol (per_v applies: Vengeance rank scaling)
    ['Arebati'] = { base = 1320, level = 135, per_v = 55, kind = 'tested',
                    src = 'ffxiah 58150 Lockhartt' },
    ['Kalunga'] = { base = 1320, level = 135, per_v = 55, kind = 'modeled',
                    src = 'level model, T3 tier' },
    ['Ngai']    = { base = 1320, level = 135, per_v = 55, kind = 'modeled',
                    src = 'level model, T3 tier' },
    ['Xevioso'] = { base = 1320, level = 135, per_v = 55, kind = 'modeled',
                    src = 'level model, T3 tier' },
    ['Mboze']   = { base = 1320, level = 135, per_v = 55, kind = 'modeled',
                    src = 'level model, T3 tier' },
    ['Ongo']    = { base = 1320, level = 135, per_v = 55, kind = 'modeled',
                    src = 'level model, T3 tier' },
    ['Bumba']   = { base = 1540, level = 139, per_v = 55, kind = 'modeled',
                    src = 'level model 139' },

    -- Omen (project ruling: Glassies 135, others 139)
    ['Glassy Craver']  = { base = 1320, level = 135, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Glassy Thinker'] = { base = 1320, level = 135, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Glassy Gorger']  = { base = 1320, level = 135, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Kyou'] = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Kei']  = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Kin']  = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Gin']  = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Fu']   = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },
    ['Ou']   = { base = 1540, level = 139, per_v = 0, kind = 'modeled', src = 'level model' },

    -- Dynamis - Divergence (CL149 bg-wiki; names bg-wiki zone pages + ffxiah 52513)
    ['Overseer\'s Tombstone'] = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Sandy W1' },
    ['Mu\'Sha Effigy']        = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Bastok W1' },
    ['Evincing Idol']          = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Windurst W1' },
    ['Impish Golem']           = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Jeuno W1' },
    ['Halphas']                = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Sandy W2' },
    ['Ka\'Rho Fearsinger']    = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Bastok W2' },
    ['Fii Pexu the Eternal']   = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Windurst W2' },
    ['Obstatrix']              = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Jeuno W2' },
    ['Disjoined Elvaan']       = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Sandy W3' },
    ['Disjoined Galka']        = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Bastok W3' },
    ['Disjoined Tarutaru']     = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Windurst W3' },
    ['Disjoined Mithra']       = { base = 2090, level = 149, per_v = 0, geo_mult = 0.50, kind = 'modeled', src = 'CL149; Jeuno W3' },

    -- HELM NMs + Escha Ru'Aun additions (project ruling: all 150)
    ['Zerde']       = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Vinipata']    = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Schah']       = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Albumen']     = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Onychophora'] = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Erinys']      = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Teles']       = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Kouryu']      = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },
    ['Warder of Courage'] = { base = 2145, level = 150, per_v = 0, kind = 'modeled', src = 'level model 150' },

    -- HTMB named VD seeds (project ruling: 134 at VD)
    ['Cloud of Darkness'] = { htmb = true, vd = 1320, base = 1320, level = 134, per_v = 0, kind = 'modeled', src = 'level model VD 134' },
    ['Shinryu']           = { htmb = true, vd = 1320, base = 1320, level = 134, per_v = 0, kind = 'modeled', src = 'level model VD 134' },
    ['Lilith']            = { htmb = true, vd = 1320, base = 1320, level = 134, per_v = 0, kind = 'modeled', src = 'level model VD 134' },

    -- Sortie (project ruling 2026-08-23: A-D level 135, E-H 145, Aminon 149)
    ['Ghatjot']   = { base = 1320, level = 135, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie A' },
    ['Leshonn']   = { base = 1320, level = 135, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie B' },
    ['Skomora']   = { base = 1320, level = 135, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie C' },
    ['Degei']     = { base = 1320, level = 135, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie D' },
    ['Dhartok']   = { base = 1870, level = 145, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie E' },
    ['Gartell']   = { base = 1870, level = 145, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie F' },
    ['Triboulex'] = { base = 1870, level = 145, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie G' },
    ['Aita']      = { base = 1870, level = 145, per_v = 0, kind = 'modeled',
                    src = 'level model, Sortie H' },
    ['Aminon']    = { base = 2090, level = 149, per_v = 0, kind = 'modeled',
                    src = 'level model; Incessant Void mode not modeled' },

    -- Open world Locus camps
    ['Locus Ghost Crab'] = { base = 1446, level = 137, per_v = 0,
                    kind = 'measured', src = 'measured in-game 1413-1479' },
}
-- HTMB tier defense, tier-halving model (project rulings 2026-08-23): generic
-- VD = CL 129 (1155); the hard trio (Cloud of Darkness, Shinryu, Lilith)
-- override VD to the 135 anchor via their vd field (1320). Descending,
-- the 55/level slope halves at each knee (135, 129, 124, 119, 116):
-- 27.5, 13.75, 6.875, 3.4375, 1.71875. Tier defaults to VD; Vengeance defaults 25.
local HTMB_TIER_DEF = { ve = 1036, e = 1042, n = 1052, d = 1086, vd = 1155 }
local pdl_htmb_tier = 'vd'   -- //pdl htmb <ve|e|n|d|vd>, defaults VD (project ruling)
local pdl_vengeance = 25   -- defaults V25 (project ruling)   -- //pdl v <n> (Gaol Vengeance rank; session-local)

local function pdl_actor_in_party(id)
    -- true = confirmed party/alliance member; false = confirmed outsider;
    -- nil = cannot confirm (party API unavailable). Members out of zone have
    -- no .mob and cannot be casting nearby, so skipping them is correct.
    if not id then return false end
    local pt = windower.ffxi.get_party()
    if not pt then return nil end
    for _, mem in pairs(pt) do
        if type(mem) == 'table' and mem.mob and mem.mob.id == id then
            return true
        end
    end
    return false
end

local function apply_frailty(pct, dur, source)
    -- Strongest live aura wins (geomancy same-aura stacking rule; project ruling
    -- Aug 2026, crab-log epoch). Equal or stronger recasts refresh the timer.
    if frailty.active and os.clock() < frailty.expires
       and frailty.pct > pct then
        dbg('Frailty %.1f%% (%s) ignored: stronger %.1f%% (%s) live',
            pct*100, source, frailty.pct*100, tostring(frailty.source))
        return
    end
    frailty = { active=true, pct=pct, expires=os.clock()+dur, source=source }
    dbg('Frailty %.1f%% (%s) for %ds', pct*100, source, dur)
end

--------------------------------------------------------------------------------
-- Action packet handling (0x028)
--------------------------------------------------------------------------------
local function set_of(t)
    local s = {} for _, v in ipairs(t) do s[v] = true end return s
end
local SPELL_LAND_MSGS = set_of{2, 252, 236, 237, 268, 271}  -- from Debuffed
local STEP_MSGS       = set_of{519, 520, 521, 591}          -- from Debuffed-Steps

local function on_action(act)
    local t1 = act.targets and act.targets[1]
    local a1 = t1 and t1.actions and t1.actions[1]
    if not a1 then return end

    -- Light Shot (Debuffed: category 6, param 131)
    if act.category == 6 and act.param == 131 then
        local m = mobs[t1.id]
        if m and live(m.dia) then
            m.dia.shot = true   -- potency only; Quick Draw does NOT extend
                                -- duration (project ruling, Aug 2026)
        end
        return
    end

    -- Steps (Debuffed-Steps: message-ID keyed; daze level rides in param)
    if STEP_MSGS[a1.message] then
        if act.param == BOXSTEP_ID then
            apply_daze(t1.id, a1.param or 1)
        end
        return
    end


    -- Defense Down landing on the MOB from any actor: BLU spells, pet
    -- moves, bolt/weapon procs. (WS-family stays on its precise landed-
    -- message path: 185/187 are not in these sets, so no double-apply.)
    if (MSG_GAIN[a1.message] or MSG_AFFLICT[a1.message])
       and a1.param == DEFDOWN_STATUS
       and t1.id ~= act.actor_id
       and not party_jobs[t1.id] and t1.id ~= player_id then
        local nm, ent
        if act.category == 4 then
            local sp = res.spells and res.spells[act.param]
            nm = sp and sp.en
            ent = nm and DEFDOWN_SPELLS[nm]
        else
            local ma = res_ma[act.param]
                       or (res.job_abilities and res.job_abilities[act.param])
            nm = ma and ma.en
            ent = nm and DEFDOWN_PETMOVES[nm]
        end
        local pct = (ent and ent[1]) or pdl_config.defdown_generic_pct
        local dur = (ent and ent[2]) or pdl_config.defdown_generic_dur
        local m = mob_entry(t1.id)
        if not (m.defdown and live(m.defdown) and m.defdown.pct >= pct) then
            m.defdown = { name = nm or 'proc', pct = pct,
                          status = DEFDOWN_STATUS,
                          expires = os.clock() + dur }
            m.defup = nil
            dbg('defdown landed on %d: %s -%d%% (%ds)',
                t1.id, nm or 'proc', pct * 100, dur)
        end
        return
    end

    -- Enemy self-buffs: Defense Boost / Protect gains on the mob
    if MSG_GAIN[a1.message] and t1.id == act.actor_id
       and not party_jobs[t1.id] and t1.id ~= player_id then
        if a1.param == BUFF_DEFBOOST then
            local ma = res_ma[act.param]
            local mname = ma and ma.en
            local pct = (mname and pdl_config.defup_moves[mname])
                        or pdl_config.defup_default_pct
            local m = mob_entry(t1.id)
            m.defup = { pct = pct,
                        expires = os.clock() + pdl_config.defup_default_dur }
            -- Defense Boost OVERWRITES a Defense Down effect (149 family
            -- only -- Dia/steps/Frailty are unaffected) and vice versa
            m.defdown = nil
            dbg('defup on %d: %s +%d%%', t1.id, mname or 'unknown', pct * 100)
            return
        elseif a1.param == DEFDOWN_STATUS then
            -- Rage-type self defense-down: the mob lowered its own defense
            local ma = res_ma[act.param]
            local mname = ma and ma.en
            local pct = (mname and pdl_config.selfdefdown_moves[mname])
                        or pdl_config.selfdefdown_default
            local m = mob_entry(t1.id)
            m.defdown = { name = mname or 'self', pct = pct, status = DEFDOWN_STATUS,
                          expires = os.clock() + pdl_config.defup_default_dur }
            m.defup = nil
            dbg('self-defdown on %d: %s -%d%%', t1.id, mname or 'unknown', pct * 100)
            return
        elseif a1.param == BUFF_PROTECT then
            local m = mob_entry(t1.id)
            m.protect = { flat = pdl_config.protect_flat[act.param] or 0,
                          expires = os.clock() + pdl_config.protect_dur }
            dbg('protect on %d: spell %s flat %d', t1.id,
                tostring(act.param), m.protect.flat)
            return
        end
    end

    -- Frailty casts FIRST within category 4: matched by spell id regardless of
    -- completion message, so the generic block below cannot shadow them.
    -- Per design: fire-and-forget full duration, no early-drop handling.
    if act.category == 4 and FRAILTY_SPELLS[act.param] then
        local spell_name = FRAILTY_SPELLS[act.param]
        local actor      = windower.ffxi.get_mob_by_id(act.actor_id)
        local in_pt      = pdl_actor_in_party(act.actor_id)
        -- Party filter (design decision, Aug 2026 combat log): zone outsiders'
        -- frailty must never book (their auras are not on our mobs).
        if actor and in_pt == false then
            dbg('Frailty from %s ignored: not in party', actor.name)
            return
        end
        -- Ambiguity nerfs DOWN to Sylvie potency (project ruling): nil actor or
        -- unconfirmable membership books 12.5, never the Idris 41.8. Only a
        -- resolvable, confirmed-party, non-Sylvie caster keeps the player-GEO
        -- Idris assumption.
        local sylvie_level = (actor and actor.name == 'Sylvie')
                             or (not actor) or (in_pt == nil)
        if sylvie_level then
            apply_frailty(pdl_config.frailty_sylvie_pct,
                          pdl_config.frailty_sylvie_dur, 'Sylvie-level')
        else
            apply_frailty(pdl_config.frailty_player_pct,
                          pdl_config.frailty_player_dur, spell_name)
        end
        return
    end

    -- Aria of Passion: note SV-ness of the cast (potency doubling)
    if act.category == 4 and ARIA_SPELL and act.param == ARIA_SPELL then
        aria_sv = (sv_actors[act.actor_id]
                   and sv_actors[act.actor_id] > os.clock()) or false
        dbg('Aria of Passion (sv=%s)', tostring(aria_sv))
        return
    end

    -- Minuets: identified per cast (spell id -> tier), Soul Voice look-back
    -- on the singing bard, tracked individually with timers. Only songs that
    -- include US in the target list count.
    if act.category == 4 and MINUET_SPELLS[act.param] then
        local hits_me = false
        for i = 1, #act.targets do
            if act.targets[i].id == player_id then hits_me = true break end
        end
        if hits_me then
            local tier  = MINUET_SPELLS[act.param]
            local svon  = sv_actors[act.actor_id]
                          and sv_actors[act.actor_id] > os.clock()
            local value = pdl_config.att_minuet_tier[tier]
                          * (svon and pdl_config.soul_voice_mult or 1)
            local nowc  = os.clock()
            local found = false
            for i = 1, #minuet_tracks do
                if minuet_tracks[i].tier == tier then
                    minuet_tracks[i].value   = value
                    minuet_tracks[i].expires = nowc + pdl_config.song_dur_default
                    found = true
                    break
                end
            end
            if not found then
                minuet_tracks[#minuet_tracks+1] =
                    { tier=tier, value=value,
                      expires=nowc + pdl_config.song_dur_default }
            end
            dbg('Minuet %d landed (sv=%s) value %d', tier, tostring(svon), value)
        end
        return
    end

    -- Spells (Debuffed: category 4 + landed messages)
    if act.category == 4 and SPELL_LAND_MSGS[a1.message] then
        local sid = act.param
        if DIA_TIER[sid] then
            apply_dia(t1.id, DIA_TIER[sid], act.actor_id)
        elseif BIO_IDS[sid] then
            apply_bio(t1.id)
        end
        return
    end

    -- Defense Down WS (category 3). Landed-message gate: 185 = deals damage,
    -- 187 = drain damage (VERIFIED action_messages.lua); 188 miss / 189
    -- no-effect must NOT apply the debuff.
    if act.category == 3 then
        local ws  = res.weapon_skills[act.param]
        local def = ws and WS_DEFDOWN[ws.en]
        if def and (a1.message == 185 or a1.message == 187) then
            local tp = estimate_tp(act.actor_id)
            apply_defdown(t1.id, ws.en, def.pct, def.dur(tp))
        elseif settings.debug and ws then
            dbg('WS %s msg=%d param=%d (unmatched)', ws.en, a1.message,
                a1.param or -1)
        end
        return
    end

    -- Spirit-Surged Jump (SELF only -- own buffs are knowable): Jump under
    -- Spirit Surge lands Defense Down -20%% for 60s (bg-wiki, Aug 2026)
    if act.category == 6 and act.param == 66 and act.actor_id == player_id then
        local plss = windower.ffxi.get_player()
        if plss and plss.buffs then
            for i = 1, #plss.buffs do
                if plss.buffs[i] == 126 then   -- Spirit Surge status
                    apply_defdown(t1.id, 'SS-Jump', 0.20, 60)
                    break
                end
            end
        end
        return
    end

    -- JA (categories 6/14/15): Chaos Roll source, Soul Voice window,
    -- Defense Down family
    if act.category == 6 or act.category == 14 or act.category == 15 then
        local nowj = os.clock()
        if ROLL_JAS[act.param] then
            last_roll[act.actor_id] = { ja = act.param, t = nowj }
            if act.param == CHAOS_JA then
                local actor = windower.ffxi.get_mob_by_id(act.actor_id)
                chaos_state = { num = a1.param,
                                qultada = (actor and actor.name == 'Qultada')
                                          or false,
                                t = nowj }
                dbg('Chaos Roll %s by %s', tostring(a1.param),
                    actor and actor.name or '?')
            end
        elseif act.param == DOUBLEUP_JA then
            -- Double-Up updates the actor's most recent roll; only relevant
            -- when that roll was Chaos. >11 = bust (buff drops; clear number).
            local lr = last_roll[act.actor_id]
            if lr and lr.ja == CHAOS_JA and nowj - lr.t < 60 then
                local n = a1.param
                chaos_state.num = (n and n <= 11) and n or nil
                dbg('Chaos Double-Up -> %s', tostring(chaos_state.num))
            end
        elseif act.param == SOULVOICE_JA then
            sv_actors[act.actor_id] = nowj + pdl_config.soul_voice_window
            dbg('Soul Voice by actor %d', act.actor_id)
        end
        local ja  = res.job_abilities[act.param]
        local def = ja and JA_DEFDOWN[ja.en]
        if def then
            apply_defdown(t1.id, ja.en, def.pct, def.dur(0))
        end
        return
    end
end

--------------------------------------------------------------------------------
-- Action message handling (0x029): same message sets as both source addons
--------------------------------------------------------------------------------
local DEATH_MSGS   = set_of{6, 20, 113, 406, 605, 646}

local WEAROFF_MSGS = set_of{64, 204, 206, 350, 531}

local function on_action_message(target_id, status_param, message_id)
    if DEATH_MSGS[message_id] then
        mobs[target_id] = nil
    elseif WEAROFF_MSGS[message_id] then
        local m = mobs[target_id]
        if not m then return end
        if m.dia     and m.dia.status     == status_param then m.dia     = nil end
        if m.daze    and m.daze.status    == status_param then m.daze    = nil end
        if m.defdown and m.defdown.status == status_param then m.defdown = nil end
        if status_param == BUFF_DEFBOOST then m.defup   = nil end
        if status_param == BUFF_PROTECT  then m.protect = nil end
    end
end

-- Per-job buffless attack anchor (manually maintained table)
local function pdl_base_attack()
    return settings.base_attack
end

-- Current attack: MEASURED (0x061 char stats, Attack @0x30 raw per Windower
-- packets/fields.lua) when available; modeled fallback otherwise.
local function current_attack()
    if attack_now and attack_now > 0 then return attack_now, true end
    local mult = pdl_attack_multiplier()
    return pdl_base_attack() * mult, false
end

--------------------------------------------------------------------------------
-- /check calibration. Message IDs 170-178 encode the defense verdict
-- (VERIFIED action_messages.lua); bg-wiki Defense gives the thresholds:
-- 'high defense' atk/def < 1.0 | no comment 1.0-1.25 | 'low defense' >= 1.25.
-- Check ignores level correction, so the bracket measures exactly our
-- anchor*att_mult/(1-defdown) quantity at check time; we divide the current
-- state back out and store NAKED ratio bounds per mob, intersected across
-- multiple checks. 249 (impossible to gauge) marks the mob ITG -> static path.
--------------------------------------------------------------------------------
local CHECK_BRACKETS = {
    [170]={0.05,1.0}, [173]={0.05,1.0}, [176]={0.05,1.0},   -- high defense
    [171]={1.0,1.25}, [174]={1.0,1.25}, [177]={1.0,1.25},   -- neutral
    [172]={1.25,nil}, [175]={1.25,nil}, [178]={1.25,nil},   -- low defense
}

local function handle_check(target, message_id, p1, p2)
    local m = mob_entry(target)
    m.check_pending = nil
    if message_id == 249 then
        m.gauge_proof = true
        dbg('check %d: impossible to gauge -> static path', target)
        return
    end
    local br = CHECK_BRACKETS[message_id]
    if not br then return end
    local lo, hi = br[1], br[2]
    if not hi then
        hi = pdl_config.check_hi_cap
        local tier = pdl_config.lowdef_lo_by_rating[p1]
        if tier then lo = tier end
    end
    -- Divide out the state present at check time -> naked bounds
    local dd  = pdl_get_defense_down(target)
    local A   = current_attack()
    -- Ratio bracket -> BASE-defense bounds: ratio = A / (def_base*(1-dd)).
    -- With measured attack these are absolute; checks at different states
    -- (especially WEAKER ones) intersect the bounds tighter.
    local eff = math.max(1 - dd, 0.05)
    local pflat = pdl_protect_flat(target)
    local dlo = math.max(A / (hi * eff) - pflat, 1)
    local dhi = math.max(A / (lo * eff) - pflat, 1)
    local c = m.cal
    if c then
        c.def_lo, c.def_hi = math.max(c.def_lo, dlo), math.min(c.def_hi, dhi)
        if c.def_lo > c.def_hi then c.def_lo, c.def_hi = dlo, dhi end
    else
        m.cal = { def_lo = dlo, def_hi = dhi }
    end
    m.cal.attack_at_check = A
    m.cal.dd_at_check = dd
    m.cal.last_check = os.clock()
    m.cal.rechecks = m.cal.rechecks or 0
    m.cal.rating, m.cal.level = p1, p2   -- raw packet params; VERIFY live via debug
    dbg('check %d: msg %d ratio %.2f-%.2f A=%d dd=%.0f -> defbase %d-%d',
        target, message_id, lo, hi, A, dd*100, m.cal.def_lo, m.cal.def_hi)
end

--------------------------------------------------------------------------------
-- Events
--------------------------------------------------------------------------------
windower.register_event('incoming chunk', function(id, data)
    if id == 0x028 then
        local ok, act = pcall(windower.packets.parse_action, data)
        if ok and act then
            local ok2, err = pcall(on_action, act)
            if not ok2 then dbg('on_action error: %s', tostring(err)) end
        end
    elseif id == 0x061 then
        -- Char stats: Attack unsigned short @0x30 raw (0x31 Lua) per
        -- packets/fields.lua. Measured attack replaces the buff model.
        if #data >= 0x33 then
            local a = data:unpack('H', 0x31)
            if a and a > 0 then attack_now, attack_now_t = a, os.clock() end
        end
    elseif id == 0x0DD then
        -- Party member update: ID @0x04, MAIN job @0x22 (raw offsets per
        -- Windower packets/fields.lua; +1 for Lua string positions). Sub job
        -- is a separate byte (0x24) and is deliberately ignored: /DRK subs
        -- must not trigger the Chaos DRK bonus.
        if #data >= 0x23 then
            local pid = data:unpack('I', 0x05)
            local mj  = data:byte(0x23)
            if pid and pid > 0 then party_jobs[pid] = mj end
        end
    elseif id == 0x029 then
        local target_id  = data:unpack('I', 0x09)
        local param_1    = data:unpack('I', 0x0D)
        local param_2    = data:unpack('I', 0x11)
        local message_id = data:unpack('H', 0x19) % 32768
        if CHECK_BRACKETS[message_id] or message_id == 249 then
            local ok, err = pcall(handle_check, target_id, message_id, param_1, param_2)
            if not ok then dbg('handle_check error: %s', tostring(err)) end
        else
            on_action_message(target_id, param_1, message_id)
        end
    end
end)

-- GlobalSwap's sandboxed register_event accepts ONE event name per call
-- (user_functions.lua register_event_user signature is (str, func)); the
-- Debuffed-style multi-event form hard-errors at load. One call per event.
-- Current MONSTER target, with sub-target tolerance.
-- spawn_type 16 = monster (verified against Windower's own addons: InfoBar
-- labels 16 TargetMOB, Debuffed gates on it; 13/14/9/1 are players and
-- trusts, 2/34 are NPCs). While you sub-target a party member the last live
-- monster is kept so the readout and the job-file push don't drop out.
local pdl_last_mob = nil
function pdl_target_mob_strict()   -- current target ONLY, no fallback.
    -- ACTION paths (issuing /check) must use this: the game resolves
    -- '/check' against whatever is targeted right now, so acting on the
    -- sticky mob would check a sub-targeted party member instead.
    local t = windower.ffxi.get_mob_by_target('t')
    if t and t.valid_target and t.spawn_type == 16 then
        pdl_last_mob = t.id
        return t
    end
    return nil
end

function pdl_target_mob()   -- global: the job-file push site lives outside the tracker block
    -- DISPLAY paths: current monster, else the last live one, so sub-targeting
    -- a party member doesn't blank the readout or stall the job-file push.
    local t = pdl_target_mob_strict()
    if t then return t end
    if pdl_last_mob then
        local m = windower.ffxi.get_mob_by_id(pdl_last_mob)
        if m and m.valid_target and m.spawn_type == 16
           and m.hpp and m.hpp > 0 then
            return m
        end
        pdl_last_mob = nil
    end
    return nil
end

local function pdl_reset_state()
    mobs, party_tp = {}, {}
    frailty = { active=false, pct=0, expires=0, source=nil }
    chaos_state = { num=nil, qultada=false, t=0 }
    last_roll, party_jobs, drk_in_party = {}, {}, false
    sv_actors, minuet_tracks, aria_sv = {}, {}, false
end
windower.register_event('zone change', pdl_reset_state)
windower.register_event('logout', pdl_reset_state)

local function pdl_set_player_id()
    player_id = (windower.ffxi.get_player() or {}).id or 0
end
windower.register_event('load', pdl_set_player_id)
windower.register_event('login', pdl_set_player_id)
player_id = (windower.ffxi.get_player() or {}).id or 0

windower.register_event('prerender', function()
    local now = os.clock()
    local pl = P()
    if now - last_tp_sample >= pdl_config.tp_sample_int then
        last_tp_sample = now
        sample_party_tp()
        -- HUD update
        if settings.visible and pl and pl.status == 1 then
            local ht = pdl_target_mob()
            if ht then
                local est = pdl_estimated_ratio(ht.id)
                hud:text(('PDL: %.2f'):format(est))
                if est >= pdl_threshold() then
                    hud:color(0, 255, 0)
                else
                    hud:color(255, 255, 255)
                end
                hud:show()
            else
                hud:hide()
            end
        else
            hud:hide()
        end
        -- Auto /check: once per engaged mob, never for known-ITG mobs
        if settings.autocheck and pl and pl.status == 1 then
            local t = pdl_target_mob_strict()
            if t then
                local m = mob_entry(t.id)
                -- A /check whose response never arrives (target lost, mob
                -- died, packet missed) would otherwise strand this mob's
                -- autocheck forever. Expire the pending flag and retry.
                if m.check_pending
                   and now - m.check_pending > pdl_config.check_timeout then
                    m.check_pending = nil
                end
                if not m.cal and not m.gauge_proof and not m.check_pending then
                    m.check_pending = now
                    windower.send_command('input /check')
                elseif m.cal and not m.check_pending and attack_now
                       and m.cal.attack_at_check then
                    -- Re-check when the RATIO has moved, from either side:
                    -- a defense buff/debuff landed or wore off on the mob,
                    -- or your own attack shifted 10%. Both narrow the bounds
                    -- because each verdict is intersected with the last.
                    local d = math.abs(attack_now - m.cal.attack_at_check)
                              / m.cal.attack_at_check
                    local ddn = pdl_get_defense_down(t.id)
                    local dchg = math.abs(ddn - (m.cal.dd_at_check or 0)) > 0.005
                    if (dchg or d >= 0.10)
                       and m.cal.rechecks < pdl_config.recheck_max
                       and now - (m.cal.last_check or 0) > pdl_config.recheck_gap then
                        m.cal.rechecks = m.cal.rechecks + 1
                        m.check_pending = now
                        windower.send_command('input /check')
                    end
                end
            end
        end
    end
end)

--------------------------------------------------------------------------------
-- Public API
--------------------------------------------------------------------------------
-- Defense-down total. Stacking per bg-wiki Defense Down: Dia + Box Step +
-- Defense Down family + Frailty are additive; the DD family is exclusive.
function pdl_get_defense_down(mob_id)
    local now = os.clock()
    local m   = mobs[mob_id]
    local b   = { dia=0, step=0, defdown=0, frailty=0, defup=0 }

    if m then
        if live(m.dia) then
            b.dia = pdl_config.dia_pct[m.dia.tier]
                    + (m.dia.shot and pdl_config.light_shot_pct or 0)
        end
        if live(m.daze) then
            b.step = pdl_config.daze_base_pct
                     + pdl_config.daze_per_lvl * (m.daze.level - 1)
        end
        if live(m.defdown) then
            b.defdown = m.defdown.pct
        end
        if m.defup and m.defup.expires > now then
            b.defup = m.defup.pct
        end
    end
    if frailty.active and frailty.expires > now then
        b.frailty = frailty.pct
        local mb = windower.ffxi.get_mob_by_id
                   and windower.ffxi.get_mob_by_id(mob_id)
        if mb and SHEOL_GAOL_BOSSES[mb.name] then
            b.frailty = b.frailty * pdl_config.sheol_gaol_geo_mult
        end
        local zseed = mb and PDL_NM_DEFENSE[mb.name]
        if zseed and zseed.geo_mult then
            -- Zone geo-debuff nerf (e.g. Dynamis D ~50%); never stacks with
            -- the Gaol path because Gaol names carry no geo_mult.
            b.frailty = b.frailty * zseed.geo_mult
        end
    end

    local total = math.min(b.dia + b.step + b.defdown + b.frailty,
                           pdl_config.defense_floor)
    total = total - (b.defup or 0)   -- net; negative = mob defense is UP
    return total, b
end

-- Attack multiplier from own active buffs:
--   mult = 1 + Berserk% + ChaosRoll% + Fury% + (minuet_flats + food)/base_attack
-- Percent JA/roll/geo attack bonuses are additive off base attack; flat song
-- attack converts via the base_attack anchor.
function pdl_attack_multiplier()
    local pl = windower.ffxi.get_player()
    if not pl or not pl.buffs then return 1, {} end

    local pct, song_flat = 0, 0
    local minuets   = 0
    local d = {}
    for i = 1, #pl.buffs do
        local b = pl.buffs[i]
        if     b == BUFF_BERSERK  then pct = pct + pdl_config.att_berserk
                                        d.berserk = true
        elseif b == BUFF_CHAOS    then
            local num  = chaos_state.num
            local base = num and pdl_config.chaos_roll_pct[num]
            local v
            if base then
                local drk = pdl_config.chaos_force_drk
                if drk == nil then drk = drk_in_party end
                v = base + (drk and pdl_config.chaos_drk_bonus or 0)
                if not chaos_state.qultada then
                    -- player COR: full bonuses per design (gear, then Crooked
                    -- x1.2 AFTER job bonus + gear, per bg-wiki)
                    v = (v + pdl_config.chaos_gear_bonus)
                        * pdl_config.chaos_crooked_mult
                end
            else
                -- roll packet not seen (zoned in mid-roll): fallback constants
                v = chaos_state.qultada and pdl_config.att_chaos_qultada
                     or pdl_config.att_chaos_player
            end
            pct = pct + v
            d.chaos, d.chaos_num, d.chaos_qultada =
                true, num, chaos_state.qultada
        elseif BUFF_ATTBOOST[b]   then pct = pct + pdl_config.att_fury
                                        d.fury = true
        elseif b == BUFF_MINUET   then minuets = minuets + 1
        end
    end
    -- Identified-minuet values: live buff count is authoritative for HOW MANY
    -- apply; tracks supply WHICH/how strong. Prune expired, strongest first,
    -- untracked instances assumed full-potency Minuet V per design.
    local nowc = os.clock()
    for i = #minuet_tracks, 1, -1 do
        if minuet_tracks[i].expires <= nowc then
            table.remove(minuet_tracks, i)
        end
    end
    table.sort(minuet_tracks, function(a, b) return a.value > b.value end)
    for i = 1, minuets do
        local tr = minuet_tracks[i]
        song_flat = song_flat + (tr and tr.value or pdl_config.att_minuet_tier[5])
    end
    d.minuets = minuets

    -- MULTIPLICATIVE combination per the sourced attack formula:
    --   Attack = (base + gear + trait/ability/MINUET flat) x (1 + att%),
    --   flat food applied after everything.
    -- Song flat sits INSIDE the % multiplier -- Berserk/Chaos/Fury multiply
    -- the minuet attack too (cross term); flat food stays outside.
    local ba = pdl_base_attack()
    local mult = (1 + song_flat / ba) * (1 + pct)
                 + pdl_config.att_food / ba
    return mult, d
end

-- est_cRatio = base_ratio_anchor * attack_mult / (1 - defense_down_total)
-- Level correction ignored (modern content zones have none).
-- Returns est_cRatio, att_mult, defdown_total, mode
-- mode: 'cal' (check-calibrated, conservative low edge), 'itg-static'
-- (impossible to gauge -> configured anchor), 'static' (not yet checked)
-- Returns est, current_attack, defdown, mode.
-- cal: est = max( A/(def_hi*(1-dd))  [certified floor from check bounds],
--                 base_ratio*(A/base_attack)/(1-dd)  [model estimate] ).
-- The floor is provable; the model term lets a 'low defense' open bracket
-- rise past its 1.25 floor when measured attack is clearly overwhelming.
function pdl_estimated_ratio(mob_id)
    local dd, _ = pdl_get_defense_down(mob_id)
    local A, measured = current_attack()
    local eff = math.max(1 - dd, 0.05)
    local m = mobs[mob_id]
    -- model: assumed mob defense = base_attack/base_ratio, plus any
    -- tracked Protect flat, times the net defense percentage
    local assumed_def = pdl_base_attack() / settings.base_ratio + pdl_protect_flat(mob_id)
    local model_est = A / (assumed_def * eff)
    local est, mode
    if m and m.cal then
        local floor_est = A / ((m.cal.def_hi + pdl_protect_flat(mob_id)) * eff)
        est = math.max(floor_est, model_est)
        mode = measured and 'cal' or 'cal~'
    elseif m and m.gauge_proof then
        -- Seeded ITG NMs: name-keyed base defense
        -- from PDL_NM_DEFENSE, Vengeance-scaled, replaces the blind anchor.
        local smb = windower.ffxi.get_mob_by_id
                    and windower.ffxi.get_mob_by_id(mob_id)
        local seed = smb and PDL_NM_DEFENSE[smb.name]
        if seed then
            local sbase = seed.htmb
                          and ((pdl_htmb_tier == 'vd' and seed.vd)
                               or HTMB_TIER_DEF[pdl_htmb_tier])
                          or seed.base
            local sdef = sbase + (seed.per_v or 0) * pdl_vengeance
                         + pdl_protect_flat(mob_id)
            est, mode = A / (sdef * eff), 'seed'
        else
            est, mode = model_est, 'itg-static'
        end
    else
        est, mode = model_est, 'static'
    end
    return est, A, dd, mode
end

-- Threshold for the CURRENT job state. Base per-job onset (main-job trait
-- baked in), lifted by: sub-job Damage Limit tier I on no-trait mains, and
-- Aria of Passion (PDL multiplies the cap: thr' = (thr+0.375)*(1+pdl)-0.375).
local function pdl_weapon_cap()
    -- equipped main weapon via item id (no GearSwap player table here)
    local eq = windower.ffxi.get_items and windower.ffxi.get_items()
    local slot = eq and eq.equipment and eq.equipment.main
    local bag  = eq and eq.equipment and eq.equipment.main_bag
    if not slot or slot == 0 then return nil end
    local bagt = windower.ffxi.get_items(bag or 0)
    local it   = bagt and bagt[slot]
    local id   = it and it.id
    local rit  = id and id > 0 and res.items and res.items[id]
    local sk   = rit and rit.skill
    return sk and pdl_config.skill_caps[sk] or nil
end

function pdl_threshold()
    local plr = P()
    local job = plr and plr.main_job
    local thr
    local cap = pdl_weapon_cap()
    if cap and job then
        thr = cap + (pdl_config.main_trait[job] or 0) - 0.375
    else
        thr = (job and pdl_config.thresholds[job]) or pdl_config.threshold_default
    end
    if job and pdl_config.no_trait_mains[job] then
        local sj = plr and plr.sub_job
        local sl = plr and plr.sub_job_level
        local need = sj and pdl_config.subjob_trait_level[sj]
        if need and sl and sl >= need then thr = thr + 0.10 end
    end
    local pl = windower.ffxi.get_player()
    if pl and pl.buffs then
        for i = 1, #pl.buffs do
            if pl.buffs[i] == BUFF_ARIA then
                local aria = settings.aria_pdl
                             * (aria_sv and pdl_config.soul_voice_mult or 1)
                thr = (thr + 0.375) * (1 + aria) - 0.375
                break
            end
        end
    end
    return thr
end

function pdl_is_viable(mob_id)
    local est = pdl_estimated_ratio(mob_id)
    return est >= pdl_threshold()
end
--------------------------------------------------------------------------------
-- Addon commands
--------------------------------------------------------------------------------
windower.register_event('addon command', function(cmd, a1, a2)
    cmd = cmd and cmd:lower() or ''
    if cmd == '' then
        settings.visible = not settings.visible
        if not settings.visible then hud:hide() end
        config.save(settings)
        windower.add_to_chat(8, '[PDLTracker] window: '
            .. (settings.visible and 'On' or 'Off'))
    elseif cmd == 'base' and tonumber(a1) then
        settings.base_ratio = tonumber(a1)
        config.save(settings)
        windower.add_to_chat(8, '[PDLTracker] static anchor: ' .. settings.base_ratio)
    elseif cmd == 'atk' and tonumber(a1) then
        settings.base_attack = tonumber(a1)
        config.save(settings)
        windower.add_to_chat(8, '[PDLTracker] buffless attack: ' .. settings.base_attack)
    elseif cmd == 'v' then
        local n = tonumber(a1)
        if n then
            pdl_vengeance = math.max(0, math.min(25, n))
        end
        windower.add_to_chat(8, '[PDLTracker] Vengeance: V' .. pdl_vengeance
            .. (n and '' or ' (usage: //pdl v <0-25>)'))
    elseif cmd == 'htmb' then
        local t = a1 and a1:lower()
        if t and HTMB_TIER_DEF[t] then
            pdl_htmb_tier = t
        end
        windower.add_to_chat(8, '[PDLTracker] HTMB tier: '
            .. pdl_htmb_tier:upper()
            .. ((t and HTMB_TIER_DEF[t]) and (' (def basis ' .. HTMB_TIER_DEF[t] .. ')')
                or ' (usage: //pdl htmb <ve|e|n|d|vd>)'))
    elseif cmd == 'save' then
        local x, y = hud:pos()
        if x and y then
            settings.pos.x, settings.pos.y = x, y
        end
        config.save(settings)
        windower.add_to_chat(8, ('[PDLTracker] position saved: %d,%d')
            :format(settings.pos.x, settings.pos.y))
    elseif cmd == 'debug' then
        settings.debug = not settings.debug
        config.save(settings)
        windower.add_to_chat(8, '[PDLTracker] debug: '
            .. (settings.debug and 'On' or 'Off'))
    elseif cmd == 'status' then
        local t = pdl_target_mob()
        if t then
            local est, atk, dd, mode = pdl_estimated_ratio(t.id)
            windower.add_to_chat(8, ('[PDLTracker] est %.2f [%s] atk %d defdown %d%% thr %.2f')
                :format(est, mode, atk, dd * 100, pdl_threshold()))
        else
            windower.add_to_chat(8, '[PDLTracker] no target')
        end
    else
        windower.add_to_chat(8, '[PDLTracker] //pdl | //pdl save | //pdl base <n> | //pdl atk <n> | //pdl v <0-25> | //pdl htmb <ve|e|n|d|vd> | //pdl status | //pdl debug')
    end
end)
