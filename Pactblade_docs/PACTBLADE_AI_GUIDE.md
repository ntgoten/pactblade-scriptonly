# Pactblade - guide for an AI agent (state: release 1.1, 2026-10-25)

Purpose: everything an agent needs to rebuild, extend or debug the Pactblade custom vocation for Dragon's Dogma 2
(post-DLC PC build) without re-discovering it. Dense on purpose. Companion for humans: PACTBLADE_MODDER_GUIDE.md; code-level reference (hooks, tables, game calls, excerpts,
full hook / callback index): PACTBLADE_CODE_WALKTHROUGH.md.
Deeper references in the project folder: TECHNIQUES.md (cookbook of working recipes + crash list), DESIGN.md (full
history, newest at the bottom - grep it, don't read it whole), HANDOFF.md (older state notes).

## 0. Ground rules (learned the hard way)
- Runtime = REFramework Lua (one big script `Pactblade.lua` + module `Pactblade/DimensionDoor.lua`), library
  _DragonCore >= 1.2.0 (`require("DragonCore.game.runtime")` etc.), VocationAndSkillBuilder (VSB) >= 1.4.0 for the
  vocation and the skill entries, _ScriptCore (`require("_SharedCore/Functions").cast_ray`) for ground rays.
- MAIN CHUNK IS AT LUA'S 200-LOCALS LIMIT. New code: `;(function() ... end)()` blocks, or fields on `dbg` / existing
  tables. A do-block does NOT free locals for the main chunk. Code above a local can't see it: share via `dbg.*`.
- `lupa load()` only checks SYNTAX. A table/local used on a line BEFORE its `local` definition is a nil global at run
  time and throws every frame -> in REFramework an error in one `re.on_*` callback stops the callbacks registered after
  it for that entry point (1.0 release bug: the beam, the slash wave and tints broke). Check forward references with
  a script (name used before its top-level definition line) before every install.
- Never put `-- comment` inside a table line in a string patch (eats the rest of the line).
- After any crash: bursts of `Exception thrown in REMethodDefinition::invoke` in `re2_framework_log.txt` first.
- Script resets keep game state (e.g. a created clone, a shell param instance); a "fix" verified after a reset may be
  a state effect - compare with a known-good version in the SAME game session before blaming the code.
- Effects: only NEW paths in paks (`vfx/effects/pactblade/pb_*.efx`); overriding a game path crashes at start.
- Paks load at game start only; a running game locks them.

## 1. Files
- Source: `src_integrated/Pactblade.lua` (~11.7k lines), `src_integrated/Pactblade/DimensionDoor.lua` (built by
  `src_integrated/build_dd_module.py` from the standalone Dimension Door 0.8.5; `standalone` arg = the standalone 0.8.6).
- Patches: `src_integrated/patch_*.py` / python heredocs with `rep(old, new)` count asserts.
- VSB pack: `vsb_pack_integrated/pactblade/pack.json` + `skills/pb_*.json` -> game `reframework/data/VSB/packs/pactblade`.
- Effects/sounds pak source: `pak_release/natives/stm/...` (136 files), names list `pak_release_names.list`
  (vanilla list + ours; needed to unpack by name). Pack: `tools/ree-pak/ree-pak-cli.exe pack -i pak_release -o <out>.pak`.
- Release: `release/Pactblade-1.0/Pactblade/` (Fluffy layout: modinfo.ini, README.md, reframework/, pak_mods/Pactblade.pak)
  -> `release/Pactblade-1.0.zip`; Nexus text `release/NEXUS_DESCRIPTION.txt` (BBCode). GitHub clone: `dist/repo`.
- Saved versions: `versions_integrated/` (`Pactblade-1.0-RELEASE.lua`, `-testmenu.lua`, `i-0.7-SAVE-fallback...`).
- Build check: `PYTHONPATH=tools/pylibs python -c "from lupa import LuaRuntime; ... load(src)"` (A:/.ClaudeModding/tools).
- RELEASE switch: top of Pactblade.lua, `local RELEASE = true` inside a do-block wraps `json` (json.RELEASE): short menu,
  and json.dump_file only writes Pactblade.json, Pactblade_guise_items.json, Pactblade_vsb_pick.json,
  Pactblade_guise_sounds.json, Pactblade_trace.json. Test build: `RELEASE = false` (full menu, Debug, Recorder, spawner).

## 2. Architecture
- `live` table (line ~350): `live.on` = VSB picks Job01 == "pactblade" (`VSB_API.app.picks.Job01`) AND
  `a:weapon_job() == 1`; `live.go` / `live.am` = player GameObject / ActionManager addresses (updated every frame in
  update_body); `live.settled` = on for >= 2 s (warm-ups, arm glow, clone ensure wait for it).
- VSB ADAPTER (right after `local live`): the 8 VSB skills are separate HumanCustomSkillIDs assigned by VSB
  (`json.load_file("VSB/state/idtable.json").ids.custom[uuid]`; uuids fixed, uuid5). On
  `PlayerInputProcessorDetail.processCustomSkill(HumanCustomSkillID, ...)` (args[3]) and
  `processCustomSkill(app.CharacterInput.Action, HumanCustomSkillID, ...)` (args[4]; the AIR path) a VSB id is rewritten
  to the Fighter id the skill code is bound to, `dbg.pbDepth++` for the call (`dbg.press_ok()`), and
  `HumanSkillAvailability.isCustomSkillAvailable(+WithoutItemCondition)` answers yes for that translated id.
  Every Pactblade trigger hook checks `dbg.press_ok()` -> real Fighter skills stay vanilla.
- Bindings (kind -> Fighter id the code listens to): smite Job01_BlinkStrike, slash Job01_HindsightSlash,
  blast Job01_ShieldSummons, brew Job01_FullMoonSlash, guise Job01_DivineDefense, combo Job01_BravesRaid,
  dive Job01_RisingLunge, strike Job01_CymbalAttack (cfg.*Skill for the rebindable ones).
- VSB skill JSON = presentation (name/desc/icon), levels {1,2} (unlock_rank, dcp_cost; 2 levels avoid a guild crash),
  trigger slot, timeline `[{type:"script", fn:"return true"}]` (placeholder; the Lua does the work).
- Ranks/DCP: brew 1/300, slash 1/300, strike 2/500, dive 3/800, blast 5/1500, combo 7/2500, smite 8/3000, guise 9/4000;
  level 2 = same rank, 100 DCP. Vocation icon 46. Stat growth = Fighter's.
- Playing actions: `a:request_action(name, layer)` (DragonCore actor) with an `ourReq` flag so our own
  `ActionManager.requestActionCore(Priority, String, UInt32)` pre-hooks ignore it. Those hooks refuse the game's
  follow-ups / landings with SKIP_ORIGINAL. All 11 player-only requestActionCore hooks start with
  `if not live.am or sdk.to_int64(args[2]) ~= live.am then return end` (perf: they ran for every NPC request).
- Per-frame entry points used: UpdateBehavior (pre) for logic/warps, UpdateMotion for motion forcing, LateUpdateBehavior
  (pre/post) for following / pinning, BeginRendering for material colours. Many callbacks; each must return early.

## 3. Passives / always-on (no slot)
- Damage: `HitController.calcDamageValue` post (big hook): player hits Damage x (phys + 1.5 mag)/(phys + mag);
  blasts: magick base x DamageRate x BLAST[kind].factor (charged 0.4255, tap 0.2127); slash x2; Hex x1/0.9.
- Sword: with a sword the held weapon's item data gets Magick = Strength and element Thunder (ELEMENT_CHOICES pick 4,
  _ElementStore 100), via item master data AND the equipped Main StorageData's own _ItemData copy (upgraded swords
  carry one - changing only the master data does nothing for them), then a full recalc (EquipData clearParam + calc +
  applyEquipDataForCharacter); restored when inactive and around every save / online upload (guard; it lets go by
  itself after 5 s if a save's end never comes).
  Boons (StatusCondition 15/16/17) refused in `reqStatusConditionApplyCore` for the player.
- Speed: basic attacks via `a:set_speed` (Onslaught Job01_AttackLeft/Right/Air 1.5, other Job01 attacks 1.2).
- Core skills: `isNormalSkillEnable` / `isNormalSkillAvailable` hooks GRANT {17 BreakFall, 18 KickWall, 27 Quik Fot},
  DENY {4, 5, 7, 8} (shield cores). Footpad = `InputProcessor.DetailInstances[3]:processKickWall()` every frame; Quik
  Fot window = DetailInstances[6] `processJustMagicBind()`.
- Shield: `ItemManager.setEquip(..., SlotEnum 1 = sub, ...)` refused for fresh equips; Job01 Guard/Shield actions refused.
- Vocation button (JobSpecialAction), state machine `st` (~line 1500): tap (< HOLD_SEC 0.5) = Job04_Dodge (Thief's Swift
  Step); hold = charging (rim glow pulse), release = Eldritch Bolt = Job07_MagicBindComplete + our shell (JOB07_SHELLS
  "AppSystem/Shell/UserData/HumanShellParamData_Job07.user" shell 12 via DragonCore spawn) at L_Hand_Palm; the action's
  own Forbeding Bolt is let through (it BINDS); other own shells blocked in ShellManager.requestCreateShell.
  Burst = press during / right after Onslaught (0.8 s) / ground Empale frames 56.6-110.5 / air Empale 0.8 s / Tusk Toss
  frames 50-91: charged animation + hidden shell 13 hit area (2.5 m, arc 150, flinch only). `st.recover`: an attack
  press during the Burst recovery cuts it (NormalLocomotion). Blocked while levitating, carrying, busy (rope / climb /
  hurt), and while Dimension Door owns the button (`dbg.dd_block()`).
- Shell effect scale: `shape_effects(b)` sets the shell param's effectParam EffectScale = b.fx (0.5) for 1 s around a
  spawn (params learned at warm_up). Explosion clouds scaled to cfg.boom (0.31). Launch flash = our baked copy of
  -1/8/40 (pb_40_e285) via parts.play_ours, then x0.3 (Bolt, air Blast) / x0.5 (Burst).
- Bind window: Human.Job07ActionCtrl.MagicBindCtrl `get_IsJustMagicBindEnable()` (dbg.leapOpen),
  target `get_MagicBindShellHitOwner()`. Jump -> Misty Step (Job07_MagicBindJustLeap, own move to the target) or after a
  Burst `dbg.burst_step` (warp to the far side). Interact/GimmickAction -> Hex.
- Hex: 15 s, -10 % defence (hits x1/0.9), 15 % max HP on a kill while hexed, 10 % max stamina, X marker = 2 frozen
  copies of our shimmer (pb_hexx_b1-3) above the head scaled with creature height.
- Hellish Rebuke: hit with no reaction / a flinch (not status ticks) -> 0.5 s window (`hr.open`) -> Interact: 30 % max
  stamina, cooldown 6 s (game clock), faces the attacker, Mage cast end clip 9112/750 x1.2, super armour; attacker:
  directDamage 30 Hitback_M power 10000 IsForceReceived, then FireSpread (5); green flames = our pb_bs/bc/bl*_gy2 copies
  swapped into the burning character's own body-effect data (hr.swap_flames, per character kind), Heat_* material
  recolour for scorches, torch pb_torch_gy in the palm, pb_40/43_gy explosion, own sound 1047135920. While the Hex
  window is open, Interact belongs to Hex (rebuke ignores it).
- Dimension Door: module; hold vocation + Go! (CharacterInput.Action bits: JobSpecialAction 29, Go 18; pawn command bits
  17-20 cleared while held) or key B; available while live.on (option all vocations). Aim camera = MainCameraController
  lateUpdate post writes `_CameraJoint` position (up 0.8, right 0.6). Target pillar = rings of the door's frost shimmer
  (wp00/009 enchant_25 efx on own EffectPlayers), no light. Teleport = Character.warp(ResetPosRotContext) in the input
  hook, camera flight scene, carried NPC warped + PosRotRecorder reset. Combo cancels Eldritch Bolt (`M.block()`).

## 4. Skills (implementation)
| Skill | Trigger id | Animation | Core mechanism |
|---|---|---|---|
| Eldritch Slash | HindsightSlash | Warrior Job05_CrescentSlashNormal 0-97 (super armour) | at cfg.slashFrame fire Magike Cut wave = Job07 shell 6 from R_Hand_Palm; range via ShellAdditionalJob07SubNormalAttackShell.update DefaultRangeDist; wave ends by set_RequestKill; parts -1/10/1 (follows the wave), -1/10/3, -1/10/6 replaced by baked pb_10_*_h285; wave dmg x3 (BLAST.slash.dmgMul; its hits come from the wave's SUB-shells -> any player shell hit within 4 s of dbg.slashT without another kind = "slash"), the swing itself x2 (combo.slash.on in calcDamageValue), stagger 5; turns toward the nearest enemy; 160 stamina |
| Tasha's Caustic Brew | FullMoonSlash | Mage chant: dynamic motion bank 9112 = ch00_006_atk.motlist (710 start, 712 loop, 750 release), MotionFsm2 paused (castT) | 3 s chant (Mage circle cs 0/304 on our anchor in front), then acid wave pb_acid_v3 from 1 m ahead; every 0.3 s enemies in the strip (half width 1.25 m) take 72 directDamage + 35 poison points (own meter, 100 = Poison via reqStatusConditionApplyCore), lingers 5 s; splash sounds from monster bank ch221000 (trigger 3870869112); 150 stamina at the pour (setRemainingAmount: `add` is ignored during chants); a damage reaction requested for the player during the chant (Dmg*/Caught*/Down/Blown/Slam) cancels it |
| Misty Strike | CymbalAttack | Job07_SkyDive crouch (bank 170) held 0.25 s -> warp behind the target (radius + 1.2 m, far side) -> Riotous Fury Job01_BravesRaid 110/1701 crossfaded to frame 106 | after the hit: x1.7 speed from 150 (set_Frame step - the layer speed is ignored), any attack/skill/jump/vocation/dash press from frame 170 ends it (crossfade to the last frame, 8 frames), cut at 235; landing/fall requests refused while it plays; from a jump: 0.2 s air hold with SkyDive launch effects; target = beam's aim pick 15 m; ground height from cast_ray; 110 stamina |
| Misty Dive | RisingLunge | SkyDive prep jump -> warp 1.8 m above the enemy -> air Empale (Job01_HeavyAttackAir) | own descent (x/z follow the enemy, never up, 7 m/s), held at its head up to 0.25 s, sure hit directDamage 1500 Hitback_L, lands just outside its body - except on big ones (CharaController radius >= md.bigRadius 1.0): released to fall onto its body (Skydragon-like); SkyDive teal replaced by baked copies (md.FX 14/7/10, 14/7/11, 13/0/10, 0/15/0 -> pb_sd*_h<hue>); super armour; 15 m; 110 stamina |
| Eldritch Blast | ShieldSummons | ground: Riotous Fury's opening Job01_BravesRaidStart (fire at frame 57, x1.5 until then); air: Job07_MagicBindComplete (fire at 0.3 s, button entry hook) | beam = a ROW of frozen copies of the Golem hand flash (pb_beamrowf) palm -> target, grows 0.1 s, holds 0.45 s; hit = our pb_40/43 copies + directDamage magick x3.5 (Hitback_M, power 300); animation effects killed on the ground; air keeps them except 13/20/56 (big swirl) and tints the charge cloud 0/160/0; launch flash at the palm x0.3; 200 stamina (the game's 480 swapped in a StaminaManager.add pre-hook) |
| Archfey Combo | BravesRaid | Kite Arrow Job02_StartFlightShot 0-71.6 -> warp to a side -> Job01_RushAttack 34-67 -> warp behind -> Job01_RushAttackFinish 25-54 -> warp above the head -> Job01_EndRisingLunge -> game landing | dynamic warp spots on a cross around the target (opposite side first, then unused sides); each warp: wisps (weapon element 30 via a hidden Stalwart Sword donor) + Mystic Spearhand afterimage clone at the departure spot (AfterImageHandler init(false)+start, pinned, joint-pose snapshot, purple) + Blink Behind cues; Kite Arrow follow-ups refused; the Rush parts' dust killed; opening turns to the target (360 deg/s, 12 m, 70 deg); 250 stamina |
| Eldritch Smite | BlinkStrike | Job05_ShortRangeHeavyAttack 0-66.6 -> Job05_ArcOfObliterationEnd from 50 (crossfade 12 frames), x1.5 from 150 to 347 | part 2 boosts the Nox blade glow x2.5 + a 2nd shimmer; first melee hit in part 2 -> our explosion copy -1/8/43 x2.5 at the victim; knock-down: Slam_L at power x150 on living enemies; on a KILL no forced Slam (DamageRagdollBlow: IsBlownWithAttackVelocity false, ragdoll velocity limit 2.5 for 2 s) so loot doesn't fly; own sounds (charge 199459528, hit 3434957627); full drain + 20 % back on a hit |
| Tasha's Otherworldly Guise | DivineDefense | Caustic Brew's chant | see 4.1; 60 s (game clock, paused in menus), a spell slot + 25 % stamina at gu.release, recast renews (and uses a slot) |

### 4.1 Otherworldly Guise
- Clone = Trickster decoy `Human.<Job09ActionCtrl>.<DecoyHandler>` (create() if no Instance; init(false)+start). NEVER
  an own CloneCharacterHandler (crash), not the Job07 afterimage (shared with the warps).
- Dress: decoy `get_PartSwapper()` `_Meta._TopsStyle/_PantsStyle` (Grand Cuirass + Raptor Claws by default) +
  `requestSwap(Parts.Tops/Pants)`; wait for the parts' mesh paths; every other mesh off. Body-level parts only (a body
  mesh on the head part crashed).
