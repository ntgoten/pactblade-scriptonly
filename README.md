# Pactblade

A custom vocation for Dragon's Dogma 2: a pact-bound swordsman with a fast, magick-charged blade in one hand and
eldritch magick in the other. No shield. Inspired by the D&D 5e warlock (names only).

Pactblade is built on **Vocation & Skill Builder (VSB)** as a Fighter vocation and runs as a REFramework script.
Play it as Fighter, or as Warfarer with a sword. Version **1.3.1**.

**This repository is the script-only edition:** only my own files - the Lua script, its Dimension Door module, the
VSB pack (the vocation and skill definitions), the default settings and the guides. It carries **no game files and
nothing made from them**: the recoloured effects and the sound bank are not here. Without them Pactblade plays, but its
effects show in the game's own colours and its own sounds are silent. The full package (with the effect / sound pak) is
on Nexus Mods: **https://www.nexusmods.com/dragonsdogma2/mods/2164**

## Requirements

| What | Version | Why |
|---|---|---|
| Dragon's Dogma 2 (PC, Steam) | post-DLC update | Tested on the current build. |
| [REFramework](https://github.com/praydog/REFramework) | current | Runs the script and loads the effect pak. |
| [_DragonCore](https://www.nexusmods.com/dragonsdogma2/mods/1916) | 1.2.0 or newer (tested 1.2.5) | Pactblade's library. |
| [VocationAndSkillBuilder (VSB)](https://www.nexusmods.com/dragonsdogma2/mods/1917) | 1.4.0 or newer | The vocation and its 8 skills. |
| [_ScriptCore](https://www.nexusmods.com/dragonsdogma2/mods/30) | current | Ground checks (Dimension Door, Misty Strike landings). |

Recommended: [Fluffy Mod Manager](https://www.fluffyquack.com/) to install.

## Install

1. Install the requirements.
2. Copy the `reframework` folder of this repository into the game folder, next to `DD2.exe`, merging folders.
3. Start the game. In the REFramework menu (Insert): **VocationAndSkillBuilder → Vocations → Fighter: pick Pactblade**.
4. Be a Fighter (or a Warfarer with a sword in hand). The skills are at the Vocation Guild.

Back up your saves before trying any new mod.

## What is in here

| Path | What |
|---|---|
| `reframework/autorun/Pactblade.lua` | the vocation's script (release build) |
| `reframework/autorun/Pactblade/DimensionDoor.lua` | the Dimension Door module |
| `reframework/data/VSB/packs/pactblade/` | the VSB pack: the vocation and its 8 skills (my own JSON - VSB itself is a requirement) |
| `reframework/data/Pactblade.json` | default settings |
| `Pactblade_docs/` | guides for players, modders and AI agents |

## Stats and passives

- **Magick damage x1.5:** the magick part of all your hits is multiplied by 1.5 (the physical part is unchanged).
- **The sword carries magick:** with a sword in hand, its Magick equals its Strength (shown on the status screen),
  and it carries full-strength **Thunder**. Back to normal when Pactblade isn't active.
- **Fast blade:** Onslaught 1.5x faster, every other attack 1.2x.
- **Core skills:** Thief's **Controlled Fall** and **Footpad** are on. Fighter's shield core skills are off.
- **No shield:** a shield can't be equipped while Pactblade is active; the shield actions are off.
- **No boons:** elemental boons (Fire / Ice / Thunder Boon) can't be put on you; the sword's Thunder replaces them.
- **Stat growth:** Fighter's.

## Always available (no skill slot)

| Ability | Input | What it does |
|---|---|---|
| Swift Step | tap the **vocation button** | Thief's dodge roll. |
| **Eldritch Bolt** | **hold** the vocation button, release | A charged magick bolt. **Binds** the target it hits. |
| **Eldritch Burst** | vocation button **during / right after a sword attack** | A point-blank blast. **Binds** the target. |
| **Hex** | **Interact** while a target is bound | Hex for 15 s: -10 % defence; if it dies hexed, you get 15 % of your max HP back. |
| **Misty Step** | **Jump** while a target is bound | Leap to it (after a Bolt) or warp to its far side (after a Burst). |
| **Hellish Rebuke** | **Interact** right after an enemy hits you | The attacker flinches and catches green fire. 30 % of your max stamina, once every 6 s. |
| **Dimension Door** | hold the vocation button + **d-pad up** (keyboard: **B**) | Aim (a pillar of frost light marks the spot, up to 500 ft), press again to open a door, walk through it. Press once more to close it. |

## Skills

Learned at the Vocation Guild with Discipline (DCP), equipped like any weapon skill.

| Skill | Rank | DCP | What it does |
|---|---|---|---|
| Eldritch Slash | 1 | 300 | A sweeping arc of eldritch force that cleaves foes from afar (sword hit x2, the wave x3 damage). |
| Tasha's Caustic Brew | 1 | 300 | A chant, then a torrent of acid that washes over the foes before you and poisons them. |
| Misty Strike | 2 | 500 | Step through the mist behind a foe and strike before they can turn. Works from a jump. |
| Misty Dive | 3 | 800 | Vanish into mist above a foe and plunge down on it with the Air Empale, following it as it moves. Works from the air. |
| Eldritch Blast | 5 | 1500 | A searing beam of eldritch energy from your off hand. Works from the air. |
| Archfey Combo | 7 | 2500 | A fey-born flurry: vanish and strike from every side in quick succession. |
| Eldritch Smite | 8 | 3000 | A crushing two-part overhead blow that knocks even great foes to the ground. Uses a **spell slot**. |
| Tasha's Otherworldly Guise | 9 | 4000 | A spectral armour from beyond for 60 s (see below). Uses a **spell slot** and a quarter of your stamina. |

Each skill has a second level for 100 DCP at the same rank (it's there for the game's skill menus; it doesn't change
the skill). A hit strong enough to make you flinch or fall interrupts a chant (Caustic Brew, Guise).

## EX skills

Four skills get an **EX version** when your sword carries the matching **special skill** (from appraisal) and the
skill is learned at **level 2** - the game's own EX rule. The sword's special skill then shows the EX name in the item
screens, and the skill's name gets "EX".

| EX skill | Sword special skill | What it adds |
|---|---|---|
| Archfey Combo EX | Cloudfall Strike | After the opening teleports: a kick and backflip, a sliding cut past the enemy, then the falling strike. |
| Eldritch Slash EX | Plenilune Slash | A vertical cut with its wave; the swing slows down for a moment - press again for a second, horizontal cut with a flat wave and a sword twirl. No second press: back to idle. Real sword hits. |
| Tasha's Caustic Brew EX | Tornadic Strike | Moments after the acid lands, the whole stream bursts into flame from end to end and sets foes on fire. Uses a **spell slot** (no slot free: the acid only). |
| Misty Strike EX | Eviscerating Skewer | When the strike hits, press the skill again to vanish: foes lose track of you and you turn see-through with a faint glowing outline, until your next attack (or 10 s). Drains a little stamina while hidden. |

## Spell slots

Like a warlock's pact magic: **Eldritch Smite** and **Tasha's Otherworldly Guise** each use a spell slot.
- You have **1 slot at level 1**, one more every 15 levels (15, 30, 45, 60), **at most 5**.
- A used slot comes back after **20 s**; several come back one after another. Menus don't count.
- With no slot free, the two skills are greyed out and can't be used. The Guise uses its slot when the spell takes
  effect, so an interrupted chant costs none. Renewing an active Guise uses one too.
- **On the HUD:** a row of circles under the stamina bar - a violet gem when the slot is ready, empty when used, and it
  grows back like the phases of the moon while recharging. The position (3 choices), size and on/off are in the menu.
  It hides with the game's own HUD (menus, cutscenes, conversations, camp and loading fades).

**Tasha's Otherworldly Guise** (60 s, paused in menus):
- +20 % Defense and Magick Defense (on the status screen)
- **Immune** to Caught Fire, Torched, Blighted and Fulminant Poison; fire damage halved
- **Levitate:** hold Jump in the air, steer with the stick; let go and hold again to float once more in the same jump
  (no Eldritch Bolt while levitating)
- A ghostly armour over your own

## Combos

```
Sword attack (Onslaught / Empale / Tusk Toss)
 └─ vocation button right after → ELDRITCH BURST ── target bound ─┬─ Interact → HEX
                                                                  └─ Jump     → MISTY STEP: warp to its far side
Hold the vocation button
 ├─ release when charged → ELDRITCH BOLT ── target bound ─┬─ Interact → HEX
 │                                                        └─ Jump     → MISTY STEP: leap to it
 └─ + d-pad up → DIMENSION DOOR (the Bolt is cancelled)
Get hit (a flinch or no reaction)
 └─ Interact right after → HELLISH REBUKE   (while a target is bound, Interact goes to Hex instead)
Eldritch Burst
 └─ an attack during its recovery → straight into the attack
Misty Strike
 └─ after its hit: attack / skill / jump / vocation button / dash → straight on (no recovery)
Jump
 ├─ Eldritch Blast / Misty Dive / Misty Strike → their air versions
 └─ with Otherworldly Guise on: hold Jump → LEVITATE
```

## Changelog

**1.3.1**
- New: **Misty Strike EX** (sword special skill Eviscerating Skewer + Misty Strike at level 2): when the strike hits,
  press the skill again within 1.5 s to vanish - foes lose track of you until your next attack.

**1.3**
- New: **EX skills** - Archfey Combo EX, Eldritch Slash EX and Tasha's Caustic Brew EX (see "EX skills").
- Misty Dive: after the teleport you strike with the Fighter's Air Empale (its own hover and plunge), follow a
  moving enemy while you fall, and the height adapts (a foe lying on the ground, or when you stand on a big monster).
- Caustic Brew: the acid hits a big monster whenever its body is in the acid, not only its middle - big foes get
  hit and poisoned far more reliably.
- Fixed: a crash with big monsters - Pactblade's health-bar notification could crash the game after a big monster died
  and the next one was hit. The grey "damage taken" segment now shows on normal enemies' health bars only (a boss's
  bar at the top just drops).
- Fixed: Eldritch Slash, Archfey Combo and Controlled Fall restored stamina instead of costing it.
- The Pactblade menu remembers which of its sections were open after a script reset.

**1.2**
- All of Pactblade's own hits (Eldritch Blast, Caustic Brew, Hellish Rebuke, Misty Dive's strike) now register on the
  enemy's health bar like normal hits, with the grey "damage taken" segment.
- Misty Dive now uses the game's own plunge, aimed at the enemy you picked: it lands on the body of big monsters
  reliably and no longer misses or drops beside them.
- Fixed: after every Eldritch Slash the script kept calling into the finished wave for 30 s (thousands of errors in
  the REFramework log), which could lead to a crash later.
- Fixed: an animation check ran on the render thread; it now runs with the game's own update (a possible crash).

**1.1.2**
- Dimension Door: getting hit while aiming no longer leaves the character stuck in the casting pose - the spell is
  cancelled and the hit reaction plays. Loading a save while aiming also resets the spell.

**1.1.1**
- The spell slot display now hides with the game's HUD: in menus, cutscenes, conversations (outside battle), and
  during the camp, black-screen and loading fades (it used to stay on screen there).

**1.1**
- Spell slots for Eldritch Smite and Tasha's Otherworldly Guise (1 at level 1, +1 every 15 levels, max 5, 20 s
  recharge each), shown on the HUD; the two skills are greyed out when none is free.
- Otherworldly Guise costs a quarter of your stamina (was half); Eldritch Smite's stamina drain is halved.

**1.0.2**
- Upgraded swords (with their own item data) now get Magick = Strength and Thunder too - before, only unupgraded
  swords did, so Eldritch Bolt / Blast / Slash's wave were very weak with them.
- Eldritch Slash: the wave's hits are recognised properly (its damage comes from sub-projectiles); sword hit x2,
  wave x3.
- The save guard (sword plain while the game saves) lets go by itself after 5 s at the latest.

**1.0.1**
- Otherworldly Guise: real immunity to Caught Fire, Torched, Blighted and Fulminant Poison, fire damage halved (the
  status-screen values alone didn't protect).
- Levitate can be started again in the same jump.
- Misty Dive: on big monsters you land on their body instead of being put on the ground.
- Eldritch Slash: more damage.
- Hex takes priority over Hellish Rebuke when both could fire on one Interact press.

## Settings

REFramework menu (Insert) → Script Generated UI → **Pactblade 1.3.1**: Nox sword look on/off, arm effect on/off, the spell slot display (on/off, position, size), and
**Dimension Door** (on/off, also for other vocations, the key, range, how long a door stays open, the door's look).

## Safe for your save and online

Nothing Pactblade changes is written into your save or into the pawn / Arisen data the game uploads: the sword and the
Guise chest piece go back to their originals while the game saves or uploads. Uninstalling leaves a normal save.

## Uninstall

Disable it in Fluffy Mod Manager, or delete `reframework/autorun/Pactblade.lua`, the `reframework/autorun/Pactblade`
folder, `reframework/data/VSB/packs/pactblade`, `pak_mods/Pactblade.pak` and `reframework/data/Pactblade*.json`.

## Known issues

- Single player only (your character, not pawns).
- The EX skills need the expansion's appraised special skills on your sword.
- As Warfarer, switching weapons keeps an active Guise on.
- Resting at an inn or camp doesn't end the Guise.
- When the Guise ends, a faint gold shimmer of its decoy can stay where it ended (gone with the next cast).
- The chant animations are made for a staff, so the hands are posed for one.
- Lenient Stagger and Exhaustion: Pactblade triggers Controlled Fall itself; with both installed it may double.

## Credits

- **Capcom** for Dragon's Dogma 2. The effects, animations and most sounds are the game's own, used by ID or as
  recoloured copies. No game file is replaced. The EX animations of Archfey Combo EX and Eldritch Slash EX are converted
  from Capcom's Devil May Cry 5 (the kick) and Onimusha (the sliding cut, Eldritch Slash EX).
- **praydog** for REFramework.
- **Bloodragon** for _DragonCore and VocationAndSkillBuilder.
- **SilverEzredes** and **alphaZomega** for _ScriptCore.
- **Nickesponja** for UDD2P and NickCore, whose scripts showed how to play effects, add animation banks and warp.
- REE-Lib (effect files), ree-pak-cli (paks), vgmstream (sounds).
- Built by ntgoten with AI assistance: [Claude Code](https://claude.com/claude-code) and the
  [universal-modder](https://github.com/rehan-remade/universal-modder) toolkit.

## How it was made

- [docs/PACTBLADE_MODDER_GUIDE.md](docs/PACTBLADE_MODDER_GUIDE.md) - for modders: how the vocation and each skill were built.
- [docs/PACTBLADE_AI_GUIDE.md](docs/PACTBLADE_AI_GUIDE.md) - the same in compact technical form, for AI coding assistants.
- [docs/PACTBLADE_CODE_WALKTHROUGH.md](docs/PACTBLADE_CODE_WALKTHROUGH.md) - the code itself: every hook, table and game call, with excerpts and a full index.

All three are also in the release zip (Pactblade_docs).

## Credits

- **Capcom** for Dragon's Dogma 2. The effects, animations and most sounds are the game's own, used by ID or as
  recoloured copies. No game file is replaced.
- **praydog** for REFramework.
- **Bloodragon** for _DragonCore and VocationAndSkillBuilder.
- **SilverEzredes** and **alphaZomega** for _ScriptCore.
- **Nickesponja** for UDD2P and NickCore, whose scripts showed how to play effects, add animation banks and warp.
- REE-Lib (effect files), ree-pak-cli (paks), vgmstream (sounds).
- Built by ntgoten with AI assistance: [Claude Code](https://claude.com/claude-code) and the
  [universal-modder](https://github.com/rehan-remade/universal-modder) toolkit.
