# How Pactblade was made - a guide for modders

Pactblade is a custom vocation for Dragon's Dogma 2: a sword in one hand, eldritch magick in the other, 8 new skills
and a handful of always-on abilities. This guide explains how it's put together and how each part was built - in detail, with the problems on the way -
so you can make something similar, or continue Pactblade. It assumes you know Lua basics and have used REFramework.

A denser, more technical version for AI assistants is `PACTBLADE_AI_GUIDE.md`. The code itself - every hook,
table, game call, with excerpts - is explained in `PACTBLADE_CODE_WALKTHROUGH.md`. The source is the script
`reframework/autorun/Pactblade.lua` (search it for the names used here).

---

## 1. The building blocks

| Piece | What it does for Pactblade |
|---|---|
| **REFramework** | Runs Lua scripts inside the game: you can hook (intercept) any game method, call game functions, read and change game objects. It also loads `pak_mods` (custom file packs). |
| **VocationAndSkillBuilder (VSB)** | Adds a custom vocation (name, icon, description, which vanilla vocation it's based on) and custom skill entries the game treats like real skills: they appear at the Vocation Guild, cost Discipline, unlock at a rank and go into skill slots. |
| **_DragonCore** | A helper library: the player as an easy object (`a:request_action`, `a:button_pressed`, `a:stamina()`...), spawning projectiles (shells), effects, summons. |
| **_ScriptCore** | Ray casts against the ground (where to land, where a door goes). |
| **A pak** | Our own effect and sound files (recoloured copies of game effects), loaded at game start. |

The big idea: **VSB makes the vocation and the skill entries; the Lua script does everything the skills actually do.**
The VSB skills themselves are empty shells. When you press one, the script recognises it and runs its own code.

---

## 2. How a skill press reaches the script

1. VSB gives each of our skills an ID (it keeps them in `reframework/data/VSB/state/idtable.json`, keyed by the skill's
   fixed uuid).
2. When you press a skill button, the game calls `PlayerInputProcessorDetail.processCustomSkill(...)` with that ID.
   Pactblade hooks this method.
3. An **adapter** translates our VSB ID into the Fighter skill ID the skill's code was originally written for (the
   first versions replaced Fighter skills directly) and marks the press as "ours". Every Pactblade skill only reacts to
   presses marked this way, so the real Fighter skills keep working normally.
4. The skill code then plays animations, spawns effects and deals damage itself, and tells the game to skip its own
   handling of the press (`SKIP_ORIGINAL`).

Two catches you'll meet too:
- **In the air** the game drops ground skills before step 2. Pactblade also hooks the button's own entry
  (`processCustomSkill(CharacterInput.Action, ...)`), which still fires mid-air - that's how the air versions work.
- The game asks "is this skill available?" (`HumanSkillAvailability.isCustomSkillAvailable`). For shield skills
  without a shield it says no, so the script answers yes for its own presses.

### The skill JSON (VSB)
```json
{ "schema_version": 1, "uuid": "...", "id": "pb_smite", "kind": "custom",
  "presentation": { "name": {"en": "Eldritch Smite"}, "desc": {"en": "..."}, "icon": 35 },
  "availability": { "mode": "all" },
  "levels": { "1": {"unlock_rank": 8, "dcp_cost": 3000}, "2": {"unlock_rank": 8, "dcp_cost": 100} },
  "trigger": { "type": "slot" },
  "timeline": [ { "id": "n1", "type": "script", "frame": 0, "fn": "return true" } ] }
```
Two levels per skill: with only one, the Vocation Guild crashed. The icon is a number into the game's own skill icon
sheets (VSB's editor shows them).

---

## 3. Making things happen

### Animations
- **Borrow any vanilla action:** `a:request_action("Job05_CrescentSlashNormal", 0)` plays a Warrior swing on a Fighter.
  Most actions of other vocations work if the character has their animations loaded.
- **Cut and speed them:** every frame, read the full-body layer's frame (`get_Frame`) and jump with
  `changeMotion(bank, motion, frame, blend, 1, 1)` (a crossfade looks much better than a hard `set_Frame`). Fire things
  at chosen frames (the beam fires at frame 57 of its animation).
- **Stop the game from interrupting:** hook `ActionManager.requestActionCore` and refuse the follow-ups / landings the
  game tries to start while your skill plays. Mark your own requests so you don't block yourself.
- **Animations from another vocation's file:** add the motion list as a dynamic motion bank (the Mage chant is
  `ch00_006_atk.motlist`, bank 9112), then force the motion every frame and pause the character's animation state
  machine (`MotionFsm2`) while it plays.
- To find which animation and frames you want, a small tool that plays clips frame by frame helps a lot.

### Effects
See section 4 - effects get their own section.

### Damage and reactions
- Our own hits: `HitManager.directDamage` with a new `DamageInfo` (damage, magick or not, the reaction type such as
  flinch / knock-down, and its power). Strong reactions on big monsters need a high power and "force received".