- On me every frame: transform + every joint's local pos/rot copied; clone Motion off; scale 1.10/1.04/1.06.
- Look: material floats every BeginRendering (Illusion_Enable 1, AlphaRate_Front 0.25, FadeRate 0.30 chest / 0.38 legs,
  AlphaRate_Rim 0.80, RimAlphaGrad 1, Dither 1); RimLight colours (hue 269, sat 0.81, x1.9); Mirage Dance cs_010_00 copy
  pb_ai00 (cloud, tint 3.79/0.34/1.82, 70 % speed).
- Keep alive: <ElapsedSecond> 0, <IsDie>/<FinishDamage> false, clearHate (not a lure); block SmokeDecoy owner reactions
  (onOwnerDamageReaction, ...) and the clone's own end paths (CloneCharacter/DecoyHandler finish/vanish/...) while ours.
- Bonuses visible on the status screen: change the worn chest item's master data (ItemArmorParam _PhysicalDefence,
  _MagicDefence x1.2, _FireDefence, _FireResist, _PoisonResist) then `Data:clearParam()` + `Data:calc()` +
  `applyEquipDataForCharacter`; originals kept in data/Pactblade_guise_items.json; reverted at the end and around saves.
- Protection (1.0.1): the item values only show on the screen. Real: while gu.on, every frame
  StatusConditionCtrl.get_ActiveStatusConditionFlagProp (bit 1 << enum) -> FireSpread (Caught Fire), OilSpread (Torched),
  Poison (Blighted), VirulentPoison (Fulminant Poison) cured at once (reqStatusConditionCure(enum, false)); statuses also
  arrive through flag-list paths that skip reqStatusConditionApplyCore (that hook refuses them too). Fire-element hits
  on me (AttackUserData._ElementType / DamageInfo.get_ElementType == 1) x gu.fireTaken (0.5) in calcDamageValue post.
