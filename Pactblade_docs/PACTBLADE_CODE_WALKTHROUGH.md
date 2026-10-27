# Pactblade - code walkthrough

The deepest of the three documents: how the code is actually built. What gets hooked (exact method signatures),
what gets called, which tables and game objects get created, with real excerpts from `Pactblade.lua` (release 1.1,
~11,900 lines). Read `PACTBLADE_MODDER_GUIDE.md` first for the ideas; this is the reference behind it. Line numbers
are approximate (they move with every edit) - search for the names instead.

Contents:
1. REFramework Lua in 10 patterns (everything the script is built from)
2. The script's skeleton (config, logging, the `live` state, blocks, release switch, the 200-locals limit)
3. Skill presses (the VSB adapter)
4. Feature by feature (state, hooks, per-frame work, game calls, excerpts)
5. Building, testing, debugging
- Appendix A: every hook in the script. Appendix B: every per-frame callback.

---

## 1. REFramework Lua in 10 patterns

**1. Find a type and a method.** Overloaded methods need the full signature (parameter types in brackets):
```lua
local td = sdk.find_type_definition("app.ActionManager")
local m  = td:get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)")
```
The exact names come from an **il2cpp dump** of the game (a JSON of every type with its fields, methods and enums).

**2. Hook it.** `sdk.hook(method, pre, post)`. In `pre`, `args[1]` is internal, `args[2]` is `this` (the object the
method runs on), `args[3]...` are the parameters - all raw pointers. `post` gets the return value and must return it
(or a replacement):
```lua
sdk.hook(m, function(args)
    local this = sdk.to_managed_object(args[2])           -- pointer -> object
    local name = sdk.to_managed_object(args[4]):ToString()  -- a System.String parameter
    local id   = sdk.to_int64(args[3]) & 0xFFFFFFFF          -- an int / enum parameter
    if want_to_block then return sdk.PreHookResult.SKIP_ORIGINAL end   -- the game's method doesn't run at all
end, function(retval) return retval end)
```
- Change a parameter: `args[3] = sdk.to_ptr(newValue)` (the VSB adapter swaps skill IDs this way).
- Change the return value in `post`: `return sdk.to_ptr(1)` (true), `return sdk.float_to_ptr(0.5)`.
- Pass data from `pre` to `post` of the same call: `thread.get_hook_storage()` (a table per call, safe with recursion
  and threads), or a stack table you push in `pre` and pop in `post`.
- **Speed:** hooks on methods the game calls for every character (requestActionCore, calcDamageValue...) run for
  every NPC too. Return as early as possible: Pactblade compares `args[2]` with the player's own object address first:
```lua
if not live.am or sdk.to_int64(args[2]) ~= live.am then return end   -- not the player's ActionManager
```

**3. Objects: fields vs methods.** `obj:get_field("_Name")` / `obj:set_field("_Name", v)`, or the short form
`obj._Name` / `obj._Name = v`. Properties are methods: `obj:get_Position()`, `obj:call("get_Position")`. Auto
properties have backing fields: `a.character["<StatusConditionCtrl>k__BackingField"]`. Overloads via `call` with the
signature: `mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)", id, go, -1, nil)`.

**4. Singletons:** `sdk.get_managed_singleton("app.ItemManager")`, `"app.HitManager"`, `"app.EnemyManager"`,
`"app.CharacterManager"` (the player = `["<ManualPlayer>k__BackingField"]`), `"app.GuiManager"`, `"app.TimeManager"`.

**5. Components of a GameObject:**
```lua
local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
local ep  = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
```

**6. New objects and resources.** Keep a reference (`:add_ref()`) to anything you create, or the game's GC frees it:
```lua
local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()   -- a game class instance
local res  = sdk.create_resource("via.effect.EffectResource", "vfx/effects/pactblade/pb_40_e285.efx"):add_ref()
local hold = res:create_holder("via.effect.EffectResourceHolder"):add_ref()   -- what components take
local v    = ValueType.new(sdk.find_type_definition("via.Color"))             -- a value type (struct)
```
A new GameObject (an "anchor" for our effects):
```lua
local function make_anchor()
    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "Pactblade_glow", 0)
    go = go:add_ref()
    go:call(".ctor")
    go:set_Name("Pactblade_glow")
    return go
end
-- later: go:call("destroy(via.GameObject)", go)
```

**7. Enums by name** (never hard-code a number you can look up):
```lua
local FIRE = sdk.find_type_definition("app.StatusConditionDef.StatusConditionEnum"):get_field("FireSpread"):get_data(nil)
```

**8. Per-frame work:** `re.on_frame(fn)` (once a frame), or tied to the engine's update steps:
`re.on_pre_application_entry("UpdateBehavior", fn)` (game logic; do teleports here), `"UpdateMotion"` (animation;
force motions here), `"LateUpdateBehavior"` (after the game moved things - pin / follow objects here; the
`re.on_application_entry` variant runs after the game's own late update), `"BeginRendering"` (material colours,
right before drawing). `re.on_script_reset(fn)` to clean up, `re.on_draw_ui(fn)` for the menu (imgui).

**9. Everything in `pcall`.** Game objects die between frames (an enemy despawns, a weapon is switched); any call can
throw. Wrap each unit of work: `pcall(function() ... end)`. One error in a callback can stop the other callbacks of
the same engine step for that frame.

**10. Files:** `json.load_file(name)` / `json.dump_file(name, table)` read and write `reframework/data/<name>`.

**DragonCore** wraps the player as an "actor" `a` (`runtime.player()`): `a.character` (app.Character),
`a.game_object`, `a.action_manager`, `a:request_action(name, layer)`, `a:current_action(layer)`, `a:button_pressed(name)`
/ `a:button_down(name)` (CharacterInput.Action names: "JobSpecialAction", "Interact", "Jump", "AttackS"...),
`a:stamina()`, `a:consume_stamina(n)`, `a:set_speed(x)`, `a:set_super_armor(on)`, `a:is_grounded()`,
`a:spawn_shell(node, opts)` (projectiles), `a:weapon_job()`.

---

## 2. The script's skeleton

### 2.1 Config, logging, debug table
- `cfg` (~line 119): every tunable value with its default (`boom = 0.31`, `burstWindow = 0.8`, `noxBladeR = 91` ...),
  overwritten from `reframework/data/Pactblade.json` at load; `save_cfg()` writes it back.
- `dbg` (~line 242): a shared table for diagnostics AND for passing functions between blocks (see 2.4).
- `note(s)`: appends a timestamped line to `trace` (last 120 lines), written to `Pactblade_trace.json` at most every
  2 s by an `re.on_frame`. Every skill notes what it does ("Misty Dive: strike (at its head)..."), which is how every
  bug in this project was found.
- `BLAST` (~line 47): per projectile kind (`tap`, `charged`, `burst`, `slash`): shell id, animation, scale, effect
  scale `fx`, damage `factor` / `dmgMul`, `stagger`.

### 2.2 `live`: the state every hook reads
```lua
local live = { on = false, go = nil, am = nil, ctx = nil, avail = nil, shieldWorn = false, sc = nil }
-- every frame in update_body():
live.go = a.game_object and a.game_object:get_address()        -- player GameObject address
live.am = a.action_manager and a.action_manager:get_address()  -- player ActionManager address
live.vsb = vsb_state()                                          -- "picked" / "not picked" / "missing"
live.on = (live.vsb == "picked") and a:weapon_job() == 1        -- Pactblade active
live.settled = live.on and now - (live.onSince or now) >= 2.0   -- active for 2 s (safe for warm-ups)
live.sc = a.character["<StatusConditionCtrl>k__BackingField"]:get_address()
```
Hooks compare **addresses** (cheap integers) instead of objects. `vsb_state()` reads VSB's global
`VSB_API.app.picks.Job01 == "pactblade"`.

### 2.3 Blocks and the 200-locals limit
Lua allows 200 local variables per function, and the main chunk is at that limit. So each feature lives in its own
immediately-called function: `;(function() local bm = {...} ... end)()`. Things another block needs go into `dbg`:
`dbg.beam = bm`, `dbg.guise = gu`, `dbg.smite = sm`, `dbg.misty = md`, `dbg.rebuke = hr`, `dbg.hex = hex`.
**Order matters:** a block can only see locals defined above it; a callback defined above `local live` must use
`dbg.live`. A name used before its definition is a nil global at run time and the syntax check won't tell you.

### 2.4 The release switch
At the top:
```lua
local json = json
do
    local RELEASE = true
    if RELEASE then
        local KEEP = { [DATA] = true, ["Pactblade_guise_items.json"] = true, ... }
        local real = json
        json = setmetatable({ RELEASE = true,
            dump_file = function(name, ...) if KEEP[name] then return real.dump_file(name, ...) end return true end },
            { __index = real })
    end
end
```
With `json.RELEASE` the menu shows only the player options and debug dumps aren't written. `RELEASE = false` = the
test build (Debug menu, Recorder, spawner, sliders).