- Changing the game's hits: hook `calcDamageValue` (the number), `calcDamageReaction` (the stagger) and
  `getReactionDamageType` (the reaction).
- Statuses: `StatusConditionCtrl.reqStatusConditionApplyCore` (fire, poison, ...).
- Careful with kills: a huge knock-down power on the killing hit makes the body fly away and the loot with it.

### Teleports
Move the character's transform AND call its CharaController `warp`, in the game's update step, and hold the position
for a few frames (some animations push you). Find the ground with a ray cast first, so you never land inside terrain.

### Stamina
Note the stamina at the press, then shortly after take or give back the difference, so the skill costs exactly what
you want even when the borrowed animation drains its own amount.

---

## 4. Effects in depth: finding, recolouring, replacing

Almost everything purple in Pactblade is a game effect: Mystic Spearhand's bolts, Skydragon, Mirage Dance, a Golem's
hand flash, a Chimera's acid, the bad-status flames. Only the colours, sizes and some layers were changed. This section
explains how effects work in the engine and every technique used on them.

### 4.1 How effects work in RE Engine (DD2)
- An effect is an **`.efx` file** (in DD2: `*.efx.5965310`; the number is the file version). Inside are **layers**
  (named entries such as `Root`, `blur`, `inv`, `Light`, `sk0`), each with attributes: emitters, particle settings,
  colours (`RgbCommon`), meshes (`TypeMesh`), lights (`TypeNoDraw`), distortion, textures.