- Levitate: hold Jump in the air (again 0.3 s after letting go, rise capped from the jump's first float): own float in LateUpdateBehavior post + CharaController warp, reset SecFall /
  FreeFallCtrl each frame, FallInfo only at the end; Mage anims bank 3 (5010 start, 5000 keep); stick steering.
- Sounds: record the decoy's first-start triggers and replay; stop via SoundManager.stopEventByRequestId.
- Known: the decoy's gold dissolve can linger where the guise ended (cleared by the next cast); rest doesn't end it
  (hooks on BarRoomTimeSkipStateBase/CampStateBase 'restart' never fire - candidate states:
  BarRoomTimeSkipStateFinish.onBarRoomTimeSkipStart, CampStateResetCharacterStatus.onCampStart - untested).

### 4.2 Spell slots (1.1)
- `dbg.slots` (block at the end of the file): `max = min(5, 1 + floor(level / 15))`, level = `a.character:get_Human()["<StatusContext>k__BackingField"]:call("get_Level")`
  (read every 1 s); `used`; sequential recharge `rechargeAt = dbg.gclock() + 20`. `SL.use()` (false = none free),
  `SL.free()`, `SL.deny()` (red flash), `SL.fill()`.
- Smite: `sm.press` calls `SL.use()` before `sm.want`. Guise: `gu.press` needs `SL.free() >= 1`, `gu.release` calls
  `SL.use()` (fizzles without). Stamina: Guise `gu.skill.staminaPct = 0.25`; Smite part 2 sets
  `dbg.stamSwap = { mul = 0.5 }` (the StaminaManager.add pre-hook halves the Arc's big drain).
- Greyed out: hooks on `HumanSkillAvailability.isCustomSkillAvailable(+WithoutItemCondition)(HumanCustomSkillID)`: for
  the player's availability object (`live.avail`) and a VSB id whose adapter kind is smite / guise, when `used >= max`
  the post returns `sdk.to_ptr(0)`.
- HUD: `re.on_frame` + `draw.filled_circle` / `draw.filled_rect`; screen size `imgui.get_display_size()`; hidden when
  not active or `GuiManager:isPausedGUI()`. Layers per slot: shadow 1.14r, bronze rim r / 0.88r / 0.78r, core 0.71r,
  gem 0.66r / 0.55r / 0.38r (ABGR 0xFF6B1D4B / 0xFF9C2C6D / 0xFFC9559A) + shine; ready: breathing halo, orbiting light
  with a 5-dot tail; used: `SL.fade` (swell x1.45, alpha to 0 in 0.6 s); recharging: `moon(cx, cy, g, p, col)` = 1 px
  strips from `-half` to `half * (1 - 2p)` (waxing from the left); refilled: `SL.flash` 1 s bloom. Settings in
  `Pactblade_slots.json` (`SL.menu()` in the release and test menus; the file is in the release json KEEP list).

## 5. Effects pipeline (how every purple effect was made)
1. Find the effect: Recorder (test menu Debug) -> data/Pactblade_chant_record.json lists every effect id
   (DataContainerIndex/ContainerID/ElementID + set path), sound trigger and motion for N s.
2. Map id -> file: the player's ObjectEffectManager2 data (hr.each_fx_data walks StandardDataMap + ExpertProviderInfoList
   of the manager and every ExternalDataContainer; element `getResources(i):get_ResourcePath()`); dump button writes
   data/Pactblade_fx_data.json.
3. Extract: `catalog-tool pakget <game dir> <out> natives/stm/<path>.efx.5965310` (use tools/catalog-tool/out via
   tools/dotnet10/dotnet.exe; the bin/Release build is stale). Inspect layers: `catalog-tool efx <file>`.
4. Bake: `efxtint <in> <out.efx.5965310> r g b` (the output NEEDS the .5965310 extension or REE-Lib can't re-read it).
   Hue 285 = 191,0,255; 300 = 255,0,255; 315 = 255,0,191. Layers named inv* are inverted: 2 passes (EFX_SKIP=<inv names>
   at H, EFX_ONLY=<inv names> at H+180). Hide layers by alpha bytes / efxhide (leaf layers only). Gradient textures:
   recoloured copy under a same-length name + byte-replace the UTF-16 path.
5. Ship under vfx/effects/pactblade/pb_*.efx in pak_release, repack, verify by unpacking with the names list.
6. Use: (a) own EffectPlayer on an own GameObject (create_resource + create_holder + createComponent + set_Resource +
   AutoStart; one player per GO; move it every LateUpdate), (b) kill the game's container in the requestEffect post-hook
   and play ours (parts.play_ours / md.FX), (c) swap the file in the character's effect data (`el:setResources(i, holder)`,
   restore later) when the effect must stay on the body's bones (body flames).
- Runtime tint `ep:set_Color` multiplies and can veil the screen on see-through layers -> prefer baked copies;
  cfg.noTint holds ids never tinted.

### 5.1 Pak catalogue (pak_release, 136 files: 131 efx + 5 gradient textures; all under vfx/effects/pactblade/)
| File(s) | Source effect | Used by |
|---|---|---|
| pb_40_e285/300/315 (+ _g120, _gy) | Eldritch Bolt shell container 8 element 40 = launch flash (cs_008 family), mesh colour hash f20fbe80 tinted | Bolt / Burst / air Blast launch (parts "ours", scaled 0.3 / 0.5), beam hit; g120 / gy = Hellish Rebuke |
| pb_43_e285/300/315 (+ _g120, _gy) | same, element 43 = explosion (cs_008_31); fog layers sk0 / ky0 / mkky / miky / mky + debris hidden | Bolt / Burst explosion (scaled cfg.boom 0.31), Smite part-2 hit (x2.5), beam hit; Rebuke explosion |
| pb_10_1 / _3 / _6 _h<hue> | Magike Cut wave (Job07 shell 6) container 10 elements 1 / 3 / 6 | Eldritch Slash wave (10_1 follows the wave) |
| pb_beam*, pb_beamrow[b-g], pb_beamhand, pb_beamhit[2] _h<hue> | Golem hand flash 030_01 (ch52/000) and 030_03; variants with blur / shock / dis / com_CamS / com_RadialS layers hidden by alpha or light black | Eldritch Blast beam row (beamrowf = the final look), hand flash |
| pb_sd10 / sd11 / sd20 / sd21 / sdex / sdns10 _h<hue> | Skydragon (Job07_SkyDive) pieces 14/7/10, 14/7/11, 14/7/20, 14/7/21, 0/15/0 (ch00 EX flash, inverted layers at the opposite hue), 13/0/10 | Misty Dive / Misty Strike (md.FX swap, air hold effects) |
| pb_ai00 / ai20 _h<hue> | Mirage Dance cs_010_00 elements 0 / 20 (20 = black pulsing distortion, unused) | Guise cloud, afterimage aura |
| pb_arm_h<hue>g1-4, pb_arm_no_dis | Mystic Spearhand charge glow (ch07 ns 25), distortion layer hidden, colours + light colours tinted, RgbCommon intensities x1 / x2 / x3.5 / x6 | arm effect (glow strength 1-4) |
| pb_bs10-12 / 15-17 _g120 / _gy / _gy2 | player body flames ch00/bs/13_ch00_BadStatus_000_<n> (fire) | Hellish Rebuke, swapped into the player's 13_chcm_pl_Ref data (gy2 = used) |
| pb_bc10-12_gy2 | enemy humans Common/BadStatus/13_Cm_BadStatus_100_<n> | Rebuke: data 13_chcm_em_pl_Ref |
| pb_bl10-14_gy2 | large monsters Common/BadStatus/13_Cm_BadStatus_101_<n> | Rebuke: data 13_chcm_em_L_<ch>_Ref |
| pb_torch_g120 / _gy | a torch flame | Rebuke flame in the left palm |
| pb_rebuke_h120 / h140 | Golem copy | unused (kept) |
| pb_hexx_b1-3 | a shimmer line, fluid simulator colours edited to pink, intensity 1.5 / 2.5 / 4 | Hex X (2 copies rolled +-45 deg, frozen at 0.8 s) |
| pb_acid_v3 | Chimera acid ch54_001_liquidshell_020_03, black cloud / decal layers hidden, green | Caustic Brew wave (copies from 1 m ahead) |
| texture/gradient/13_p285 / p300 / p315 / g120 / g140 _000_00_alb.tex | copies of a game gradient texture (same name length), recoloured | referenced by baked efx whose colour lives in a gradient |
Not in the pak (played from the game's own files on own EffectPlayers): the door / pillar frost shimmer
(wp00/009 enchant_25), the cs0220 door glow, Mage chant circle cs 0/304 (requested on our anchor).

## 6. Save / online guard
Hooks on SaveDataManager save / saveGameSaveData, ItemManager saveGameSaveData / saveGameSaveDataTarget /
fillStorageSaveData / makeLoopSaveData, OnlinePawnDataFormatter updatePlaydataFrom* / getEquipSnapshot* /
makeToUploadValidationWork, PawnServerController registerSupportPawn*: while they run the sword item data and the
guise chest item data are the originals (`dbg.guardHold` stops the sword re-apply). Nothing modded reaches saves/uploads.

## 7. Stamina
`dbg.stam_cost(a, what, cost)`: note at the press, 0.6 s later take / refund to the exact cost (the game's own drain
counted). A vanilla skill's own drain swapped before it lands in a StaminaManager.add pre-hook (dbg.stamSwap).

## 8. Release / test cycle
1. Patch src_integrated/Pactblade.lua -> lupa compile -> forward-reference check -> copy to the game autorun
   (test build = RELEASE false) -> user resets scripts (paks need a restart).
2. Release: RELEASE true, copy script + module + VSB pack + data/Pactblade.json (the tuned settings) + pak into
   release/Pactblade-1.0/Pactblade, zip (top folder Pactblade/), copy the zip into Fluffy's Mods folder.
3. GitHub: dist/repo (ntgoten/pactblade) - only when the user asks; `gh release create vX zip`.
- Fluffy reinstalls overwrite test files with the zip's content: keep the Fluffy zip current.

## 9. Open ideas / parked
Darkness (no hiding cloud found), Ghostly Gaze (see-through walls 30 ft; options: wireframe per mesh if available,
env mesh fade via material values, hidden meshes + drawn AABB outlines), Hunger of Hadar, Lightning Lure, Cloud of
Daggers, rest ending the guise, decoy remains.