---

## 3. Skill presses: the VSB adapter

VSB gives each of Pactblade's 8 skills its own `HumanCustomSkillID` and stores the mapping in
`reframework/data/VSB/state/idtable.json` (`ids.custom[uuid] = id`). The skill code itself listens for Fighter skill
IDs (it started as a takeover of Fighter skills). The adapter translates:

```lua
local UUIDS = { ["4a1d3cc4-..."] = "smite", ["9a6da1ea-..."] = "slash", ... }   -- the skill files' fixed uuids
local function binding(kind)   -- which Fighter id each kind's code listens to
    if kind == "smite" then return cfg.smiteSkill or "Job01_BlinkStrike" end
    if kind == "slash" then return "Job01_HindsightSlash" end
    ...
end
function A.refresh()   -- every 5 s until all 8 are known
    local ids = json.load_file("VSB/state/idtable.json").ids.custom
    for u, kind in pairs(UUIDS) do
        local vid, fid = ids[u], fighter_id(binding(kind))   -- fighter_id: HumanCustomSkillID enum by name
        if vid and fid then A.map[vid] = { kind = kind, fid = fid } end
    end
end
local function translate(args, idx)
    local e = A.map[sdk.to_int64(args[idx]) & 0xFFFFFFFF]
    if not e then return end
    args[idx] = sdk.to_ptr(e.fid)                  -- the press becomes the Fighter id
    dbg.pbDepth = (dbg.pbDepth or 0) + 1           -- "this press is ours" while the call runs
    thread.get_hook_storage().pbT = true
end
local PID = sdk.find_type_definition("app.PlayerInputProcessorDetail")
sdk.hook(PID:get_method("processCustomSkill(app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean, app.LocomotionSpeedTypeEnum, System.Boolean)"),
    function(args) pcall(translate, args, 3) end, done)
sdk.hook(PID:get_method("processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean)"),
    function(args) pcall(translate, args, 4) end, done)   -- the button's own entry (also fires in the AIR)
-- done(r): pbDepth back down in post
```
Every skill's own hook on the same methods checks `dbg.press_ok()` (= `pbDepth > 0`), so a real Fighter skill press
is never taken. Because the translated Fighter skill may not be equipped / available, a hook on
`HumanSkillAvailability.isCustomSkillAvailable(app.HumanCustomSkillID)` (and `...WithoutItemCondition`) answers true for
the translated id during our press. A skill then answers the press like this (Eldritch Slash):
```lua
sdk.hook(PID:get_method(SIG), function(args)
    if not live.on or not dbg.press_ok() then return end
    if (sdk.to_int64(args[3]) & 0xFFFFFFFF) ~= HINDSIGHT_ID then return end
    local track = runtime.player().character:get_Human().Track       -- may the character use a skill now?
    if (track.All or track.Skill) and not slash.on then slash.lastPress = os.clock(); slash.want = true end
    return sdk.PreHookResult.SKIP_ORIGINAL                          -- the Fighter skill never plays
end, function(r) return r end)
```
`slash.want = true` is then picked up by the skill's `UpdateBehavior` callback, which runs the skill frame by frame.
That split (hook = "pressed", per-frame callback = "do it") is used by every skill.


## 4. Feature by feature

Each part: **state** (the tables the feature keeps), **hooks** (method → what pre / post do), **per frame** (which
engine step, what it does), **game calls**, and excerpts.

### 4.1 Passives and the sword
**State:** `cfg.*`, `swordMod = { param, own, id, itemId, mag, el, store }`, `heldEl`, `PHYS_BONUS, MAG_BONUS = 1.0, 1.5`.

**Damage passive** - hook `app.HitController.calcDamageValue(app.HitController.DamageInfo)`:
- pre: `info = sdk.to_managed_object(args[3])`; only if `info["<AttackOwnerObject>k__BackingField"]` is the player;
  find out what hit (`blast_kind_of(info:get_AttackHitController())` - one of our projectiles?) and remember it in
  `thread.get_hook_storage()`.
- post: read the parts `phys = SlashDamage + ShootDamage`, `mag = MagicDamage + EnchantDamage`, then
  `info.Damage = before * (phys * PHYS_BONUS + mag * MAG_BONUS) / (phys + mag)`; for projectiles
  `info.Damage = magick * DamageRate * BLAST[kind].factor`, then `* BLAST[kind].dmgMul`, Hex, Smite.

**The sword** (`sword_update`, `re.on_frame`, every 0.5 s):
```lua
local im = sdk.get_managed_singleton("app.ItemManager")
local param = im:call("getItemData(app.WeaponID)", held_weapon_id())        -- the item's template
swordMod = { param = param:add_ref(), id = id, itemId = param._Id, mag = param._MagicAttack, el = param._Element, store = param._ElementStore }
param._MagicAttack = param._PhysicalAttack
param._Element = sword_element()          -- 3 = Thunder
param._ElementStore = HOLY_STORE          -- 100 = full strength
-- an upgraded sword carries its OWN copy of the item data in its storage entry:
local sd = data:call("get(app.EquipData.SlotEnum)", MAIN)   -- data = im:call("getEquipData(app.Character)", a.character).Data
local own = sd:get_field("_ItemData")
if own and own:get_address() ~= param:get_address() then (same three fields on `own`) end
refresh_equipment(itemId)   -- data:updateEnhanceEquip(storageData) for the equipped entry + full recalc:
-- data:call("clearParam"); data:call("calc"); im:call("applyEquipDataForCharacter(app.Character)", a.character)
```
`sword_restore()` writes the remembered values back (template and own copy). The held weapon is read from the weapon
slot (`CharacterManager.ManualPlayer:get_WeaponAndItemHolder():get_RightWeapon()` → field `<Weapon>k__BackingField`),
never through `WeaponElementController.getWeapon` (it threw during vocation changes and crashed).

**Core skills** - hooks on `app.HumanSkillContext.isNormalSkillEnable(app.HumanNormalSkillID)`,
`app.PlayerInputProcessorDetail.isNormalSkillEnable(...)`, `app.HumanSkillAvailability.isNormalSkillAvailable(...)`:
pre pushes `1` (grant: ids 17 Controlled Fall, 18 Footpad, 27 Quik Fot), `0` (deny: 4, 5, 7, 8) or `false` on a stack;
post pops it and returns `sdk.to_ptr(v)` instead of the game's answer. Footpad also needs its input handler every
frame: `a.character["<InputProcessor>k__BackingField"].DetailInstances[3]:call("processKickWall")`.

**Shield** - hook `app.ItemManager.setEquip(app.ItemDefine.StorageData, app.Character, app.EquipData.SlotEnum, System.Boolean, System.Boolean)`:
`SKIP_ORIGINAL` when the slot is 1 (sub) for the player and the item isn't already equipped. The shield actions:
`requestActionCore` pre-hook skips any `Job01_*Guard*` / `*Shield*` name for the player.

**Boons** - hook `app.StatusConditionCtrl.reqStatusConditionApplyCore(StatusConditionEnum, DamageInfo, RequestInfo, Boolean)`:
`SKIP_ORIGINAL` when `this` is the player's (`live.sc`) and the status is 15 / 16 / 17.

**Speed** - `update_speed(a)` every frame: if `a:current_action(0)` is an Onslaught name, `a:set_speed(1.5)`; other
Fighter attacks 1.2; else `a:set_speed(nil)`.