- A character doesn't play effect files directly. It has an **`ObjectEffectManager2`** component with **effect data
  sets** (prefabs such as `VFX/Effects/Character/ch07/13_ch07_ns_Ref.pfb` = Mystic Spearhand's set). The game asks for
  an effect by an **effect ID**: `DataContainerIndex / ContainerID / ElementID`, written `13/23/0` in this guide.
  - the **index** says which data set (13 = the Spearhand set on the player, 0 = the common ch00 set, -1 = the object's
    own set, e.g. a projectile's);
  - the **container** and **element** pick an entry in that set, which points to one or more `.efx` files.
- Projectiles (shells) have their own effect manager; their effects show up as `-1/8/40` (the Eldritch Bolt's launch
  flash), `-1/8/43` (its explosion), `-1/10/1` (Magike Cut's wave), and so on.
- Requests go through methods like `requestEffect`, `requestEffectInternal`, `requestEffectFromFsm` /
  `requestEffectFromFsmOrSequence` (effects started by an animation's timeline). Each returns a **created effect
  container**: the running effect, with its `EffectPlayer`s (`getAllPlayers`). You can `killAll` / `finishAll` it,
  scale it (`setUniformScale`), tint it (`set_Color` on its players), slow or freeze it (`set_PlaySpeed`).

### 4.2 Finding the effect you want
1. **Record it.** Pactblade's test menu has a Recorder: for a few seconds it logs every effect request of the player
   (the ID and the data set's path), every sound trigger and every animation change. Do the vanilla move while
   recording (e.g. as a Mystic Spearhand, or with that move borrowed), then read
   `reframework/data/Pactblade_chant_record.json`.
2. **Map the ID to its file.** Walk the character's effect data (the manager's own `StandardDataMap` and
   `ExpertProviderInfoList`, plus every `ExternalDataContainers` entry) and read each element's
   `getResources(i):get_ResourcePath()`. Pactblade's "dump my effect data" button writes all of them to
   `Pactblade_fx_data.json`, lines like
   `13 VFX/Effects/Character/ch07/13_ch07_ns_Ref.pfb | key 23 | element 0 | VFX/Effects/Character/ch07/ns/13_ch07_ns_023_00.efx`.
3. Shortcut for a running effect: on any `EffectPlayer`, `get_Resource():get_ResourcePath()` gives its file.
4. **Look before you edit:** an effect browser / a script that plays an `.efx` file in front of you (Pactblade had a
   preview for the acid candidates) saves a lot of guessing.

### 4.3 Extracting and inspecting
- Extract the file from the game's paks by its full path (`natives/stm/vfx/.../13_ch07_ns_023_00.efx.5965310`) with a
  REE-Lib based tool (`pakget`), or unpack whole paks with ree-pak-cli and a file list.
- Dump its layers: names, attribute types and raw bytes. Layer names tell a lot: `blur` / `dis` / `Liquid_distortion` =
  screen distortion, `inv*` = inverted colours, `Light` = a light source, `sk0` / `ky0` = smoke / fog.

### 4.4 Recolouring ("baking")
The recolour tool (`efxtint <in> <out> r g b`) changes the **hue** of every decoded colour field to the hue of the given
RGB, keeping each colour's own saturation and brightness, so the effect keeps its gradients and highlights:
- `RgbCommon` colours (two per attribute),
- the colour of `TypeMesh` layers (meshes in the effect: spirals, cones, magic circles),
- a light layer's colour (`TypeNoDraw`, the light that tints the surroundings),
- mesh material colour parameters identified by their hash (one of them held the Eldritch Bolt's teal shockwave).

Things learned:
- **Hue numbers:** purple 285 = rgb 191,0,255; pink-purple 300 = 255,0,255; pink 315 = 255,0,191. Pactblade bakes all
  three, because the colour can be picked in the menu.
- **Inverted layers** (names starting with `inv`) are drawn with inverted colours. Sometimes they need the
  **opposite** hue (285 + 180 = 105, a green, turns purple on screen): Skydragon's pieces did. Sometimes they don't
  (the bad-status flames turned purple when flipped). Bake both and compare in game.
- **Hot cores:** for fire, the bright cores were tinted toward a second hue by their brightness (green flames with
  yellow cores = the `gy` files of Hellish Rebuke).
- **Colours in textures:** some effects take their colour from a gradient texture (128x1 pixels). Copy the texture
  under a new name of the **same length** (`13_Heal_...` → `13_p285_...`), recolour it, and replace the texture path
  inside the `.efx` byte by byte (same length = nothing else shifts).
- **Brightness:** a separate pass multiplies colour intensities (the arm effect's 4 glow strengths, `g1`-`g4`).
- **Never guess colour bytes.** Writing "colour-looking" bytes into an efx crashed the game; only decoded fields.
- The output file needs the `.efx.5965310` extension, or the tool can't read it back for a second pass.

### 4.5 Hiding parts of an effect
- **A leaf layer:** set its transform scale to almost 0 (`efxhide`). Not on a parent layer: hiding the `Light` layer
  of the Golem flash hid the whole effect, because everything hangs under it.
- **Safer:** set the alpha bytes of its colours to 0, or a light's colour to black.
- **Never** set a layer's particle count to 0: "heap allocation failed" crash as soon as it emits.
- Used for: the Bolt explosion's lingering fog (`sk0` and friends), the screen distortion of the arm effect, the
  debris of the explosion, the Golem flash's blur and shock ring in the beam copies.

### 4.6 Names and packing
- Copies always get **new paths**: `vfx/effects/pactblade/pb_<what>_<variant>.efx`. Overriding a game path in a pak
  crashes the game at start, even with an identical file.
- Variant suffixes used: `_h285 / _h300 / _h315` (hue), `_e285` (the 4th iteration of the Bolt effects, with the mesh
  colours fixed), `_g120` (green), `_gy` / `_gy2` (green with yellow cores, 2nd version), `g1`-`g4` (glow strength),
  `_b1`-`_b3` (brightness), `_v3` (version).
- Examples: `pb_40_e285` / `pb_43_e285` = the Bolt's launch flash / explosion (shell container 8, elements 40 / 43);
  `pb_10_1_h285` = Magike Cut's wave (container 10, element 1); `pb_sd10_h285` = Skydragon piece 14/7/10;
  `pb_ai00_h285` = Mirage Dance's aura; `pb_bs10_gy2` = the player's burning flames; `pb_hexx_b2` = the Hex X;
  `pb_beamrowf_h285` = one beam segment; `pb_acid_v3` = the acid wave; `pb_arm_h285g2` = the arm effect.
- All files go into one folder tree (`natives/stm/vfx/...`), packed into one `.pak` in `pak_mods`. Paks load only at
  game start; a running game locks them (add a higher-numbered pak, merge later).

### 4.7 Using the copies in the script (five ways)
1. **Play it on our own object.** Create a GameObject, add a `via.effect.EffectPlayer` component, give it the file
   (`sdk.create_resource("via.effect.EffectResource", path)` → `create_holder` → `set_Resource`), `AutoStart`.
   One player per GameObject. Move / rotate / scale the object every frame to follow a joint (the left palm for the
   beam, the arm for the arm effect) or stay in the world (the acid, the Hex X). Destroy the object to end it.
2. **Replace a game effect when it's requested.** Hook the request methods; in the post-hook, if the ID is one we have
   a copy for, `killAll` the game's container and play our copy at its creator's position (and follow it, for the
   Slash wave). Pactblade's "parts" table lists these IDs with a mode: `ours` (replace), `hidden` (kill), `whole`
   (tint the game's). Misty Dive does the same for Skydragon's pieces (its `md.FX` list).
3. **Swap the file inside the character's effect data**, when the effect must stay on the body's bones (a body effect
   needs the body binding). Find the element (4.2), `setResources(i, our holder)`, and put the original back later.
   This is how Hellish Rebuke's green flames work: before the burn starts, the burning character's own fire files are
   swapped for ours (each character kind has its own data set and files), and swapped back when the burn is over.
4. **Tint at runtime.** `set_Color` on the players of a container (the projectile's effects, the charge cloud). Quick,
   but it **multiplies**: orange x purple = dark red, and on see-through / distortion layers it paints the background
   and covers the screen ("the veil"). Effects that do this go on a "never tint" list and get baked copies instead.
   Never tint every frame without checking the container is still alive (it crashed).
5. **Shape it.** `setUniformScale` (Eldritch Bolt's explosions at 0.31, the launch flash at 30 %), the projectile's
   effect scale in its shell data, hold at scale 0 for 0.1 s (the explosion's first frames hidden), `set_PlaySpeed(0)`
   at a chosen moment to **freeze** it (the beam segments, the Hex X), or kill a container (the dust of the combo).

### 4.8 Sounds, briefly
- Game sounds play through a character's sound container by trigger ID (found with the Recorder).
- Own audio: a script clones a small game sound bank and puts your own PCM audio in it under new IDs (Smite's charge
  and hit, Hellish Rebuke), packed with the effects. Our sounds always play **on top** of the game's, never instead.

---

## 5. Every skill and feature, in detail

For each one: the idea, what it borrows from the game, what happens step by step, how its look was made, the problems
on the way and how they were solved. Times and frames are the tuned values.

### 5.1 The base: passives, the sword, the shield
- **Active when:** VSB has Pactblade picked for Fighter and the character holds a Fighter weapon (a sword).
- **Magick damage x1.5:** a post-hook on `HitController.calcDamageValue` sees every hit; for the player's hits the
  damage is recomputed as `Damage x (physical + 1.5 x magick) / (physical + magick)`.
- **The sword carries magick:** the held sword's item data gets `Magick = Strength` and the element Thunder at full
  strength, then the equipment totals are recalculated, so the status screen shows it. **Upgraded swords carry their
  own copy of the item data** - that copy has to be changed too (only changing the item's template did nothing for
  them; found in 1.0.2). When Pactblade isn't active, the originals come back.
- **Faster attacks:** while an Onslaught swing plays, the character's animation speed is 1.5; other Fighter attacks 1.2.
- **Core skills:** the game asks "is this core skill enabled?" for each one; Pactblade answers yes for Thief's
  Controlled Fall and Footpad (and the Spearhand's Quik Fot, used by Misty Step), no for the shield core skills.
  Footpad also needed its input handler called every frame.
- **No shield:** equipping a shield into the sub slot is refused, and the shield actions are refused when requested.
- **No boons:** the elemental boon statuses are refused for the player (the sword's Thunder replaces them).
- **Save and online safety:** hooks on the save functions and the online pawn / owner data builders put the sword
  (and the Guise chest piece) back to their originals while those run. A watchdog lets go after 5 s if a save's end
  never comes (otherwise the sword stayed plain).

### 5.2 Vocation button: Swift Step, Eldritch Bolt, Eldritch Burst
- **Idea:** the Fighter's Defend button becomes the warlock's signature spell.
- **Tap (< 0.5 s):** Thief's dodge `Job04_Dodge`, with the same "can I dodge now" check the game uses.
- **Hold:** after 0.5 s a short full-body glow says "charged"; on release the character plays Mystic Spearhand's
  charged Forbeding Bolt animation (`Job07_MagicBindComplete`) and Pactblade spawns its own projectile at the left palm
  (the Spearhand's shell 12, Magike Sperepelote's projectile) through DragonCore. Damage = the projectile's magick x the
  attack rate x 0.4255 (calibrated against Magick Bolt), then the x1.5 passive.
- **The bind:** the animation also fires the Spearhand's own binding bolt. All other projectiles of these animations
  are blocked (`ShellManager.requestCreateShell` pre-hook), but this one is **let through** and kept on our projectile's
  path every frame (it missed on its own aim): when it hits, the game opens its "bind" window - which is what Misty Step
  and Hex use.
- **Eldritch Burst:** pressing the button during or right after a sword attack (Onslaught 0.8 s, ground Empale between
  frames 56.6 and 110.5, air Empale 0.8 s, Tusk Toss frames 50-91) gives a point-blank version: the charged animation,
  a hidden hit area 2.5 m / 150 degrees in front, only a flinch (heavier reactions are turned into a flinch), and it
  binds too. An attack press during its recovery cuts the recovery.
- **Aim:** the target is the enemy nearest to where the stick (or the camera) points; the character turns to it, and
  the bolt flies no further than that.
- **Look:** the launch flash and the explosion are baked purple copies; the explosion's lingering fog layers were
  hidden; the explosion is shrunk to 31 %, the launch flash to 30 % (Burst 50 %). The Spearhand's charge cloud on the
  ground is tinted at runtime.
- **Problems:** the game kept the Spearhand's teal charge cloud running (found with a cloud recorder, now tinted /
  ended); tinting the explosion's distortion layers painted a "veil" over the screen (fixed with baked copies);
  water splashes turned purple because every player effect was tinted for 2 s (now only the Spearhand's own effect
  set and the charge cloud).

### 5.3 Misty Step and Hex (after a bind)
- The bind window = the game's `IsJustMagicBindEnable`; the bound enemy = `get_MagicBindShellHitOwner`.
- **Misty Step (Jump):** the game's own Quik Fot leap didn't start for a Fighter, so Pactblade requests the leap action
  itself (`Job07_MagicBindJustLeap`) and moves the character to the enemy. After a Burst bind it's a warp to the
  enemy's far side instead. The bind on the enemy is released after the leap.
- **Hex (Interact):** 15 s on the bound enemy: every hit on it x 1/0.9 (= -10 % defence, once per hit, not stacking),
  10 % max stamina, and if it dies while hexed you get 15 % of your max HP back.
  - The X marker = 2 copies of a shimmer line (made pink: its fluid-simulation colours edited), rolled +-45 degrees,
    above the head, frozen at 0.8 s of its life, scaled with the creature's height (tiny on a Cyclops before that).
    Debug dots (coloured points drawn at computed positions) found where each line really starts.
- **Priority:** while the Hex window is open, Interact belongs to Hex (Hellish Rebuke uses Interact too).

### 5.4 Hellish Rebuke (Interact after being hit)
- **Idea:** D&D's reaction spell: hit back with fire right after taking a hit.
- **Window:** a damage hook on the player opens a 0.5 s window when an enemy's real hit lands with no reaction or only
  a flinch (status damage ticks don't count).
- **Cast:** 30 % of max stamina, once per 6 s (a game clock that stops in menus). The character faces the attacker and
  plays the Mage's cast-release clip (bank 9112, motion 750, from the Mage's motion file loaded as a dynamic bank), super
  armour while it plays, a charge flash borrowed from Tusk Toss (a body material mode + an effect + a sound).
- **On the attacker:** a direct hit that forces a flinch even through attack armour (power 10000), then the game's
  fire status (`FireSpread`).
- **Green fire:** the hardest part was the flames. Tinting the game's flame players washed them out; playing our copy on
  our own object showed nothing (a body effect needs the body). What worked: **before** the burn starts, swap the fire
  files in that character's own effect data for green-yellow copies (`pb_bs`, `pb_bc`, `pb_bl` for the player, enemy
  humans and large monsters - each kind has its own data set and file names), and swap them back when the burn is
  over. The scorch marks are a body material (`Heat_*` colours), recoloured every frame. Plus a green torch flame in
  the palm, a green explosion and an own sound.

### 5.5 Eldritch Slash
- **Idea:** a sword swing that sends an eldritch wave.
- **Animation:** the Warrior's Crescent Slash (`Job05_CrescentSlashNormal`), frames 0-97, with super armour, sped up
  1.2x toward its end.
- **The wave:** at frame 64 Pactblade spawns Mystic Spearhand's Magike Cut wave (shell 6) from the right palm, 2x
  taller. Its range is set where the game updates it (`ShellAdditionalJob07SubNormalAttackShell.update`, the
  `DefaultRangeDist` value); the wave is ended with `set_RequestKill` when it has travelled its range or stopped.
- **Damage:** the wave x3, the sword hit x2 (the passive comes on top for the wave, which is pure magick). The wave's
  damage comes from **sub-projectiles** the wave spawns itself - recognising only the projectile we spawned made the
  multiplier never apply (fixed in 1.0.2: every player projectile hit within 4 s of the slash counts).
- **Look:** three parts of the wave are replaced by baked copies (`pb_10_1/3/6`), the main one follows the wave.
- **Turning:** before the wave fires, the character turns toward the nearest enemy in front.
- **Problem:** walking and re-tinting the projectile's effect list every frame crashed the game (it lives on other
  threads) - colouring now runs 5x a second, once per container.

### 5.6 Tasha's Caustic Brew
- **Idea:** a chant, then a torrent of acid washing over the enemies in front.
- **Chant:** the Mage's spell-casting set from the Mage's motion file (`ch00_006_atk.motlist`, loaded as dynamic bank
  9112: 710 start, 712 chant loop, 750 release). The character's animation state machine (`MotionFsm2`) is paused so
  it can't switch away; the motion is forced every frame. The Mage's chant circle is placed upright 0.7 m in front (on a
  staff it hangs there; without one it lay on the ground). The chant's sounds come from the motion's own events.
- **Interruption:** a damage reaction requested for the player during the chant (flinch, knock-down, grab...) cancels
  it, like a vanilla spell. Hits that your knock-down resistance absorbs don't.
- **Acid:** after 3 s the wave `pb_acid_v3` (a Chimera's acid projectile effect, its black smoke removed and
  recoloured green) is laid in copies from 1 m in front. Every 0.3 s the script checks which enemies stand in the strip
  (2.5 m wide, up to 15 m), deals 72 damage and adds 35 to its own poison meter per enemy - at 100 the game's Poison is
  applied. The acid lasts 5 s. Splash sounds come from a monster's sound bank (a random set of splashes).
- **Stamina:** 150, taken when the acid pours (during a chant the game ignores stamina changes, so it's set directly).
- **History:** first a vase (a game prop) was supposed to fall and break - spawning, physics and breaking were too
  fragile, so it was dropped; then a hidden Salamander projectile carried the damage; the final version is the
  script's own strip check (simplest and reliable).

### 5.7 Misty Strike
- **Idea:** step through the mist behind an enemy and strike (Pactblade's first idea, from the author's Blink Behind
  mod).
- **Flow:** Skydragon's crouch (`Job07_SkyDive`, held on the ground for 0.25 s so the character doesn't lift off) → warp
  to the far side of the target (its radius + 1.2 m), ground height found with a ray (stairs, slopes) → the last hit of
  Riotous Fury (`Job01_BravesRaid`, motion 110/1701) crossfaded in at frame 106.
- **Recovery:** after the hit (from frame 150) the animation is moved on faster by the script (x1.7; the layer's own
  speed setting was ignored by the game), and from frame 170 any attack, skill, jump, vocation or dash press ends it -
  with an 8-frame crossfade into the end pose (a hard jump looked like a "reset"). At the latest it ends at frame 235.
- **From a jump:** a 0.2 s hold in the air with Skydragon's launch effects, then the warp.
- **Look:** the same warp effects as the Archfey Combo (wisps, afterimage, purple Skydragon pieces).
- 15 m range, 110 stamina; the game's landing / fall actions are refused while it plays.

### 5.8 Misty Dive
- **Idea:** vanish and plunge onto an enemy from above.
- **Flow:** Skydragon's preparing jump → warp 1.8 m above the enemy → the air Empale (`Job01_HeavyAttackAir`). The descent
  is the script's own: every frame x/z follow the enemy (it may move), the height only ever goes down, at 7 m/s. At its
  head it's held up to 0.25 s so the blade can hit; if it didn't, a direct hit (1500, a strong flinch) is dealt.
- **Landing:** on a human-sized enemy, the character is put on the ground just outside its body. On a **big monster**
  (body radius 1 m or more) it's let go and falls onto the monster's body, like Skydragon (1.0.1).
- **Look:** Skydragon's teal pieces on the character are replaced by purple copies when the game requests them, and
  its body glow (a rim light material) is painted purple.
- Works from the air; refused on ropes, while climbing or downed; super armour during the dive.

### 5.9 Eldritch Blast (the beam)
- **Idea:** a crackling beam from the off hand (like Baldur's Gate 3's Eldritch Blast).
- **Animation:** on the ground the opening of Riotous Fury (`Job01_BravesRaidStart`): it's a shield push, and without a
  shield it reads as thrusting the hand forward. The beam fires at frame 57; the game's follow-up into the rest of
  Riotous Fury is refused. In the air: the Spearhand's charged bolt animation, beam after 0.3 s.
- **The beam:** a real stretched beam mesh (the Golem's laser) didn't render on our object, and a projectile chain
  looked wrong. What worked: a **row of copies of a flash effect** (the Golem's hand flash, recoloured, its blur and
  shock-ring layers made invisible) laid from the palm to the target as the beam grows (0.1 s), each **frozen** at
  0.1 s of its own life, held 0.45 s, then thinned out. The first 1.5 m (the launch cloud) disappear early.
- **Hit:** the Bolt's purple starburst + explosion copies turned along the beam, and a direct hit: the raw magick of the
  last bolt x3.5, a medium flinch.
- **Effects of the animation:** on the ground they're killed (a pink whirlwind came from them); in the air they stay,
  except one big swirl (13/20/56), and the charge cloud is tinted.
- **Stamina:** 200 - Riotous Fury's own 480 is swapped out before it lands (a pre-hook on the stamina manager's `add`).

### 5.10 Archfey Combo
- **Idea:** a fey-born flurry - vanish and strike from every side.
- **Chain:** the Archer's Kite Arrow kick (`Job02_StartFlightShot`, frames 0-71.6) → warp to a side of the target →
  Rush Attack (frames 34-67) → warp behind → Rush Attack's finisher (25-54) → warp above the head → the end of Cloudfall
  Strike (`Job01_EndRisingLunge`) → the game's landing. The target is the first enemy the opening hits; the opening turns
  toward the nearest enemy (360 deg/s, 12 m, 70 degrees).
- **Dynamic warps:** the spots lie on a cross around the enemy (its own front / back / left / right). The first warp
  goes to the side opposite you, the next ones to unused sides, with the next free side if a spot is blocked.
- **Warp look:** each warp leaves:
  - wisps at the feet and hips (weapon enchant element 30 - only a weapon's own effect manager can play them, so a
    hidden Stalwart Sword is spawned once from the game's weapon catalog as the "donor");
  - the Spearhand's afterimage clone at the departure spot: the game's own Mirage Dance clone (`AfterImageHandler`),
    started where you were, pinned there, posed like you at that moment (a copy of every joint), purple, gone after
    0.3 s. If the game hasn't made that clone yet, it's asked to (`create`) - never a clone handler of our own (crash);
  - Blink Behind's warp sounds.
- **Problems:** Kite Arrow's own follow-up (a kick-off jump) is refused so the opening plays to its end; the Rush
  parts' dust made a see-through veil over the screen and is killed; a warp sound looped forever ("static") and was
  removed from the cues.

### 5.11 Eldritch Smite
- **Idea:** a crushing two-part overhead blow, powered by the patron.
- **Animation:** the Warrior's short heavy swing (`Job05_ShortRangeHeavyAttack`, 0-66.6) crossfaded (12 frames) into the
  end of Arc of Obliteration (`Job05_ArcOfObliterationEnd`, from 50), sped up 1.5x from frame 150 to 347.
- **Part 2:** the Nox blade glow x2.5 and a second shimmer on the sword; the first sword hit gets the Bolt's purple
  explosion copy (x2.5) at the victim and a guaranteed knock-down (power x150).
- **Kills:** a huge knock-down power on the **killing** blow made the body fly away (loot lost). On a kill there's no
  forced knock-down, and for 2 s the death ragdoll's launch velocity is limited.
- **Sounds:** own audio (charge and hit), built into an own sound bank.
- **Stamina:** half of Arc of Obliteration's drain (the drain is caught in a stamina hook and halved), 20 % of max
  back on a hit. Uses a spell slot (5.15).

### 5.12 Tasha's Otherworldly Guise
- **Idea:** a spectral armour from beyond: defence, resistances, levitation. Visually: a ghostly copy of a different
  armour (Grand Cuirass + Raptor Claws by default) over your own, a bit bigger, see-through.
- **Cast:** the Caustic Brew chant; a spell slot (5.15) and 25 % stamina when the spell takes effect; 60 s (a game
  clock that stops in menus); a recast renews it.
- **The ghost = a clone:**
  - Our own clone handler crashed the game. The Spearhand's afterimage is shared with the warps. The **Trickster's decoy**
    (`DecoyHandler`, the game's own) works: created once if missing, started, then kept alive every frame (its timer and
    death flags reset).
  - **Dressed** through its own part swapper (`_Meta._TopsStyle` / `_PantsStyle` + `requestSwap`) - the game builds the
    armour like transmog. Every other mesh of the clone is switched off. (Hand-made mesh swaps never loaded and
    crashed; a body mesh on the head part crashed instantly.)
  - **On you:** every frame its position, rotation and scale (1.10 / 1.04 / 1.06) and every joint's local position and
    rotation are copied from yours; its own animation is off; its hip is pulled onto yours.
  - **See-through:** material values written every frame: `Illusion_Enable 1`, `Illusion_AlphaRate_Front 0.25`,
    `Illusion_FadeRate 0.30` (chest) / `0.38` (legs), rim alpha 0.8; a purple rim light; Mirage Dance's aura as a pink
    cloud (70 % speed, weaker).
  - **Its own behaviour off:** the decoy normally lures enemies (cleared every second), reacts when its owner is hit or
    grabbed (blocked - it lost the look on a pawn catch), and ends itself (blocked while ours). Its health bar is hidden.
    Its start effect is kept (it looks good).
  - **Sounds:** its start sounds are recorded the first time and replayed on reuse; they're stopped at the end.
- **Bonuses:**
  - +20 % Defense / Magick Defense: written into the worn chest piece's item data (with the originals kept on disk),
    then the equipment totals recalculated - that's the only way they show on the status screen. (`calc()` alone added
    everything twice: clear first.)
  - Fire and poison: the item values only showed on the screen. Real protection: while the Guise is on, the active
    statuses are checked every frame and Caught Fire, Torched, Blighted and Fulminant Poison are cured at once (they
    reach the character through more than one path); fire-element hits on you do half damage.
- **Levitate:** hold Jump in the air. The Sorcerer's levitate isn't in a Fighter's action set, so it's the script's own:
  every frame the height rises (up to 2.5 m above the jump's first float), x/z follow the stick, and the game's fall
  state is reset (otherwise a sudden fast drop after). The Mage's levitation animations (start, keep) are forced on the
  body. Let go and hold again to float once more in the same jump.
- **Known:** resting doesn't end it; a faint gold remnant of the decoy can stay where it ended.

### 5.13 Nox sword look and the arm effect
- **Nox (from the author's Stalwart Nox mod):** a purple mist = the Frost Boon shimmer effect played through the held
  sword's own effect manager and tinted; the blade glow = two colour values and one float written straight into the
  sword's material every frame. Material **modes** on weapons crashed at weapon switches, so they're never used there.
  The sword's own element glows are blocked. Everything stops cleanly before a weapon switch.
- **Arm effect:** the Spearhand's charge glow on the left forearm, a baked purple copy without its distortion layer, on
  our own object kept on the arm joint; a stronger variant while charging the Bolt.

### 5.14 Dimension Door
- From the author's standalone Dimension Door mod, built in as a module: hold the vocation button + Go! (d-pad up) or
  press B. A ray from the eyes along the camera finds the spot (up to 500 ft); a pillar of frost light marks it
  (copies of the door's frost shimmer stacked into a column, no light - an earlier light cost performance); the camera
  moves over the shoulder while aiming. Press again: a door of frost shimmer opens next to you; walk through it and the
  camera flies to the destination, where a second door opens and you step out. Holding the vocation button + d-pad up
  cancels a charging Eldritch Bolt.

---

### 5.15 Spell slots
- **Idea:** like a warlock's pact magic, the two strongest skills (Smite and Guise) need a spell slot: 1 at level 1, +1
  every 15 levels, at most 5; a used slot comes back after 20 s, one after another.
- **The rule:** the level is read from the character's status (`Human.<StatusContext>.get_Level()`), slots =
  `min(5, 1 + floor(level / 15))`. A slot is used when Smite starts, and when the Guise takes effect (after its chant,
  so an interrupted chant costs none; a renewal too). The recharge runs on the game clock that stops in menus.
- **Greyed out like the game does it:** the game asks `HumanSkillAvailability.isCustomSkillAvailable(id)` for each skill
  in the palette; with no slot free, Pactblade answers "no" for the two skills' VSB ids - the game then shows them
  greyed out and doesn't let them be used, exactly as with too little stamina.
- **The HUD:** drawn by the script every frame with REFramework's `draw` functions (circles and 1-pixel strips), no
  images:
  - each slot = a dark shadow, a bevelled bronze rim (dark / light / dark circles), a dark see-through core and a violet
    gem in three shades with a small shine - styled after the game's round icon frames;
  - ready: a halo that breathes and a light that runs round the rim with a short tail;
  - used: the gem swells and fades away (0.6 s); recharging: the gem grows back like the **moon's phases** (the lit
    part of a disk with an elliptic terminator, drawn as thin horizontal strips); refilled: a bloom of light for 1 s;
  - a press with no slot free: the row flashes red;
  - hidden in menus; position (3 spots), size and on/off are the player's, saved to `Pactblade_slots.json`.

---

## 6. Things that will crash or break, and the rules they taught
- Never overwrite a game file path in a pak. Only new paths.
- Never create your own clone handler; use the game's existing ones (Spearhand afterimage, Trickster decoy).
- Don't put material modes on weapons; a weapon switch then crashes the game. Write the material values directly.
- Don't rewrite a projectile's effect list every frame (it runs on other threads).
- Effects with zero particles crash ("heap allocation failed"); hide layers by alpha instead.
- Lua allows 200 local variables per chunk; a big script hits that. Wrap new sections in their own function.
- A variable used above the line where it's defined is nil at run time. The syntax check won't catch it, and in
  REFramework one erroring callback can stop the others on the same game event.
- Status screen numbers can't be changed by hooking the screen; change the item data the screen reads.
- Keep modded values out of saves and online pawn data: restore them while the game saves or uploads.

---

## 7. Tools used
- **REFramework** (its console / log `re2_framework_log.txt` for errors).
- **ree-pak-cli** - unpack and pack `.pak` files (needs a file list to show names).
- **REE-Lib**-based small command line tool - extract files from the game's paks, read `.efx` layers, recolour them.
- **Wwise bank builder** (a script that clones a small game sound bank and puts your own PCM audio in it) and
  **vgmstream** to listen to game sounds.
- **Fluffy Mod Manager** - install and package (`modinfo.ini` + the folder layout).
- **AnimPlayer** - a small REFramework dev tool made for this project: record the animations a skill plays, step
  through a clip frame by frame, mark the part you want (A-B) and loop it. That's how frames like "Riotous Fury from
  106" or "Kite Arrow 0-71.6" were picked.
- **Debug helpers in the test build:** the Recorder (effects / sounds / animations), an effect data dump, debug dots
  (coloured points drawn at computed positions), a hit log (every hit's damage before / after), test-dummy and
  fighting-enemy spawners.
- An **il2cpp dump** of the game (all types, methods, fields, enums) to find what to hook.

## 8. Credits
Built by ntgoten with AI assistance (Claude Code). Thanks to praydog (REFramework), Bloodragon (_DragonCore, VSB),
SilverEzredes and alphaZomega (_ScriptCore), Nickesponja (UDD2P / NickCore), and the REE-Lib / ree-pak / vgmstream
authors. Dragon's Dogma 2 and its assets belong to Capcom.