### 4.2 Vocation button: Bolt and Burst
**State:** `st = { phase = "idle" | "holding" | "charging", t0, pending, recover, dodgeUntil }`, `blasts = { {record,
kind, born} }` (every projectile we spawned, so hooks can recognise its hits / effects), `params[shellId]` (the
shell's parameter object, learned at the first spawn), `bindBolt`.

**Per frame** (`update_body` → the button logic, UpdateBehavior): `down = a:button_down("JobSpecialAction")`;
- idle + pressed: inside a Burst window (`dbg.basicName` = the current sword swing, its start time; or the Empale /
  Tusk Toss frame ranges) → `fire(a, "burst")`, else `phase = "holding"`;
- holding: released before `HOLD_SEC` (0.5) → dodge `a:request_action("Job04_Dodge", 0)` (re-asked until it plays);
  held long enough → `phase = "charging"` + `dbg.rim_glow(a, true, 0.3)` (a short body glow);
- charging + released → `fire(a, "charged")`.

**`fire(a, kind)`** picks the target (`dbg.beam.aim_pick`), turns the character, requests the animation and sets
`st.pending`; when the animation has run `BLAST[kind].delay` seconds, `spawn_blast(a, kind)`:
```lua
shape_effects(b)   -- the shell's effectParam.EffectScale = b.fx (0.5) for 1 s, restored after
local res = spawn(a, { type = "shell", id = "eldritch_" .. kind,
    shell = "AppSystem/Shell/UserData/HumanShellParamData_Job07.user", shell_id = b.shell,   -- 12 = Sperepelote
    cast = { mode = "joint", joint = "L_Hand_Palm", face = "crosshair" },
    scale = b.scale, speed = b.speed, lifetime = b.lifetime }, aimOpts)   -- DragonCore a:spawn_shell
table.insert(blasts, { record = res.record, kind = kind, born = os.clock() })
if cfg.blastTint then colour_shell(res.record, col, 6.0) end   -- tint its effects for 6 s
```
**Block the animation's own bolts** - hook `app.ShellManager.requestCreateShell(via.GameObject, via.vec3, via.Quaternion, ShellCreateInfo, ShellParamData, ...)`:
for 1.5 s after a fire, owner = player → `SKIP_ORIGINAL`, except the charged animation's Forbeding Bolt (`cfg.bind`),
which is captured (`bindBolt.go`) and moved onto our projectile's position every LateUpdateBehavior (`bind_follow`).

**Projectile colouring** (`colour_shell` → `colour_update` 5x a second): for every effect container of the record's
parts, every player gets `set_Color(col)` and the container `setRootColor(col)` - skipped once `get_isFinished`.

### 4.3 Effect hooks: replace, tint, kill, scale
All on `via.effect.script.ObjectEffectManager2`: `requestEffect(via.effect.script.EffectID, ...)` (the overloads whose
first parameter is an EffectID) and the animation paths `requestEffectInternal`, `requestEffectFromFsmOrSequence`,
`requestEffectFromFsm`, `requestEffectParamFromFsm`, `requestEffectParamAllElementsFromFsm` (they return a
`CreatedEffectContainer`). The ID is read with `effect_id_of(args, how)` → `"d/c/e"`.
- pre decides what to do with this request and pushes it on stacks (`stack`, `tstack`, `rstack`, `mst`):
  `"kill"` (combo dust, beam animation effects, the air beam's big swirl `13/20/56`), `"scale"` (our explosions),
  a tint id (`tint_wanted`: our projectiles' effects, the player's own Spearhand set `13/*` and `0/160/*` for 2 s after
  a fire or during the air beam), a part id (`parts.wanted`), a Misty Dive replacement path (`dbg.md_fx`).
- post pops them and acts on the returned container `c = sdk.to_managed_object(rv)`:
  `c:call("killAll")`; `c:call("setUniformScale", cfg.boom)` + keep it in `clouds` (rescaled every frame -
  the effect rebuilds its players); `tint_add` (its players `set_Color`); `parts.add(rv, id)`; `dbg.md_fx_play(rv, path)`.

**parts** (`parts.ids`, `PART_DEFAULTS`, `OUR_FILES[id]` → our file for the chosen colour): `parts.add` reads the
container's `Creator` (the projectile's GameObject); mode `ours` → `parts.play_ours(id, pos, rot, creator)` + `killAll`:
```lua
local go = make_anchor()
go:get_Transform():set_Position(at); go:get_Transform():set_Rotation(rot)
local ep = go:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer")):add_ref()
ep:call("set_Resource", parts.res[path]:create_holder("via.effect.EffectResourceHolder"):add_ref())
ep:call("set_AutoStart", true)
tr:set_LocalScale(creator:get_Transform():call("get_Scale"))   -- the projectile's size (x0.3 / x0.5 for -1/8/40)
table.insert(parts.ours, { go = go, ep = ep, creator = creator, untilT = os.clock() + 3, follow = ... })
```
A LateUpdateBehavior callback moves `follow` copies with their creator (the Slash wave) and destroys them after
`untilT`.

### 4.4 Misty Step, Hex
**Bind window** (on_frame, with `cfg.bind`):
```lua
local mb = h:get_field("<Job07ActionCtrl>k__BackingField"):get_field("<MagicBindCtrl>k__BackingField")
local open = mb:call("get_IsJustMagicBindEnable")      -- dbg.leapOpen = open
local target = mb:call("get_MagicBindShellHitOwner")
if open and (a:button_pressed("Interact") or a:button_pressed("GimmickAction")) then dbg.hex_put(a, target) end
if open and a:button_pressed("Jump") then ... a:request_action("Job07_MagicBindJustLeap", 0) (re-asked 0.3 s) ... end
```
The leap moves the character toward `leap.target` in UpdateBehavior; afterwards the enemy's bind is ended:
`ch["<BindCtrl>k__BackingField"]:get_MagicBind():stop(false)` + `deleteBindEffect`, `mb:resetHitMagicBindInfo()`.

**Hex** (`hex = { secs = 15, defence = 0.10, heal = 0.15, staminaPct = 0.10, copies, anchors = {}, target, go, untilT }`):
- `hex.put`: stamina `smg:call("setRemainingAmount(System.Single)", left - max * 0.10)`, `hex.target = t:add_ref()`,
  `hex.untilT = dbg.gclock() + 15`, `hex.build()` = `2 * copies` anchors with our `pb_hexx_b*` file.
- LateUpdateBehavior: the X placed above the highest joint named `*head*` (searched every 0.3 s), scaled
  `clamp((head - feet) / 1.8, 1, 4)`, the two lines rolled +-45 degrees and turned to the camera; after `freezeAt`
  each player `set_PlaySpeed(0)`. If the target's HP is 0: `hc:call("recoverHp(System.Single, System.Boolean, System.Int32, System.Boolean)", maxHp * 0.15, false, 0, false)`.
- `dbg.hex_mul(info)` in the damage hook: `1 / 0.9` when the hit's victim is `hex.go`.

### 4.5 Hellish Rebuke
**State:** `hr = { window = 0.5, cooldown = 6, staminaPct = 0.30, bank = 9112, motion = 750, BURN = 5, open,
lastCast, resSwaps = {}, fireRes = {}, sparks = {} }`.
- **Window:** a calcDamageValue pre-hook on hits whose `DamageGameObject` is the player, from a living enemy, not a
  direct-damage status tick, no reaction or a flinch → `hr.open = { untilT = now + 0.5, who = attacker:add_ref() }`.
- **Cast** (UpdateBehavior): `a:button_pressed("Interact")`, not while the Hex window is open, cooldown on
  `dbg.gclock()` (a clock without menu pauses). The clip: `castT.bank(a)` (the Mage motion file as dynamic bank 9112),
  then every UpdateMotion `L:call("set_Speed", 0.0); L:call("set_Frame", t)` (the clip played at our own time, x1.2).
- **On the attacker:** `HitManager.directDamage` with `DamageType = 6` (Hitback_M), `DamageReaction = 10000`,
  `IsForceReceived`; then
  `t["<StatusConditionCtrl>k__BackingField"]:call("reqStatusConditionApplyCore(...)", hr.BURN, nil, req, false)`.
- **Green flames** (`hr.swap_flames(go, true)` before the burn):
```lua
hr.each_fx_data(go, function(ci, key, id, el)          -- every element of this character's effect data
    for i = 0, el:call("getResourcesCount") - 1 do
        local h = el:call("getResources", i)
        local path = tostring(h:call("get_ResourcePath")):lower()
        local num = path:match("ch00_badstatus_000_(%d+)")   -- (or cm_badstatus_100_ / 101_ for enemies)
        if num then
            hr.resSwaps[#hr.resSwaps + 1] = { el = el:add_ref(), i = i, orig = h:add_ref() }
            el:call("setResources", i, hr.fireRes[ours]:create_holder("via.effect.EffectResourceHolder"):add_ref())
        end
    end
end)
-- back after 14 s (game clock): for _, sw in ipairs(hr.resSwaps) do sw.el:call("setResources", sw.i, sw.orig) end
```
  `hr.each_fx_data` walks `mgr.StandardDataMap._entries[k].value:getElementIDList()` → `getElementFromID(id)` and
  `mgr.ExpertProviderInfoList[k]._Data.Elements`, for the manager and every `ExternalDataContainers` entry.

### 4.6 The chant (`castT`, used by Caustic Brew, Guise)
**State:** `castT = { secs = 3.0, BANK = 9112, PATH = "animation/ch/ch00/motlist/ch00_006_atk.motlist", t0, step,
conts = {}, anchor, paused, onRelease, onEnd }` and `castT.STEPS` (a timeline):
```lua
castT.STEPS = {
    { t = 0.0, fx = { { "ch03/13_ch03_ns", 0, 40, true }, { "ch03/13_ch03_cs", 0, 104, true } }, snd = 2921097576, motion = 710 },
    { t = 0.2, snd = 3366100101, loop = true },
    { t = 0.4, fx = { { "ch03/13_ch03_cs", 0, 304, true } }, motion = 712 },   -- the chant circle
}
```
- **The Mage motions as a dynamic bank:**
```lua
local mo = a.character:get_Motion()
local holder = sdk.create_resource("via.motion.MotionListResource", castT.PATH):add_ref()
    :create_holder("via.motion.MotionListResourceHolder"):add_ref()
local n = mo:getDynamicMotionBankCount()
mo:setDynamicMotionBankCount(n + 1)
local bank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
bank:set_MotionList(holder); bank:set_OverwriteBankID(true); bank:set_BankID(9112)
mo:setDynamicMotionBank(n, bank)
-- ready when: mo:call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", 9112, 712, info)
```
- **Play / hold:** `mo:getLayer(0):call("changeMotion(UInt32, UInt32, Single, Single, InterpolationMode, InterpolationCurve)", 9112, id, 0.0, blend, 1, 1)`;
  the state machine paused: `go:call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2")):call("set_Paused", true)`.
- **A Mage effect on a Fighter:** find the external data set whose path contains `ch03/13_ch03_cs` in
  `mgr.ExternalDataContainers[i].DataContainer:get_Path()`, then `requestEffect(EffectID{index = i, container, element}, playerGO, -1, nil)`;
  the circle's container is later moved onto our anchor in front of the chest.
- **Timeline** (UpdateBehavior): run the STEPS whose `t` has passed, keep motion 712 looping, at 3 s the release
  (flash + chime 3990051307, motion 750, stop sound 2605810471, `castT.onRelease(a)`), at 3.9 s clean up.
- **Interruption:** `requestActionCore` pre-hook for the player during a chant: names starting `Dmg` / `Caught`, or
  containing `Down` / `Blown` / `Slam` → `castT.cancel`.

### 4.7 Caustic Brew
**State:** `sk = { castSecs = 3.0, ahead = 1.0, lingerSecs = 5.0, halfWidth = 1.25, tickSecs = 0.3, tickDmg = 72,
poisonPts = 35, file = "pactblade/pb_acid_v3", area, wave, meters = {}, poisonQ = {} }`.
- Press → `castT.start(a)` with `castT.onRelease = sk.release`.
- `sk.release`: stamina set directly (`setRemainingAmount`: during the chant the game's `add` is ignored), the strip
  `sk.area = { pos, fx, fz, t0 }` along the character's facing, the wave `sk.wave`.
- on_frame: every 0.07 s one acid copy `acid_at(pos + fwd * (1 + n * 1.9), rot)` (8 copies), each an anchor + an
  EffectPlayer with `pb_acid_v3`, destroyed after 6 s, with a splash sound.
- `sk.tick(a)` every 0.3 s for 5 s:
```lua
local list = sdk.get_managed_singleton("app.EnemyManager")._EnemyList
for k = 0, list._size - 1 do
    local ch = list._items[k]._Chara
    local hit = ch["<Hit>k__BackingField"]
    local p = (ch.Hip or ch["<Transform>k__BackingField"]):get_Position()
    local along, side = dx * fx + dz * fz, math.abs(dx * fz - dz * fx)   -- position in the strip
    if inside then
        local info = sdk.create_instance("app.HitController.DamageInfo"):add_ref()
        info.Damage = sk.tickDmg
        hm:call("directDamage", info, hit, me, false, myHit)
        m.value = m.value + sk.poisonPts   -- own poison meter per enemy; at 100 -> sk.poisonQ
    end
end
-- LateUpdateBehavior: for each queued enemy: reqStatusConditionApplyCore(Poison, nil, RequestInfo, false)
```
  (Statuses are asked outside the damage calculation, on the late update.)

### 4.8 Eldritch Slash
**State:** `SLASH = { action = "Job05_CrescentSlashNormal", to = 97, shell = 6, stamina = 160 }`,
`slash = { on, want, started, fired, rec, target, waves = {} }`.
- `slash_update` (UpdateBehavior): request the action; read `L = a.character.FullBodyLayer`, `fr = L:call("get_Frame")`;
  before `cfg.slashFrame` turn toward `slash.target`; from `cfg.slashFastFrom` `a:set_speed(1.2)` and
  `L:call("set_Speed", 1.2)`; at `cfg.slashFrame` (64) the wave:
```lua
local res = spawn(a, { type = "shell", id = "eldritch_slash", shell = JOB07_SHELLS, shell_id = 6,
    cast = { mode = "owner", offset = { 0, 1.2, 1.3 }, face = "owner" }, scale_axes = { 1, 2, 1 } })
table.insert(blasts, { record = res.record, kind = "slash", born = os.clock() })
dbg.slashT = os.clock()
```
- Range: hook `app.ShellAdditionalJob07SubNormalAttackShell.update()` pre: for our wave's shell, scale
  `DetailParam.DefaultRangeDist`; the wave is ended with `shell:call("set_RequestKill", true)` (its end effect dropped).
- Damage: wave hits come from **sub-shells**: in the damage hook, a hit from any player shell within 4 s of
  `dbg.slashT` that isn't another kind counts as `"slash"` (x `BLAST.slash.dmgMul` = 3); the swing's own hits
  (`slash.on`, no projectile) x2.

### 4.9 Misty Strike
**State:** `bs = { ACTION = "Job01_BravesRaid", from = 106, to = 235, fastFrom = 150, fastSpeed = 1.7,
cancelFrom = 170, endBlend = 8, prep = true, PREP = "Job07_SkyDive", stage, target, retries }`.
- Press (`processCustomSkill` hook, gate `dbg.press_ok()`): `dbg.busy_action(a)` and the skill track checked; in the
  air `dbg.air_ok(a)`.
- `stage = "prep"`: `request(a, "Job07_SkyDive")`, ground lock (y kept at the press height in UpdateMotion /
  LateUpdateBehavior / BeginRendering for the crouch), after 0.25 s the warp behind the target:
  `combo.warp_to(a, dest, rot, dx, dz)` with `dest` = target position + (its radius + 1.2 m) on the far side, its y
  from `combo.nearest_hit` (a ray down).
- `stage = "strike"`: request `Job01_BravesRaid`; once it plays, crossfade to frame 106:
  `L:call(CHANGE, L:call("get_MotionBankID"), L:call("get_MotionID"), 106.0, 6.0, 1, 1)`; then each frame
  `L:call("set_Frame", fr + dt * 60 * (fastSpeed - 1))` from frame 150 (the layer's `set_Speed` was ignored); from
  170 any of `AttackL, AttackS, Jump, JobSpecialAction, Skill1-6, Dash, SkillAdditional` pressed → crossfade to the
  last frame (`to_end()`) + `NormalLocomotion`.
- `requestActionCore` pre-hook: while the strike plays, landing / fall / jump requests and Riotous Fury's own
  follow-ups are `SKIP_ORIGINAL`.

### 4.10 Misty Dive
**State:** `md = { above = 1.8, range = 15, fallSpeed = 7, dmg = 1500, landGap, bigRadius = 1.0, stage, follow,
lockXZ, FX = { ["14/7/10"] = "sd10", ... } }`.
- Pick (`md.pick`): enemies from `EnemyManager._EnemyList`, alive (`["<Hit>k__BackingField"]:get_Hp() > 0`), within
  range and cone, beyond 5 m only those on screen (`draw.world_to_screen`).
- Prep (SkyDive) → warp above the head → `Job01_HeavyAttackAir`; `md.follow = { t, ox, oz, lastY, low }`.
- `md.follow_step` (UpdateBehavior): `x, z = target + offset`, `y = max(low, min(y, lastY - fallSpeed * dt))`
  (never up), `tr:set_Position(...)` + `CharaController warp`; at the head held up to 0.25 s, then `md.strike`:
  a direct hit if the blade didn't land (`DamageType = 7`, Hitback_L), then the landing: big monster
  (`t["<CharaController>k__BackingField"]:call("get_Radius") >= 1.0`) → nothing (falls onto it), else put just outside
  its radius on the ground found by a ray.
- Teal → purple: `dbg.md_fx(args, idd)` (in the effect-request pre-hook) returns our file path for ids in `md.FX` while
  `md.busy()`; post `dbg.md_fx_play(rv, path)`: our EffectPlayer on a new anchor following the player, copying the
  game player's emitter mask / group settings (`get_EmitMaskBit`, `getGroupNames`), then `c:call("killAll")`.

### 4.11 Eldritch Blast (beam)
**State:** `bm = { ACTION = "Job01_BravesRaidStart", AIR_ACTION = "Job07_MagicBindComplete", fireFrame = 57,
grow = 0.10, hold = 0.45, fade = 0.15, chainScale, spacing = 0.5, maxCopies = 50, freezeAt = 0.10, magRate = 3.5,
stamina = 200, airKill = { ["13/20/56"] = true }, airLaunchScale = 0.3, shot, fx = {} }`.
- `update` (UpdateBehavior): face the target, at frame 57 (`L:call("get_Frame")`) `fire(a)` → `bm.shot = { t0, palm0,
  aim, target, chain = {}, n = dist / spacing }`. The sound is started early by the measured frame rate.
- **The beam** (LateUpdateBehavior, every frame): `frac = t / grow`; for copy i with `i/n <= frac`: create it once
  (`anchor("beamrowf")` = own GameObject + EffectPlayer), place it at `palm + dir * dist * i/n`, rotate
  `look_rot(dx, dy, dz)`, scale `chainScale * width`; after `freezeAt` `an.ep:call("set_PlaySpeed", 0.0)`; the first
  1.5 m shrink away after 0.15 s; after `grow + hold` the width fades to 0, then everything is destroyed.
- **The hit** (once the beam has grown + 0.15 s): a `DamageInfo` with `Damage = dbg.boltMag * 3.5`,
  `IsMagicAttack = true`, `MagicDamage = dmg`, physical parts 0, `DamageType / DamageActType / OverwriteBlownType = 6`,
  `DamageReaction = 300` → `HitManager.directDamage(info, targetHit, me, false, myHit)`; plus
  `parts.play_ours("-1/8/40")` and `("-1/8/43")` at the target.
- **Stamina swap** - hook `app.StaminaManager.add(System.Single, System.Boolean)` pre: while `dbg.stamSwap` is set and
  the amount is a big drain (< -300), replace `args[3]` with our cost.

### 4.12 Archfey Combo
**State:** `COMBO = { {action, from, to, warp} x4 }`, `combo = { stage = 0..4, target, aim, asked, started,
framed, reapply = { dest, rot, n }, finalHit }`, `CUES` (warp effect ids + sounds), `wisps`, `ai` (afterimage).
- `combo_stage(a, k)`: request `COMBO[k].action`, remember `combo.prevMot` (the layer's motion) to know when the new
  one plays; in UpdateBehavior: once on the new motion, jump to `from` (crossfade), wait for `to`, then
  `warp_spot(a, how)` (side / behind / head, on the dynamic cross of `enemy_sides(a)`) and `combo.warp_to`:
```lua
function combo.warp_to(a, dest, rot, dx, dz)
    pcall(wisps.burst, a, false)                       -- wisps where we leave
    if dbg.ai then pcall(dbg.ai.warp, a) end           -- the afterimage clone where we leave
    cues(a, ..., CUE.depart_snd, tr:get_Position(), tr:get_Rotation())
    tr:set_Position(dest); tr:set_Rotation(rot)
    a.character["<CharaController>k__BackingField"]:call("warp")
    face(a, dx, dz)                                    -- TargetAngleCtrl Front + Move angles
    pcall(wisps.burst, a, true)                        -- wisps where we arrive
end
-- the controller may put us back for a frame or two: combo.reapply re-sets the position for n frames
```
- **Sounds** (`cue_sound(a, triggerId)`): find a `soundlib.SoundContainer` on the player whose `_TriggerInfoList`
  has the trigger, `createRequestInfo(info, go, go, info._OffsetJointHash, false, false, 0, 0, nil, nil, nil, nil)`,
  set its `<Container>k__BackingField`, `sc:call("trigger(soundlib.SoundManager.RequestInfo)", req)`.
- **Wisps:** `wisps.donor_mgr(a)` = a hidden Stalwart Sword spawned once:
  `sdk.get_managed_singleton("app.EquipmentManager"):call("requestInstantiate(app.WeaponID, via.Component, ...)", 3368873434, ownerTransform, nil, nil)`;
  its `ObjectEffectManager2` plays element 30 (`EffectID{ -1, 0, 30 }`) on our anchors at the feet / hips.
- **Afterimage** (`ai`): `h = a.character:get_Human()["<Job07ActionCtrl>k__BackingField"]["<AfterImageHandler>k__BackingField"]`;
```lua
local snap = ai.snapshot(a)   -- every joint of the player: { name, LocalPosition, LocalRotation }
h:call("init(System.Boolean)", false)
local info = sdk.create_instance("app.CloneCharacter.StartInformation"):add_ref()
info:call("set_Position", tr:get_UniversalPosition()); info:call("set_Rotation", rot)
h:call("start(app.CloneCharacter.StartInformation)", info)
-- every LateUpdate (post): inst.RootMoveScale = 0, position pinned, ai.apply_pose(inst) (each joint by name:
-- set_LocalPosition / set_LocalRotation), requestStartEffect() / requestBodyEffect() once, colours painted;
-- after 0.3 s h:call("finish")
```
  If `h:call("get_Instance")` is nil, `ai.ensure` asks `h:call("create")` (every 5 s while active) - never a handler of
  our own.

### 4.13 Eldritch Smite
**State:** `sm = { fast = 1.5, blend = 12, PARTS = { {action = "Job05_ShortRangeHeavyAttack", from = 0, to = 66.6},
{action = "Job05_ArcOfObliterationEnd", from = 50, fastFrom = 150, to = 347} }, stage, dead }`.
- Two stages like the combo (request, crossfade to `from`, speed `1.5` on the FullBodyLayer from `fastFrom`).
- Part 2: `dbg.nox_boost(true)`; the damage hook's pre calls `dbg.smite_hit(info)` for the first melee hit
  (`info:get_AttackHitController()` = the player's own) → our `-1/8/43` copy x2.5 at the victim, the knock-down
  (`getReactionDamageType` post returns Slam_L, `calcDamageReaction` post x150), unless `sm.lethal(info)` (damage
  >= victim HP) → `sm.soften(info)` (no knock-down, no push) and `sm.mark_dead(info)`.
- Killed body: hook `app.DamageRagdollBlow.start(via.behaviortree.ActionArg)` pre → `set_IsBlownWithAttackVelocity(false)`,
  `IsDisableCalcVelocity = true`; LateUpdateBehavior for 2 s:
  `go:call("getComponent(System.Type)", sdk.typeof("app.CharacterRagdoll")):call("limitLinearVelocity(System.Single, System.Single)", h, up)`.
- Own sounds: our sound lists loaded into the player's `app.WwiseContainerApp` (`loadContainableUserData`), played
  like cue_sound with our trigger ids.

### 4.14 Tasha's Otherworldly Guise
**State:** `gu = { scale = {1.10, 1.04, 1.06}, CHESTS = {{"Grand Cuirass","Tops_015"},...}, LEGS = {{"Raptor
Claws","Pants_012"},...}, ill = { enable = 1, front = 0.25, rim = 0.80, fade = 0.30, fadeLegs = 0.38, ... }, inst,
on, t0, secs = 60, pairs, hidden, illSlots, bonus = { def = 0.2, itemMod }, lev = {...} }`.
- **The clone:** `gu.handler(a)` = `a.character:get_Human()["<Job09ActionCtrl>k__BackingField"]["<DecoyHandler>k__BackingField"]`;
  `gu.prepare`: `h:call("create")` if `get_Instance` is nil; then `init(false)` + `start(StartInformation)`.
- **Dress** (`gu.restyle(inst, true)`):
```lua
local ps = inst:call("get_PartSwapper")
local meta = ps:get_field("_Meta")
meta:set_field("_TopsStyle", ev("app.TopsStyle", "Tops_015"))     -- enum value by name
meta:set_field("_PantsStyle", ev("app.PantsStyle", "Pants_012"))
ps:call("requestSwap(app.PartSwapper.Parts)", ev("app.PartSwapper.Parts", "Tops"))
ps:call("requestSwap(app.PartSwapper.Parts)", ev("app.PartSwapper.Parts", "Pants"))
-- then wait until ps:get_field("_TopsAmObj") (etc.) holds the style's mesh; every other mesh: set_Enabled(false)
```
- **Follow** (`re.on_application_entry("LateUpdateBehavior")`, after the game's own update):
```lua
ctr:set_Position(p); ctr:set_Rotation(ptr:get_Rotation()); ctr:set_LocalScale(Vector3f.new(1.10, 1.04, 1.06))
gu.pairs = gu.pairs or pairs_build(playerGO, cloneGO)   -- { p = my joint, c = its joint of the same name }
for _, e in ipairs(gu.pairs) do
    e.c:call("set_LocalPosition", e.p:call("get_LocalPosition"))
    e.c:call("set_LocalRotation", e.p:call("get_LocalRotation"))
end
-- + its Hip pulled onto mine in x/z (damped, at most 0.5 m); inst:call("get_Motion"):call("set_Enabled", false) once
```
- **See-through** (`gu.ill_slots`, then every BeginRendering): for each armour mesh's materials,
  `v = m:call("getMaterialVariableIndex", mi, hash)` (hash of the name via `app.StringExtension.hash(System.String)`),
  then `m:call("setMaterialFloat", mi, v, value)` for `Illusion_Enable, Illusion_AlphaRate_Front, Illusion_AlphaRate_Rim,
  Illusion_FadeRate, Illusion_RimAlphaGrad, Illusion_NoiseBlend, DitherFadeRate, DissolveRate`.
- **Keep alive / not a lure** (`gu.alive`, every frame): `<ElapsedSecond>k__BackingField = 0`, `<IsDie>` /
  `<FinishDamage>` false, `<AttensionTimer>` 0, `<IsTargetResistered>` false, its colliders `set_Enabled(false)`.
  Hooks with `SKIP_ORIGINAL` for our clone: `app.SmokeDecoy.onOwnerDamageReaction / onOwnerCalcDamageEnd / onDamageHit /
  ...`, and `finish / vanish / sleep / requestEndEffect / triggerEndSE` on `app.CloneCharacter`, `app.DecoyHandler`.
- **Bonuses** (`gu.armour_bonus(true)`): `sd = data:call("get(app.EquipData.SlotEnum)", 3)` (Upper),
  `param = im:call("getItemData(System.Int32)", sd:get_field("_ItemId"))`; originals saved to
  `Pactblade_guise_items.json`; `_PhysicalDefence` / `_MagicDefence` + 20 % of the total; then
  `data:call("clearParam")`, `data:call("calc")`, `applyEquipDataForCharacter`.
- **Fire / poison** (1.0.1): on_frame while `gu.on`:
```lua
local sc = a.character["<StatusConditionCtrl>k__BackingField"]
local flags = sdk.to_int64(sc:call("get_ActiveStatusConditionFlagProp"))   -- bit (1 << enum) per active status
for id in pairs(REFUSE) do   -- FireSpread, OilSpread, Poison, VirulentPoison
    if (flags & (1 << id)) ~= 0 then sc:call("reqStatusConditionCure(app.StatusConditionDef.StatusConditionEnum, System.Boolean)", id, false) end
end
-- + calcDamageValue: hits on me with AttackUserData._ElementType == 1 (Fire): info.Damage * 0.5 in post
```
- **Levitate** (`gu.lev`): UpdateBehavior: in the air, `a:button_down("Jump")` held 0.25 s → `L.active = { y0, y }`;
  LateUpdateBehavior post: `F.y = min(y0 + 2.5, F.y + 1.5 * dt)`, x/z from `stick_yaw(a)` x 5 m/s, position +
  `CharaController warp`, `Character.SecFall` / `FreeFallCtrl.Frame` / `InitialFrameSpeed.y` reset each frame; ends on
  release / ground / 4 s / no stamina (60 per second via `setRemainingAmount`); `FallInfo:resetBaseHeight()` +
  `resetFallHeight()` at the end. Animations: bank 3 motions 5010 / 5000 on the FullBodyLayer (UpdateMotion).

### 4.15 Save and online guard
`G = { saveDepth, onlineDepth, stripAt }`. Pre-hooks on `app.SaveDataManager` save methods, `app.ItemManager`
`saveGameSaveData` / `saveGameSaveDataTarget` / `fillStorageSaveData` / `makeLoopSaveData`,
`app.OnlinePawnDataFormatter updatePlaydataFrom* / getEquipSnapshot* / makeToUploadValidationWork`,
`app.PawnServerController registerSupportPawn*`: the outermost one calls `strip()` = `dbg.guardHold = true`,
`sword_restore()`, the Guise chest back; the matching post (depth back to 0) calls `apply()`. An on_frame lets go after
5 s if no post came.

### 4.16 Dimension Door module (`reframework/autorun/Pactblade/DimensionDoor.lua`)
Loaded with `pcall(require, "Pactblade.DimensionDoor")`; returns `M` with `M.pactblade` (set to `live.on`), `M.draw`
(menu), `M.block` (the vocation button is the door's). Input: post-hook on `app.UserInputManager.updateInput` reads the
player's `UserInput` flag words (`ButtonOnFlags / TriggerFlags / ReleaseFlags`: JobSpecialAction = bit 29, Go = bit 18),
clears the pawn command bits while the button is held. Aim: `cast_ray` from the eyes along the camera. Camera:
post-hook on `app.MainCameraController.lateUpdate` writes `mc._CameraJoint:set_Position(...)` (over the shoulder while
aiming, the flight during the arrival). Teleport: `chara:call("warp(via.vec3, via.Quaternion, app.CharacterWarpOption)", dest, rot, ResetPosRotContext)`
inside the input hook, held 8 frames; a carried NPC warped too and its `PosRotRecorder:resetHistory()`.

### 4.17 Spell slots (1.1)
**State:** `SL = { used, max, level, rechargeAt, RECHARGE = 20, x = 0.497, y = 0.976, size, gap = 2.6, show, fade,
flash, deniedAt, SPOTS }` (`dbg.slots`), settings in `Pactblade_slots.json`.
```lua
function SL.refresh()   -- every 1 s
    SL.level = tonumber(a.character:get_Human()["<StatusContext>k__BackingField"]:call("get_Level"))
    SL.max = math.max(1, math.min(5, 1 + math.floor(SL.level / 15)))
end
function SL.use()
    if SL.used >= SL.max then return false end
    SL.fade = { idx = SL.max - SL.used, t0 = os.clock() }          -- the rightmost full one fades away
    SL.used = SL.used + 1
    if not SL.rechargeAt then SL.rechargeAt = dbg.gclock() + SL.RECHARGE end
    return true
end
-- every frame: one comes back, the next starts
if SL.rechargeAt and dbg.gclock() >= SL.rechargeAt then
    SL.used = SL.used - 1
    SL.rechargeAt = SL.used > 0 and dbg.gclock() + SL.RECHARGE or nil
    SL.flash = { idx = SL.max - SL.used, t0 = os.clock() }        -- the refilled one blooms
end
```
- **Users of slots:** `sm.press` (Smite): `if not dbg.slots.use() then dbg.slots.deny(); return end`; `gu.press`
  requires `SL.free() >= 1`; `gu.release` (the chant's end) calls `SL.use()`.
- **Greyed out:** hooks on `app.HumanSkillAvailability.isCustomSkillAvailable(app.HumanCustomSkillID)` and
  `isCustomSkillAvailableWithoutItemCondition(app.HumanCustomSkillID)`: pre: `this` must be the player's
  (`sdk.to_int64(args[2]) == live.avail`), the id (`args[3]`) one of the adapter's smite / guise VSB ids, no slot free
  → a flag in `thread.get_hook_storage()`; post: `return sdk.to_ptr(0)`.
- **Drawing** (`re.on_frame`, nothing in menus / when inactive): screen size from `imgui.get_display_size()`,
  `r = height * 0.0095 * size`, the row centred on `(x * width, y * height)`. Per slot:
```lua
draw.filled_circle(cx, cy, r * 1.14, SHADOW, 40)                     -- 0x90000000
draw.filled_circle(cx, cy, r,        RIM_DARK, 40)                   -- bevelled bronze: dark,
draw.filled_circle(cx, cy, r * 0.88, RIM_LIGHT, 40)                  -- light,
draw.filled_circle(cx, cy, r * 0.78, RIM_INNER, 40)                  -- dark
draw.filled_circle(cx, cy, r * 0.71, CORE, 40)                       -- see-through dark core
for _, g in ipairs(GEM) do draw.filled_circle(cx, cy, r * g[1], g[2], 40) end   -- violet gem, 3 shades
-- ready: a breathing halo (alpha 0.65 + 0.35 * sin(t * 2.2 + i)) and a light orbiting at r * 0.86 with a 5-dot tail
-- colours are ABGR; alpha(col, a) scales the top byte
```
  The moon phase (recharging, `p` = 0..1):
```lua
local function moon(cx, cy, g, p, col)
    local n = math.max(2, math.floor(g))
    for k = -n, n do
        local y = k / n * g
        local half = math.sqrt(g * g - y * y)
        local xt = half * (1 - 2 * p)                                 -- the terminator: an ellipse across the disk
        draw.filled_rect(cx - half, cy + y - g / n * 0.5, half - xt, g / n + 0.6, col)   -- lit from the left
    end
end
```
  Used: `SL.fade` draws the gem x(1 + 0.45 t) with alpha (1 - t) for 0.6 s; refilled: `SL.flash` two growing, fading
  circles + a bright gem for 1 s; denied: a red halo for 0.5 s.

---

## 5. Building, testing, debugging
- **Edit → check → install:** a patch script with exact text replacements (each must match exactly once), a syntax
  check with a Lua 5.4 `load()` (lupa in Python), a forward-reference check (names used before their definition),
  copy to `reframework/autorun/`, then in game: REFramework menu → ScriptRunner → Reset scripts. Paks need a restart.
- **Find things:** the il2cpp dump (types, methods with parameter types, fields, enums) - query it with a script.
  The game's message files for skill / item names. The Recorder for effects / sounds / animations.
- **Debug:** the trace (`Pactblade_trace.json`), the hit log (`Pactblade_hits.json`: per hit `before / after /
  phys / mag / rate / kind`), debug dots, the REFramework log (`re2_framework_log.txt`: Lua errors with line numbers,
  "Exception thrown in REMethodDefinition::invoke" bursts before a crash, which paks were injected).
- **Compare in the same session:** a script reset keeps game state (a created clone, a changed item). If a "new" bug
  also shows with an older version in the same session, it's state, not code.


---

## Appendix A: every hook in the script (release 1.1)

Line, the game type, the method, and the nearest comment in the code. "(dynamic / loop)" = the method is picked in a loop (every overload of a name, or one hook per type in a list); the type shown is then the nearest one named in the code - read the code at that line.

| Line | Type | Method | Comment |
|---|---|---|---|
| 287 | app.StaminaManager | add(System.Single, System.Boolean) | (4.04) a skill's own big drain swapped for our cost (dbg.stamSwap = { cost, untilT }) |
| 433 | app.HumanSkillAvailability | (dynamic / loop) | (i-0.3) during a translated press the game may use that Fighter skill (it asks for the tra |
| 451 | app.PlayerInputProcessorDetail | processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean) |  |
| 453 | app.PlayerInputProcessorDetail | processCustomSkill(app.CharacterInput.Action, app.HumanCustomSkillID, System.UInt64, app.LockOnController.Option, System.Boolean, System.Boolean, System.Boolean) |  |
| 509 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | Fighter's shield actions (Defend and the rest) are refused while Pactblade is active |
| 531 | app.HumanNormalSkillID | (dynamic / loop) | Deflect, True Deflect, Steeled Foundation, Enchanted Counter |
| 568 | app.Job04BreakFall | setMotion(System.Single) |  |
| 689 | app.ItemManager | setEquip(app.ItemDefine.StorageData, app.Character, app.EquipData.SlotEnum, System.Boolean, System.Boolean) | when a save loads); a shield already worn is reported in the menu |
| 1626 | app.ShellManager | requestCreateShell(via.GameObject, via.vec3, via.Quaternion, app.ShellRequest.ShellCreateInfo, app.ShellParamData, app.ShellRequest.EventCreateShellSuccess, app.ShellRequest.EventBeforeShellInstantiate) | the bolt animations fire Mystic Spearhand's own bolt (flinch / hold): those projectiles ar |
| 1805 | app.MaterialInterpolationRequestManager | (dynamic / loop) |  |
| 2205 | app.WwiseContainerApp | (dynamic / loop) |  |
| 2375 | via.effect.script.ObjectEffectManager2 | (dynamic / loop) |  |
| 2489 | via.effect.script.ObjectEffectManager2 | (dynamic / loop) |  |
| 2657 | app.PlayerDamageCalculator | (dynamic / loop) |  |
| 2673 | ? | (dynamic / loop) |  |
| 2868 | app.StatusConditionCtrl | reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean) | active, and one already on you is cured when Pactblade becomes active |
| 2894 | app.CharacterDamageCalculator | setElemntTypeOnEnchant(app.AttackUserData.ElementType, app.HitController.DamageInfo) | the game writes it (CharacterDamageCalculator.setElemntTypeOnEnchant) - Holy by default |
| 2912 | app.PlayerDamageCalculator | getElementTypeByEnchant(app.HitController.DamageInfo) |  |
| 2948 | via.effect.script.ObjectEffectManager2 | (dynamic / loop) |  |
| 2974 | app.MaterialInterpolationEnchant | (dynamic / loop) |  |
| 3031 | app.HitController | calcDamageValue(app.HitController.DamageInfo) |  |
| 3318 | app.WeaponAndItemHolder.WeaponSlot | (dynamic / loop) |  |
| 3474 | app.HitController | calcDamageReaction(app.HitController.DamageInfo) | stagger (knockdown) power of each blast kind: BLAST[kind].stagger x the game's value (from |
| 3500 | app.HitController | getReactionDamageType(app.HitController.DamageInfo) | FlashFlood |
| 3989 | app.PlayerInputProcessorDetail | (dynamic / loop) |  |
| 4018 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | where we leave and on us where we land (Quik Fot's sounds stay) |
| 4049 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | any other way the vanilla Cloudward / Cloudfall starts (a queued press...) is turned into  |
| 4751 | app.ShellAdditionalJob07SubNormalAttackShell | update() |  |
| 4828 | app.PlayerInputProcessorDetail | (dynamic / loop) |  |
| 4846 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla Hindsight Sweep started any other way (a queued press...) becomes Eldritch Sla |
| 4915 | app.Player | drawReticle | (4.97: the dot was VSB's own crosshair option, not the game's reticle - this stays off) |
| 5984 | soundlib.SoundContainer | (dynamic / loop) | (4.73: kept over script resets) |
| 6019 | app.PlayerAttackDefenceStatus | updateDefenceParameters(app.PlayerStatusCalculatorParameter) |  |
| 6037 | app.PlayerStatusCalculatorParameter | updateStatusConditionResistParameters(app.PlayerStatusCalculatorParameter) |  |
| 6093 | app.PlayerStatusCalculator | (dynamic / loop) |  |
| 6109 | app.StatusConditionDef.StatusConditionEnum | calcStatusConditionResistWithEquipmentAndBuff(app.StatusConditionDef.StatusConditionEnum) |  |
| 6128 | app.PlayerStatusCalculatorParameter | calcStatusConditionResistWithEquipmentAndBuff(app.PlayerStatusCalculatorParameter) |  |
| 6153 | app.PlayerBasicAttackDefenceStatus | (dynamic / loop) | (4.95: off - it only grew) |
| 6169 | app.PlayerStatusCalculatorParameter | (dynamic / loop) |  |
| 6461 | app.SmokeDecoy | (dynamic / loop) | (4.93: setTarget / setStay free again) |
| 6483 | ? | (dynamic / loop) |  |
| 6657 | app.PlayerInputProcessorDetail | (dynamic / loop) |  |
| 6665 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla skill never plays |
| 6683 | app.HumanSkillAvailability | (dynamic / loop) | a shield skill without a shield: usable for MY character while Pactblade is on |
| 7171 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | (i-0.4) a hit reaction during the chant: the cast stops, the reaction plays |
| 7549 | app.StatusConditionActionSlipDamage | setDirectDamage(System.Single, System.Boolean, app.StatusConditionInfo) | our poison hurts sk.poisonMul x as much: the game's poison ticks on enemies Caustic Brew p |
| 7582 | app.PlayerInputProcessorDetail | (dynamic / loop) | (4.05: paid when the acid pours, sk.release) |
| 7590 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla skill never plays |
| 7652 | app.DamageRagdollBlow | start(via.behaviortree.ActionArg) |  |
| 7709 | app.HitController | getReactionDamageType(app.HitController.DamageInfo) | s from the smite look's start; minus = sooner, down to the smite's start (user: a bit soon |
| 7735 | app.HitController | calcDamageReaction(app.HitController.DamageInfo) |  |
| 7791 | app.HitController | (dynamic / loop) |  |
| 8180 | app.PlayerInputProcessorDetail | (dynamic / loop) | the press of the bound skill (or, while binding, whichever skill is pressed next becomes t |
| 8195 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla skill started any other way (a queued press ...) becomes the smite too - not t |
| 8814 | app.HumanCatchProcessor | processFinishingMove(app.HitController.DamageInfo, app.Character) |  |
| 8861 | app.HumanSkillAvailability | (dynamic / loop) | used (a shield skill needs a shield); for MY character and Misty Dive's slot the answer is |
| 8884 | app.PlayerInputProcessorDetail | (dynamic / loop) |  |
| 8898 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla skill never plays |
| 9101 | app.HitController | calcDamageValue(app.HitController.DamageInfo) |  |
| 9133 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | no jump right after the Burst step (the same Jump press) |
| 9616 | via.effect.script.ObjectEffectManager2 | (dynamic / loop) |  |
| 9653 | app.HitController | getReactionDamageType(app.HitController.DamageInfo) |  |
| 9670 | app.HitController | calcDamageReaction(app.HitController.DamageInfo) |  |
| 9759 | app.PlayerInputProcessorDetail | (dynamic / loop) |  |
| 9774 | app.PlayerInputProcessorDetail | (dynamic / loop) | the vanilla skill never plays |
| 9789 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | Riotous Fury's opening (the rest of Riotous Fury) is refused |
| 10105 | app.PlayerInputProcessorDetail | (dynamic / loop) | (3.94 user: from a jump too) |
| 10120 | app.PlayerInputProcessorDetail | (dynamic / loop) | (3.94) in the air the game never gets that far: the button's own entry first (as the beam' |
| 10132 | app.ActionManager | requestActionCore(app.ActionManager.Priority, System.String, System.UInt32) | the vanilla skill started any other way = Blink Strike; while it plays, Riotous Fury's own |
| 10172 | app.HitController | calcDamageValue(app.HitController.DamageInfo) | an enemy hits me: the window opens (the attacker kept) |
| 10695 | app.StatusConditionActionEffectCallEndurance | (dynamic / loop) | (4.17) the status effect call itself: which set / provider / element |
| 10721 | via.effect.script.ObjectEffectManager2 | (dynamic / loop) | (4.15) which effects the burning target starts (to make its fire green) |
| 10951 | app.ItemManager | (dynamic / loop) | (saving triggers the builders too) |
| 10955 | app.ItemManager | (dynamic / loop) |  |
| 10964 | app.ItemManager | (dynamic / loop) |  |
| 10996 | app.CampStateBase | (dynamic / loop) |  |
| 11094 | ? | (dynamic / loop) |  |
| 11281 | app.StatusConditionCtrl | reqStatusConditionApplyCore(app.StatusConditionDef.StatusConditionEnum, app.HitController.DamageInfo, app.StatusConditionDef.RequestInfo, System.Boolean) |  |
| 11292 | app.HitController | calcDamageValue(app.HitController.DamageInfo) |  |
| 11379 | app.HumanSkillAvailability | (dynamic / loop) | (1.1) none free: the game is told Smite / Guise aren't available (greyed out like with too |

## Appendix B: every per-frame / lifecycle callback

| Line | When | Comment |
|---|---|---|
| 30 | draw_ui | (1.0: in a block - the main chunk is at its 200 locals) |
| 271 | on_frame |  |
| 305 | pre LateUpdateBehavior |  |
| 319 | pre LateUpdateBehavior | (3.99) any sudden stamina drop, with the action |
| 337 | on_frame |  |
| 457 | on_frame | while walking normally: which side matches the game's own move direction |
| 484 | script reset | the VSB pick kept over a script reset |
| 504 | on_frame |  |
| 576 | on_frame |  |
| 755 | script reset |  |
| 800 | pre UpdateBehavior |  |
| 801 | pre UpdateMotion |  |
| 802 | pre LateUpdateBehavior |  |
| 803 | post LateUpdateBehavior |  |
| 853 | pre LateUpdateBehavior | (3.77) a blast / bolt goes no further than it aims |
| 1019 | script reset |  |
| 1117 | script reset |  |
| 1432 | script reset |  |
| 1674 | pre LateUpdateBehavior |  |
| 1768 | pre LateUpdateBehavior | our blast is gone (hit or ended): the bolt stays where it was last put, right at the targe |
| 2073 | pre LateUpdateBehavior |  |
| 2171 | pre LateUpdateBehavior |  |
| 2625 | pre UpdateBehavior |  |
| 2859 | on_frame |  |
| 2860 | script reset |  |
| 3381 | pre UpdateBehavior |  |
| 3425 | pre BeginRendering |  |
| 3470 | script reset |  |
| 3653 | on_frame |  |
| 3969 | pre UpdateBehavior |  |
| 4035 | pre UpdateBehavior |  |
| 4448 | pre LateUpdateBehavior | every frame (the game may set them back) |
| 4462 | script reset |  |
| 4666 | pre LateUpdateBehavior |  |
| 4741 | pre UpdateBehavior |  |
| 4864 | on_frame |  |
| 4884 | on_frame | keep it daytime: once it gets dark (19:00-4:59), skip to 10:00 - not while a Pactblade ski |
| 4901 | post LateUpdateBehavior | (4.92) game time: real time minus menus / pauses (Hellish Rebuke's fire + cooldown, Hex) |
| 5094 | pre BeginRendering |  |
| 5155 | on_frame |  |
| 5161 | post LateUpdateBehavior | after the game's own late update: the clone stays on the spot (no following), frozen in ou |
| 5850 | pre BeginRendering |  |
| 5886 | pre BeginRendering |  |
| 6272 | script reset |  |
| 6277 | pre UpdateBehavior | (4.81) LEVITATE (Sorcerer's) while the guise is on: in the air, hold jump |
| 6360 | pre UpdateMotion |  |
| 6403 | post LateUpdateBehavior | (4.82) our float: the height, every frame |
| 6584 | pre LateUpdateBehavior |  |
| 6637 | pre UpdateBehavior |  |
| 6704 | post LateUpdateBehavior | the real end: meshes back, scale, motion, finish (the warps get the clone back) |
| 6939 | pre BeginRendering |  |
| 6951 | on_frame |  |
| 7128 | on_frame | (children first) |
| 7134 | script reset |  |
| 7203 | pre UpdateBehavior |  |
| 7281 | on_frame |  |
| 7396 | script reset |  |
| 7503 | post LateUpdateBehavior |  |
| 7527 | pre UpdateBehavior | the press: the chant starts as soon as its animations are loaded (first time: a moment) |
| 7545 | script reset |  |
| 7662 | pre LateUpdateBehavior |  |
| 7691 | on_frame | (3.52 test; 3.54: off again) |
| 7868 | pre BeginRendering | (dark / white / already ours) |
| 7928 | on_frame | (checked every 5 s: back in if the game threw them out) |
| 7975 | script reset |  |
| 8020 | pre LateUpdateBehavior |  |
| 8055 | pre LateUpdateBehavior | (4.02 user: a hit gives 20 % of max stamina back - after the Arc's full drain) |
| 8066 | post LateUpdateBehavior | (as DragonCore's consume_stamina, with + instead of -) |
| 8157 | pre UpdateBehavior |  |
| 8164 | script reset |  |
| 8613 | pre UpdateBehavior | (its landing is part of it; then it is over) |
| 8625 | pre LateUpdateBehavior | (3.51) moved far right after the landing? noted |
| 8639 | post LateUpdateBehavior | (the lock again after the game moved us this frame) |
| 8771 | pre LateUpdateBehavior |  |
| 8792 | pre BeginRendering | my body glow (SkyDive's rim light) in our colour |
| 8954 | script reset | (our solid pink copies, brightness 1-3) |
| 9032 | pre LateUpdateBehavior | the X: two diagonals through the enemy's chest, turned to the camera, following it |
| 9121 | on_frame | debug dots for placing the X |
| 9148 | pre UpdateBehavior | the Burst step, at the same point as the combo's warps |
| 9250 | script reset |  |
| 9501 | pre UpdateBehavior |  |
| 9509 | pre LateUpdateBehavior | the beam itself, every frame: from the palm to the target, growing, then thinning out |
| 9595 | on_frame | placement dots: green = palm, red = beam tip, yellow = the mesh beam's anchor |
| 9871 | script reset |  |
| 10074 | pre UpdateMotion |  |
| 10075 | post UpdateMotion |  |
| 10076 | pre LateUpdateBehavior |  |
| 10077 | post LateUpdateBehavior |  |
| 10078 | pre BeginRendering |  |
| 10079 | pre UpdateBehavior |  |
| 10387 | on_frame |  |
| 10511 | pre BeginRendering |  |
| 10545 | pre BeginRendering |  |
| 10579 | pre LateUpdateBehavior | (4.26) its flames: the burning one's own effect players |
| 10652 | pre LateUpdateBehavior | (4.18) its burning effects get our green files |
| 10684 | pre LateUpdateBehavior | (4.15) the fire after the flinch |
| 10781 | pre LateUpdateBehavior | (4.14) the flash's material mode ends |
| 10787 | pre LateUpdateBehavior | the sparks follow the palm, then go |
| 10797 | pre UpdateBehavior |  |
| 10822 | on_frame | (4.13) the Mage cast bank (9112) kept on me while Pactblade is on |
| 10834 | pre UpdateMotion | the clip on the layer, at our time (AnimPlayer's way) |
| 10975 | script reset |  |
| 10978 | on_frame | lets go by itself after 5 s - a save / an upload build takes far less |
| 11231 | post LateUpdateBehavior |  |
| 11260 | on_frame | every new one noted by name |
| 11428 | on_frame |  |
| 11489 | draw_ui |  |
