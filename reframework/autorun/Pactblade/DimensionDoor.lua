-- Dimension Door for Pactblade (Dragon's Dogma 2, REFramework). Based on the standalone Dimension Door 0.8.5.
-- Loaded by Pactblade.lua (require "Pactblade.DimensionDoor"); not an autorun script of its own.
-- Hold the Vocation Action button + give Go! (gamepad default: R1 + d-pad up), or press the key (default B):
-- aim - a pillar of frost light marks the spot; press again: the door opens next to you; walk through it.
-- Press once more to close an open door. Works while Pactblade is active (option: with every vocation).
-- Needs _ScriptCore (autorun/_SharedCore) for the ground checks.
local M = { pactblade = function() return false end }
local VERSION = "pb-0.1 (from 0.8.5)"
local CONFIG_FILE = "Pactblade_DimensionDoor.json"
local LOG_FILE = "Pactblade_DimensionDoor_log.json"
local FT = 0.3048

local DEFAULTS = {
    enabled = true,
    key = 0x42,             -- B
    pad_combo = true,       -- hold Vocation Action + Go! (default R1 + d-pad up); pawn commands blocked meanwhile
    cast_anim = true,       -- Mage spell-casting animation while aiming
    max_ft = 500,
    door_time = 60,         -- an open door closes by itself after this many seconds
    door_offset = -0.4,     -- the door's look moved up/down (m); the spot you walk through stays at your feet
    sounds = true,
    cutscene = true,        -- arrival scene; off = plain instant teleport
    fly_time = 1.6,         -- camera flight to the destination (s)
    glow_fill = true,       -- soft glow inside the door frame
    glow_scale = 1.0,       -- its size
    glow_y = 0.10,          -- its height within the door (0 = bottom, 1 = top)
    fill_wisps = 6,         -- frost wisps inside the doorway (0 = frame only)
    wisp_w = 1.22,          -- wisps stretched sideways
    wisp_h = 1.10,          -- wisps stretched upward
    door_style = 1,         -- 1 = shimmer frame + wisps + glow, 2 = classic (shimmer frame only, v0.8.2)
    all_vocations = false,  -- (Pactblade) also when Pactblade isn't active
    aim_cam = true,         -- (Pactblade) camera up / over the shoulder while aiming
    aim_up = 0.8, aim_right = 0.6, aim_back = 0.0,
    pillar = true,          -- (Pactblade) the target pillar
    pillar_h = 7.0, pillar_step = 0.45, pillar_ring = 3, pillar_r = 0.2,
    sparks = true,          -- the old target sparks too
}

-- fixed settings
local EYE_HEIGHT = 1.6
local DOOR_DISTANCE, DOOR_WIDTH, DOOR_HEIGHT = 2.5, 1.4, 2.44 -- metres (8 ft door)
local DOOR_POINTS = 20         -- shimmer pieces around the frame
local TURN_TIME = 1.1          -- camera swing round behind the character at the end (s)
local WALK_STRENGTH, WALK_TIMEOUT = 0.45, 1.0
local GROUND_LAYERS = { 2, 23, 24 } -- 2 = open world; 23/24 = town ground and buildings
-- { DataContainerIndex, ContainerID, ElementID } - Fangtooth's effects
local SPARK_EFX, BURST_EFX, DOOR_EFX = { 14, 7, 11 }, { 13, 0, 10 }, { 14, 7, 10 }
local ARRIVE_EFX = { { 14, 7, 11 }, { 13, 0, 10 } }
local OPEN_SOUND, ARRIVE_SOUND = 1717783091, 2823464530
local TRAVEL_SOUND = 249171544   -- the port crystal / ferrystone warp, during the camera flight

local function copy(v)
    if type(v) ~= "table" then return v end
    local t = {}
    for k, x in pairs(v) do t[k] = copy(x) end
    return t
end
local config = json.load_file(CONFIG_FILE)
if type(config) ~= "table" then   -- first run: the standalone mod's choices (key, range, door time, look)
    config = {}
    local old = json.load_file("DimensionDoor.json")
    if type(old) == "table" then
        for _, k in ipairs({ "key", "max_ft", "door_time", "door_style" }) do config[k] = old[k] end
    end
end
local USER_SETTINGS = { key = true, max_ft = true, door_time = true, door_style = true, enabled = true, all_vocations = true,
    aim_cam = true, aim_up = true, aim_right = true, aim_back = true, pillar = true, pillar_h = true, pillar_step = true,
    pillar_ring = true, pillar_r = true, sparks = true }   -- the menu's settings
for k, v in pairs(DEFAULTS) do
    if config[k] == nil or not USER_SETTINGS[k] then config[k] = copy(v) end    -- the rest: always the defaults
end
for k in pairs(config) do if DEFAULTS[k] == nil then config[k] = nil end end -- drop settings of test versions
local function save_config() json.dump_file(CONFIG_FILE, config) end

local log = json.load_file(LOG_FILE)
if type(log) ~= "table" then log = {} end
local lastMsg = "none yet"
local function event(msg)
    lastMsg = msg
    table.insert(log, os.date("%H:%M:%S") .. " " .. msg)
    while #log > 60 do table.remove(log, 1) end
    pcall(json.dump_file, LOG_FILE, log)
end
event("--- loaded v" .. VERSION .. " ---")

local function active()
    if not config.enabled then return false end
    if config.all_vocations then return true end
    local ok, on = pcall(M.pactblade)
    return ok and on == true
end

local function player()
    local cm = sdk.get_managed_singleton("app.CharacterManager")
    local p = cm and cm["<ManualPlayer>k__BackingField"]
    if p and p:get_Valid() then return p end
end

local function transform_of(chara)
    local tr = chara["<Transform>k__BackingField"]
    if tr then return tr end
    return chara:get_GameObject():get_Transform()
end

local function flat_dir(x, z)
    local len = math.sqrt(x * x + z * z)
    if len < 0.0001 then return nil end
    return x / len, z / len, len
end

local function forward_of(q)
    return 2 * (q.x * q.z + q.w * q.y), 1 - 2 * (q.x * q.x + q.y * q.y)
end

local function yaw_rotation(dx, dz)
    local yaw = math.atan(dx, dz)
    return Quaternion.new(math.cos(yaw / 2), 0, math.sin(yaw / 2), 0)
end

local function camera_forward()
    local m = sdk.get_primary_camera():get_WorldMatrix()
    return flat_dir(-m[2].x, -m[2].z)
end

------------------------------------------------------------------------
-- effects and sounds
------------------------------------------------------------------------
local function is_type(td, typeName)
    while td do
        if td:get_full_name() == typeName then return true end
        td = td:get_parent_type()
    end
    return false
end

local function components_of(go, typeName)
    local found = {}
    pcall(function()
        for _, c in ipairs(go:call("get_Components"):get_elements()) do
            if is_type(c:get_type_definition(), typeName) then found[#found + 1] = c end
        end
    end)
    return found
end

-- borrowed skill effects don't end on their own: every one we start is finished after its life time
local liveEfx = {} -- { container, untilT }
local function finish_effect(container)
    for _, m in ipairs({ "finishAll", "finish", "killAll", "kill" }) do
        if pcall(function() container:call(m .. "()") end) then return true end
    end
    return false
end

re.on_frame(function()
    if #liveEfx == 0 then return end
    local now = os.clock()
    for i = #liveEfx, 1, -1 do
        if now >= liveEfx[i].untilT then
            pcall(finish_effect, liveEfx[i].container)
            table.remove(liveEfx, i)
        end
    end
end)

local function play_efx(p, ids, pos, rot, life)
    for _, mgr in ipairs(components_of(p:get_GameObject(), "via.effect.script.ObjectEffectManager2")) do
        local ok, res = pcall(function()
            local effectId = sdk.create_instance("via.effect.script.EffectID")
            effectId.DataContainerIndex = ids[1]
            effectId.ContainerID = ids[2]
            effectId.ElementID = ids[3]
            effectId.IsContainerIDOnly = false
            effectId.IsElementIDOnly = false
            return mgr:call("requestEffect(via.effect.script.EffectID, via.vec3, via.Quaternion, via.GameObject, System.String, via.effect.script.EffectManager.WwiseTriggerInfo)",
                effectId, pos, rot or Quaternion.new(1, 0, 0, 0), nil, "root", nil)
        end)
        if ok and res then
            pcall(function() liveEfx[#liveEfx + 1] = { container = res:add_ref(), untilT = os.clock() + (life or 1.0) } end)
            return true
        end
    end
    return false
end

-- the Frost Boon "shimmer": the Stalwart Sword's frost enchant effect file, played on a standalone
-- via.effect.EffectPlayer on each of the door's anchor objects - no weapon or enchant needed. It loops until the
-- anchor is destroyed when the door closes. Fallback: ElementID 25 from the held weapon's own effect list.
local SHIMMER_EFX = "vfx/effects/weapon/wp00/009/13_wp00_009_enchant_25.efx"
-- the glow inside the door: a cutscene light-aura effect from the game, re-started while the door is open
local GLOW_EFX = "vfx/event/effects/cutscene/cs0220/s20/13_cs0220_s20_env_main02_glow_00.efx"
local GLOW_REPEAT = 4.0
local efxRes = {}
local function efx_player(parentGo, path)
    if not efxRes[path] then
        local res = sdk.create_resource("via.effect.EffectResource", path)
        if not res then return nil end
        efxRes[path] = res:add_ref()
    end
    local holder = efxRes[path]:create_holder("via.effect.EffectResourceHolder")
    if not holder then return nil end
    holder = holder:add_ref()
    local ep = parentGo:call("createComponent(System.Type)", sdk.typeof("via.effect.EffectPlayer"))
    if not ep then return nil end
    ep = ep:add_ref()
    ep:call("set_Resource", holder)
    pcall(function() ep:call("set_AutoStart", true) end)
    return ep
end

local function weapon_fx_mgr(p)
    local w = p._WeaponElementController:call("getWeapon(System.Boolean)", false)
    local go = w and w:get_GameObject()
    return go and go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
end

local function shimmer_on(p, parentGo)
    local okP, ep = pcall(efx_player, parentGo, SHIMMER_EFX)
    if okP and ep then return ep end
    local ok, res = pcall(function()
        local mgr = weapon_fx_mgr(p)
        if not mgr then return nil end
        local eid = sdk.create_instance("via.effect.script.EffectID")
        eid.DataContainerIndex = -1
        eid.ContainerID = 0
        eid.ElementID = 25
        eid.IsContainerIDOnly = false
        eid.IsElementIDOnly = false
        return mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
            eid, parentGo, -1, nil)
    end)
    if ok and res then return res:add_ref() end
    return nil
end

-- frost wisps (Frost Boon's floating particles) inside the door. The wisps only show when a weapon's own effect
-- manager creates them (played from their file they stay invisible, even with the weapon's settings), so the door
-- borrows one: a Stalwart Sword spawned from the game's weapon catalog (app.EquipmentManager.requestInstantiate),
-- kept hidden and reused; its effect manager plays element 20 on the door's anchors. Falls back to the held weapon.
local DONOR_WEAPON = 3368873434   -- app.WeaponID of the Stalwart Sword (wp00_009)
local donor = nil                 -- { go, mgr, ours }
local function donor_mgr(p)
    if donor then
        local alive = false
        pcall(function() alive = donor.go:get_Name() ~= nil and donor.mgr ~= nil end)
        if alive then return donor.mgr end
        donor = nil
    end
    local owner = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, "DimensionDoor_donor", 0):add_ref()
    owner:call(".ctor"); owner:set_Name("DimensionDoor_donor")
    pcall(function()
        local pos = p:get_GameObject():get_Transform():get_Position()
        owner:get_Transform():set_Position(Vector3f.new(pos.x, pos.y - 50, pos.z))    -- out of sight
    end)
    local em = sdk.get_managed_singleton("app.EquipmentManager")
    em:call("requestInstantiate(app.WeaponID, via.Component, System.Action`1<app.PrefabInstantiateResults>, System.Func`2<app.PrefabInstantiateArgs.DummyArg2,System.Boolean>)",
        DONOR_WEAPON, owner:get_Transform(), nil, nil)
    local scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    local go = scene:call("findGameObject(System.String)", "wp00_009_00")
    if not go then return nil end
    go = go:add_ref()
    local mgr = go:call("getComponent(System.Type)", sdk.typeof("via.effect.script.ObjectEffectManager2"))
    if not mgr then return nil end
    -- ours = spawned under our owner object (not someone's real Stalwart Sword): hide it
    local ours = false
    pcall(function() ours = go:get_Transform():call("get_Parent") == owner:get_Transform() end)
    if ours then pcall(function() go:call("set_DrawSelf", false) end) end
    donor = { go = go, mgr = mgr:add_ref(), ours = ours, owner = owner }
    event("wisps donor sword ready (" .. (ours and "spawned, hidden" or "existing sword reused") .. ")")
    return donor.mgr
end

local function wisps_on(p, parentGo)
    local ok, res = pcall(function()
        local okD, mgr = pcall(donor_mgr, p)
        if not okD or not mgr then mgr = weapon_fx_mgr(p) end
        if not mgr then return nil end
        local eid = sdk.create_instance("via.effect.script.EffectID")
        eid.DataContainerIndex = -1; eid.ContainerID = 0; eid.ElementID = 20
        eid.IsContainerIDOnly = false; eid.IsElementIDOnly = false
        return mgr:call("requestEffect(via.effect.script.EffectID, via.GameObject, System.Int32, via.effect.script.EffectManager.WwiseTriggerInfo)",
            eid, parentGo, -1, nil)
    end)
    if ok and res then return res:add_ref() end
    return nil
end

local function make_anchor(name, pos, rot)
    local go = sdk.find_type_definition("via.GameObject"):get_method("create(System.String, via.Folder)"):call(nil, name, 0)
    go = go:add_ref()
    go:call(".ctor")
    go:set_Name(name)
    local tr = go:get_Transform()
    tr:set_Position(pos)
    if rot then tr:set_Rotation(rot) end
    return go
end

------------------------------------------------------------------------
-- (Pactblade) the target pillar: the door's frost shimmer stacked into a tall column (rings of a few pieces every
-- pillar_step metres), moved with the aim. No light (the old target light cost performance and blinded up close).
------------------------------------------------------------------------
local pillar -- { items = { { go, off } }, cur, key }
local function pillar_off()
    if not pillar then return end
    for _, it in ipairs(pillar.items) do pcall(function() it.go:call("destroy(via.GameObject)", it.go) end) end
    pillar = nil
end
local function pillar_key()
    return ("%.2f/%.2f/%d/%.2f"):format(config.pillar_h, config.pillar_step, math.floor(config.pillar_ring), config.pillar_r)
end
local function pillar_at(base, dt)
    if not config.pillar then pillar_off(); return end
    local key = pillar_key()
    if pillar and pillar.key ~= key then pillar_off() end
    if not pillar then
        pillar = { items = {}, cur = base, key = key }
        local n = math.max(1, math.floor(config.pillar_h / math.max(0.1, config.pillar_step) + 0.5))
        local ring = math.max(1, math.floor(config.pillar_ring))
        for i = 0, n - 1 do
            for j = 0, ring - 1 do
                local ang = (j + (i % 2) * 0.5) / ring * 2 * math.pi
                local off = { math.cos(ang) * config.pillar_r, i * config.pillar_step, math.sin(ang) * config.pillar_r }
                local ok, go = pcall(make_anchor, "DimensionDoor_pillar", Vector3f.new(base.x + off[1], base.y + off[2], base.z + off[3]))
                if ok and go then
                    pillar.items[#pillar.items + 1] = { go = go, off = off }
                    pcall(efx_player, go, SHIMMER_EFX)
                end
            end
        end
    end
    local c = pillar.cur
    local dx, dy, dz = base.x - c.x, base.y - c.y, base.z - c.z
    if dx * dx + dy * dy + dz * dz > 15 * 15 then c = base   -- a big jump: straight there
    else
        local k = math.min(1, dt * 14)
        c = Vector3f.new(c.x + dx * k, c.y + dy * k, c.z + dz * k)
    end
    pillar.cur = c
    for _, it in ipairs(pillar.items) do
        pcall(function() it.go:get_Transform():set_Position(Vector3f.new(c.x + it.off[1], c.y + it.off[2], c.z + it.off[3])) end)
    end
end

local function finish_door(d)
    if not d then return end
    if d.remote then finish_door(d.remote) end
    for _, c in ipairs(d.fx or {}) do pcall(finish_effect, c) end
    for _, go in ipairs(d.gos or {}) do pcall(function() go:call("destroy(via.GameObject)", go) end) end
    for _, gl in ipairs(d.glows or {}) do pcall(function() gl.go:call("destroy(via.GameObject)", gl.go) end) end
    d.fx, d.gos, d.glows, d.wispGos, d.wispScaled = nil, nil, nil, nil, nil
end

local function trigger_in(go, triggerId)
    for _, sc in ipairs(components_of(go, "soundlib.SoundContainer")) do
        local ok, done = pcall(function()
            for _, info in pairs(sc._TriggerInfoList._items) do
                if info and info._TriggerId == triggerId then
                    local req = sc:call("createRequestInfo(soundlib.SoundTriggerInfo, via.GameObject, via.GameObject, System.UInt32, System.Boolean, System.Boolean, System.UInt32, via.simplewwise.CallbackType, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>, System.Action`1<soundlib.SoundManager.RequestInfo>)",
                        info, go, go, info._OffsetJointHash, false, false, 0, 0, nil, nil, nil, nil)
                    if req then
                        req = req:add_ref()
                        req["<Container>k__BackingField"] = sc
                        sc:call("trigger(soundlib.SoundManager.RequestInfo)", req)
                        return true
                    end
                end
            end
            return false
        end)
        if ok and done then return true end
    end
    return false
end

-- the player's own sound containers first, then the game's resident sound objects (e.g. the port crystal warp)
local SOUND_OBJECTS = { "SoundResident", "UI_Sound" }
local function play_sound(p, triggerId)
    if not config.sounds then return false end
    if trigger_in(p:get_GameObject(), triggerId) then return true end
    local scene
    pcall(function()
        scene = sdk.call_native_func(sdk.get_native_singleton("via.SceneManager"), sdk.find_type_definition("via.SceneManager"), "get_CurrentScene()")
    end)
    if not scene then return false end
    for _, name in ipairs(SOUND_OBJECTS) do
        local go
        pcall(function() go = scene:call("findGameObject(System.String)", name) end)
        if go and trigger_in(go, triggerId) then return true end
    end
    return false
end

-- collision checks: _ScriptCore's cast_ray. Open-world terrain answers sphere casts, town ground thin rays;
-- quest volumes, trigger areas and characters are skipped by name.
------------------------------------------------------------------------
local castOk, shared = pcall(require, "_SharedCore/Functions")
local cast_ray = castOk and type(shared) == "table" and shared.cast_ray or nil

local SKIP_NAMES = { "^Resource_", "^ch%d", "Area", "Trigger", "Sensor", "Volume", "Sound", "Wwise", "Event" }
local function skipped(go)
    local name = "?"
    pcall(function() name = go:get_Name() end)
    for _, pat in ipairs(SKIP_NAMES) do if name:find(pat) then return true end end
    return false
end

-- the first surface below a start point: every variant tried, the highest surface below the start wins
local function ground_near(x, y, z, up, down)
    local from, to = Vector3f.new(x, y + up, z), Vector3f.new(x, y - down, z)
    local best
    for _, layer in ipairs(GROUND_LAYERS) do
        for _, opt in ipairs({ 1, 0 }) do
            for _, radius in ipairs({ 0.1, false }) do
                local ok, res = pcall(function()
                    if radius then return cast_ray(from, to, layer, 0, radius, opt) end
                    return cast_ray(from, to, layer, 0)
                end)
                if ok and res then
                    for _, r in ipairs(res) do
                        local q = r[2]
                        if q and q.y <= from.y + 0.05 and (not best or q.y > best.y) and not skipped(r[1]) then
                            best = Vector3f.new(q.x, q.y, q.z)
                        end
                    end
                end
            end
        end
    end
    return best
end

-- the nearest real surface along a line: thin rays on every ground layer (town ground answers these) AND one
-- sphere cast on the open-world layer (terrain answers only spheres); the nearest hit wins. Both always run: with
-- the sphere only as a fallback, a ray through a hill hit something behind it and the target ended up under the map.
local function first_hit(from, to)
    local best, bestD
    for pass = 1, 2 do
        for _, layer in ipairs(pass == 1 and GROUND_LAYERS or { 2 }) do
            local ok, res = pcall(function()
                if pass == 2 then return cast_ray(from, to, layer, 0, 0.15, 1) end
                return cast_ray(from, to, layer, 0)
            end)
            if ok and res then
                for _, r in ipairs(res) do
                    local q = r[2]
                    if q and not skipped(r[1]) then
                        local d = (q.x - from.x) ^ 2 + (q.y - from.y) ^ 2 + (q.z - from.z) ^ 2
                        if d > 0.04 and (not bestD or d < bestD) then best, bestD = Vector3f.new(q.x, q.y, q.z), d end
                    end
                end
            end
        end
    end
    return best, bestD and math.sqrt(bestD)
end

------------------------------------------------------------------------
-- the spell
------------------------------------------------------------------------
-- state: nil | "aiming" { b = beam, ... } | "door" { dest, rot, center, nx, nz, side, untilT, air, airDoor }
local state, s = nil, nil
local cast_cancel, open_door -- defined further down

local function cancel(why)
    pillar_off()
    if cast_cancel then cast_cancel() end
    finish_door(s)
    state, s = nil, nil
    event(why)
end

-- where the beam goes now: from the eyes toward what the camera centre points at
local function beam_now(p)
    local m = sdk.get_primary_camera():get_WorldMatrix()
    local cpos = Vector3f.new(m[3].x, m[3].y, m[3].z)
    local fx, fy, fz = -m[2].x, -m[2].y, -m[2].z
    local pos = transform_of(p):get_Position()
    local eye = Vector3f.new(pos.x, pos.y + EYE_HEIGHT, pos.z)
    local maxd = config.max_ft * FT
    -- aim point: the camera ray, started level with the character (not from behind it)
    local t0 = math.max(0, (eye.x - cpos.x) * fx + (eye.y - cpos.y) * fy + (eye.z - cpos.z) * fz)
    local a = Vector3f.new(cpos.x + fx * t0, cpos.y + fy * t0, cpos.z + fz * t0)
    local far = Vector3f.new(a.x + fx * maxd, a.y + fy * maxd, a.z + fz * maxd)
    local aim = first_hit(a, far) or far
    local dx, dy, dz = aim.x - eye.x, aim.y - eye.y, aim.z - eye.z
    local len = math.sqrt(dx * dx + dy * dy + dz * dz)
    if len < 0.01 then return nil end
    dx, dy, dz = dx / len, dy / len, dz / len
    local endp = Vector3f.new(eye.x + dx * maxd, eye.y + dy * maxd, eye.z + dz * maxd)
    local hit, hd = first_hit(eye, endp)
    return { eye = eye, dx = dx, dy = dy, dz = dz, endp = hit or endp, hit = hit ~= nil, dist = hit and hd or maxd }
end

-- the landing spot: just short of what the beam hit, onto the ground if there is ground right below, otherwise
-- in the air (you fall). A mid-air spot with solid ground ABOVE it (within 80 m) is under something - usually
-- under the map, where the aim slipped through ground the casts don't see - so it is moved up onto that surface.
-- Nothing below for 400 m -> nil (the spell fizzles).
-- v0.7.8: a landing on the ground must also be reachable: a clear line from the beam's own (open-air) path to the
-- spot at chest height, and head room. Otherwise (e.g. the beam hit a rock's side and the ground found below was
-- the terrain INSIDE the rock) we step back along the beam and try again.
local BACK_STEPS = { 0.6, 1.5, 3.0, 5.0, 8.0 }
local function reachable(from, g)
    local chest = Vector3f.new(g.x, g.y + 1.0, g.z)
    if first_hit(from, chest) then return false end
    return not first_hit(Vector3f.new(g.x, g.y + 0.4, g.z), Vector3f.new(g.x, g.y + 1.9, g.z))
end

local function landing(b)
    local back = b.hit and 0.6 or 0
    local dest = Vector3f.new(b.endp.x - b.dx * back, b.endp.y - b.dy * back, b.endp.z - b.dz * back)
    local g = ground_near(dest.x, dest.y, dest.z, 0.8, 2.0)
    if g and b.hit then
        local tries = 0
        for _, k in ipairs(BACK_STEPS) do
            if k >= b.dist then break end
            local bp = Vector3f.new(b.endp.x - b.dx * k, b.endp.y - b.dy * k, b.endp.z - b.dz * k)
            local gk = ground_near(bp.x, bp.y, bp.z, 0.8, 2.0)
            if gk and reachable(bp, gk) then
                if tries > 0 then event(string.format("landing was enclosed (inside a rock?) - stepped back %.1f m", k)) end
                return gk, false, gk.y
            end
            tries = tries + 1
        end
        event("no reachable landing near the target - spell fizzled")
        return nil, "no reachable landing"
    end
    if g then return g, false, g.y end
    local top = ground_near(dest.x, dest.y + 80, dest.z, 0.0, 79.0)
    if top then
        event(string.format("landing was under a surface %.1f m above (under the map?) - moved up onto it", top.y - dest.y))
        return top, false, top.y
    end
    local below = ground_near(dest.x, dest.y, dest.z, 0.0, 400.0)
    if not below then return nil, "nothing below for 400 m" end
    return dest, true, below.y
end

------------------------------------------------------------------------
-- casting animation: the Mage's shared spell-casting set from the staff motlist ch00_006_atk - 700
-- attackspelling_start (60 f) -> 701 attackspelling_chant1 (230 f, looped) while aiming, 750
-- spellstock_release_A1 (45 f) when the target is locked. The motlist is added to the player as a dynamic motion
-- bank; the player's animation state machine (MotionFsm2) is paused while casting so it can't switch the motion
-- away. Movement is locked while aiming (the camera stays free).
------------------------------------------------------------------------
local CAST_BANK, CAST_PATH = 9112, "animation/ch/ch00/motlist/ch00_006_atk.motlist"
local CAST = { start = { id = 700, len = 60 }, loop = { id = 701, len = 230 }, release = { id = 750, len = 45 } }
local CHANGE = "changeMotion(System.UInt32, System.UInt32, System.Single, System.Single, via.motion.InterpolationMode, via.motion.InterpolationCurve)"
local cast -- { phase = "start" | "loop" | "release", t, prev = {bank, id} }
local aimLock = false -- movement + buttons zeroed (camera stick left alone) while casting
local castInfo, nextBankTry = "not loaded yet", 0

local function cast_bank_ready(p)
    local info = sdk.create_instance("via.motion.MotionInfo", true)
    return p:get_Motion():call("getMotionInfo(System.UInt32, System.UInt32, via.motion.MotionInfo)", CAST_BANK, CAST.loop.id, info)
end

-- added once, and again if the game rebuilt the player's motion (e.g. on equipment changes)
local function ensure_cast_bank(p)
    local mo = p:get_Motion()
    for i = 0, mo:getDynamicMotionBankCount() - 1 do
        local b = mo:getDynamicMotionBank(i)
        if b and b:get_BankID() == CAST_BANK then return end
    end
    local holder = sdk.create_resource("via.motion.MotionListResource", CAST_PATH):add_ref()
        :create_holder("via.motion.MotionListResourceHolder"):add_ref()
    local n = mo:getDynamicMotionBankCount()
    mo:setDynamicMotionBankCount(n + 1)
    local bank = sdk.create_instance("via.motion.DynamicMotionBank"):add_ref()
    bank:set_MotionList(holder)
    bank:set_OverwriteBankID(true)
    bank:set_BankID(CAST_BANK)
    mo:setDynamicMotionBank(n, bank)
    castInfo = "loading"
end

local fsmPaused
local function pause_fsm(p, on)
    pcall(function()
        if on then
            local fsm = p:get_GameObject():call("getComponent(System.Type)", sdk.typeof("via.motion.MotionFsm2"))
            if fsm then fsm:call("set_Paused", true); fsmPaused = fsm:add_ref() end
        elseif fsmPaused then
            fsmPaused:call("set_Paused", false)
            fsmPaused = nil
        end
    end)
end

local function cast_play(p, m, interp)
    p:get_Motion():getLayer(0):call(CHANGE, CAST_BANK, m.id, 0.0, interp or 10.0, 1, 1)
end

local function cast_begin(p)
    if not config.cast_anim then return end
    local ok, err = pcall(function()
        ensure_cast_bank(p)
        if not cast_bank_ready(p) then castInfo = "animations still loading - retrying"; return end
        local l = p:get_Motion():getLayer(0)
        cast = { phase = "start", t = os.clock(), prev = { l:get_MotionBankID(), l:get_MotionID() } }
        aimLock = true
        cast_play(p, CAST.start, 8.0)
        pause_fsm(p, true)
        castInfo = "casting"
    end)
    if not ok then castInfo = "error: " .. tostring(err); event("casting animation: " .. castInfo); cast, aimLock = nil, false end
end

-- back to whatever was playing before (idle), animation logic and movement back
local function cast_end(p)
    if not cast then return end
    pcall(function() p:get_Motion():getLayer(0):call(CHANGE, cast.prev[1], cast.prev[2], 0.0, 12.0, 1, 1) end)
    pause_fsm(p, false)
    cast, aimLock, castInfo = nil, false, "idle"
end

local function cast_release(p)
    if not cast then return end
    pcall(cast_play, p, CAST.release, 6.0)
    cast.phase, cast.t = "release", os.clock()
    aimLock = false
end

local function face_camera(p)
    local dx, dz = camera_forward()
    if not dx then return end
    local yaw = math.atan(dx, dz)
    pcall(function()
        local tac = p["<TargetAngleCtrl>k__BackingField"]
        tac.Front["<AngleDeg>k__BackingField"] = math.deg(yaw)
        tac.Move["<AngleDeg>k__BackingField"] = math.deg(yaw)
    end)
    transform_of(p):set_Rotation(yaw_rotation(dx, dz))
end

-- every update while casting: keep our motion on layer 0, start -> loop, loop the chant, end after the release
local function cast_update(p)
    if not cast then return end
    local ok, err = pcall(function()
        local l = p:get_Motion():getLayer(0)
        local bank, id, f = l:get_MotionBankID(), l:get_MotionID(), l:get_Frame()
        local m = CAST[cast.phase]
        if cast.phase == "release" then
            if bank ~= CAST_BANK or id ~= m.id or f >= m.len - 1 or os.clock() - cast.t > 2.0 then
                pause_fsm(p, false)
                cast, castInfo = nil, "idle"
            end
            return
        end
        face_camera(p)
        if bank ~= CAST_BANK or id ~= m.id then
            if cast.phase == "start" and os.clock() - cast.t > 1.8 then cast.phase, m = "loop", CAST.loop end
            cast_play(p, m, 6.0)
        elseif f >= m.len - 2 then
            cast.phase = "loop"
            cast_play(p, CAST.loop, 10.0)
        end
    end)
    if not ok then event("casting animation error: " .. tostring(err)); cast_end(p) end
end

cast_cancel = function()
    local p = player()
    if p and cast and cast.phase ~= "release" then cast_end(p) end
end

-- a hit reaction while aiming cancels the spell (else the paused animation logic keeps the character in the pose)
local HIT_ACTIONS = { "^Dmg", "^Caught", "Down", "Blown", "Slam", "Die", "Dead", "Stagger", "Grab" }
pcall(function()
    sdk.hook(sdk.find_type_definition("app.ActionManager"):get_method("requestActionCore(app.ActionManager.Priority, System.String, System.UInt32)"),
        function(args)
            if state ~= "aiming" and not cast then return end
            pcall(function()
                local p = player(); if not p then return end
                local am = p:get_ActionManager()
                if not am or sdk.to_int64(args[2]) ~= am:get_address() then return end
                local name = sdk.to_managed_object(args[4]):ToString()
                for _, pat in ipairs(HIT_ACTIONS) do
                    if name:find(pat) then
                        if state == "aiming" then cancel("interrupted by a hit (" .. name .. ")") else cast_cancel() end
                        return
                    end
                end
            end)
        end, function(r) return r end)
end)
local lastPlayerAddr = nil

local function start(p)
    if not cast_ray then event("needs _ScriptCore (_SharedCore) - not found"); return end
    state = "aiming"
    s = { nextCast = 0, nextFx = 0, nextCastTry = os.clock() + 0.25 }
    cast_begin(p)
    play_sound(p, OPEN_SOUND)
    event("casting")
end

-- while aiming: beam every 0.15 s, sparks at the target every 0.3 s; the cast retries if its animations weren't
-- ready at the key press
local function aim_update(p)
    local now = os.clock()
    if config.cast_anim and not cast and now >= s.nextCastTry then
        s.nextCastTry = now + 0.25
        cast_begin(p)
    end
    if now >= s.nextCast then
        s.nextCast = now + 0.15
        local ok, b = pcall(beam_now, p)
        if ok and b then s.b = b elseif not ok then event("beam error: " .. tostring(b)) end
    end
    if s.b then   -- (Pactblade) the pillar, every frame
        local b, back = s.b, s.b.hit and 0.5 or 0
        local base = Vector3f.new(b.endp.x - b.dx * back, b.endp.y - b.dy * back - 0.3, b.endp.z - b.dz * back)
        local dt = math.min(0.1, now - (s.lastPillarT or now))
        s.lastPillarT = now
        pcall(pillar_at, base, dt)
    end
    if s.b and config.sparks and now >= s.nextFx then
        s.nextFx = now + 0.3
        local b, back = s.b, s.b.hit and 0.5 or 0 -- a little in front of what the beam hit
        local sp = Vector3f.new(b.endp.x - b.dx * back, b.endp.y - b.dy * back, b.endp.z - b.dz * back)
        play_efx(p, SPARK_EFX, sp, nil, 0.6)
        play_efx(p, BURST_EFX, sp, nil, 0.6)
    end
end

local function lock_beam(p)
    pillar_off()
    local b = s.b
    if not b then cancel("no target yet - spell fizzled"); return end
    local dest, air, groundY = landing(b)
    if not dest then cancel("unsafe destination (" .. tostring(air) .. ") - spell fizzled"); return end
    local dx, dz = flat_dir(b.dx, b.dz)
    if not dx then dx, dz = flat_dir(forward_of(transform_of(p):get_Rotation())) end
    s.good = { pos = dest, dist = b.dist, air = air, groundY = groundY }
    s.dx, s.dz = dx, dz
    event(string.format("target locked: %.0f ft, %s%s", b.dist / FT, b.hit and "hit a surface" or "open air",
        air and " (landing in the air)" or ""))
    cast_release(p)
    open_door(p)
end

-- the door: right next to you toward where the camera looks, at your feet height (snapped to ground within half
-- a metre, otherwise floating)
open_door = function(p)
    local pos = transform_of(p):get_Position()
    local dx, dz = camera_forward()
    dx, dz = dx or s.dx, dz or s.dz
    local center = Vector3f.new(pos.x + dx * DOOR_DISTANCE, pos.y, pos.z + dz * DOOR_DISTANCE)
    local g = ground_near(center.x, pos.y, center.z, 0.5, 0.5)
    if g then center = g end
    -- the far door (visual only): at the destination, facing back toward you - where the arrival scene's door is
    local dest = s.good.pos
    local remote = { center = Vector3f.new(dest.x - s.dx * 0.6, dest.y, dest.z - s.dz * 0.6), nx = -s.dx, nz = -s.dz }
    if not s.good.air then remote.center = ground_near(remote.center.x, dest.y, remote.center.z, 1.0, 2.0) or remote.center end
    state = "door"
    s = { dest = dest, rot = yaw_rotation(s.dx, s.dz), center = center, nx = dx, nz = dz, side = nil,
        untilT = os.clock() + config.door_time, dist = s.good.dist, air = s.good.air, airDoor = not g,
        groundY = s.good.groundY, remote = remote }
    play_sound(p, OPEN_SOUND)
    event(string.format("door opened, destination %.0f ft away", s.dist / FT))
end

-- the door's look: the frost shimmer along the frame, spawned once (it loops); Fangtooth sparks if the shimmer
-- can't be loaded
local function draw_door(p, d)
    local c0, w, h = d.center, DOOR_WIDTH / 2, DOOR_HEIGHT
    local c = Vector3f.new(c0.x, c0.y + config.door_offset, c0.z)
    local rx, rz = -d.nz, d.nx
    local rot = yaw_rotation(d.nx, d.nz)
    if d.wispGos and (d.wispScaled ~= config.wisp_w * 1000 + config.wisp_h) then   -- stretch the wisps (live)
        d.wispScaled = config.wisp_w * 1000 + config.wisp_h
        for _, go in ipairs(d.wispGos) do
            pcall(function() go:get_Transform():set_LocalScale(Vector3f.new(config.wisp_w, config.wisp_h, config.wisp_w)) end)
        end
    end
    if config.glow_fill and config.door_style == 1 then   -- glow inside the frame, re-started before it fades
        local now = os.clock()
        d.glows = d.glows or {}
        if now >= (d.nextGlow or 0) then
            d.nextGlow = now + GLOW_REPEAT
            local ok, go = pcall(make_anchor, "DimensionDoor_glow", Vector3f.new(c.x, c.y + h * config.glow_y, c.z), rot)
            if ok and go then
                pcall(function() go:get_Transform():set_LocalScale(Vector3f.new(config.glow_scale, config.glow_scale, config.glow_scale)) end)
                pcall(efx_player, go, GLOW_EFX)
                d.glows[#d.glows + 1] = { go = go, untilT = now + GLOW_REPEAT * 2 }
            end
        end
        for i = #d.glows, 1, -1 do
            if now > d.glows[i].untilT then
                pcall(function() d.glows[i].go:call("destroy(via.GameObject)", d.glows[i].go) end)
                table.remove(d.glows, i)
            end
        end
    end
    if not d.fx and not d.noShimmer then
        d.fx, d.gos = {}, {}
        local per = h * 2 + w * 2
        for i = 0, DOOR_POINTS - 1 do -- up the right side, across the top, down the left side
            local u = (i + 0.5) / DOOR_POINTS * per
            local sx, y
            if u < h then sx, y = w, u
            elseif u < h + 2 * w then sx, y = w - (u - h), h
            else sx, y = -w, h - (u - h - 2 * w) end
            local ok, go = pcall(make_anchor, "DimensionDoor_door", Vector3f.new(c.x + rx * sx, c.y + y, c.z + rz * sx), rot)
            if ok and go then
                d.gos[#d.gos + 1] = go
                local fx = shimmer_on(p, go)
                if fx then d.fx[#d.fx + 1] = fx end
            end
        end
        -- frost wisps inside the doorway: a grid of 3 columns, rows spread over the height, slightly staggered
        local n = config.door_style == 1 and math.floor(config.fill_wisps or 0) or 0
        local rows = math.ceil(n / 3)
        for k = 0, n - 1 do
            local col, row = k % 3, math.floor(k / 3)
            local sx = (col - 1) * w * 0.55
            local y = h * (row + 0.5 + (col == 1 and 0.25 or 0)) / (rows + 0.5)
            local ok, go = pcall(make_anchor, "DimensionDoor_wisp", Vector3f.new(c.x + rx * sx, c.y + y, c.z + rz * sx), rot)
            if ok and go then
                d.gos[#d.gos + 1] = go
                d.wispGos = d.wispGos or {}
                d.wispGos[#d.wispGos + 1] = go
                local fx = wisps_on(p, go)
                if fx then d.fx[#d.fx + 1] = fx end
            end
        end
        if #d.fx == 0 then finish_door(d); d.noShimmer = true end
        return
    end
    if not d.noShimmer then return end
    local now = os.clock()
    if now < (d.nextFx or 0) then return end
    d.nextFx = now + 0.8
    for i = 0, 4 do
        local y = c.y + h * i / 4
        play_efx(p, DOOR_EFX, Vector3f.new(c.x + rx * w, y, c.z + rz * w), rot, 1.0)
        play_efx(p, DOOR_EFX, Vector3f.new(c.x - rx * w, y, c.z - rz * w), rot, 1.0)
    end
    for i = -1, 1 do
        play_efx(p, DOOR_EFX, Vector3f.new(c.x + rx * w * i * 0.5, c.y + h, c.z + rz * w * i * 0.5), rot, 1.0)
    end
end

------------------------------------------------------------------------
-- teleport: app.Character.warp with CharacterWarpOption.ResetPosRotContext (the game's own instant warp; setting
-- the transform is undone by the character's position history), done during the game's input processing and
-- held for 8 frames. Afterwards the cameras are told about the warp (they don't follow long jumps otherwise).
------------------------------------------------------------------------
-- someone carried by the player (CatchController.CaughtChara) rides along, but keeps their own safe-position history
-- (PosRotRecorder): on being put down the game warps them back to it (= the pre-door spot). Warp them too, with the
-- same reset option, so their history starts at the arrival.
local carriedLogged
local function place_carried(chara, dest, rot, opt)
    local ok, e = pcall(function()
        local cc = chara:call("get_CatchController")
        local caught = cc and cc:get_field("CaughtChara")
        if not caught then return end
        caught:call("warp(via.vec3, via.Quaternion, app.CharacterWarpOption)", dest, rot, opt)
        pcall(function() caught:call("get_PosRotRecorder"):call("resetHistory()") end)
        if carriedLogged ~= caught then carriedLogged = caught; event("carried character brought along (position history reset)") end
    end)
    if not ok and carriedLogged ~= "err" then carriedLogged = "err"; event("carried character: " .. tostring(e)) end
end

local function place(chara, dest, rot)
    local ok = pcall(function()
        local opt = sdk.find_type_definition("app.CharacterWarpOption"):get_field("ResetPosRotContext"):get_data(nil)
        chara:call("warp(via.vec3, via.Quaternion, app.CharacterWarpOption)", dest, rot, opt)
        place_carried(chara, dest, rot, opt)
    end)
    if ok then return end
    local tr = transform_of(chara)
    tr:set_Position(dest)
    tr:set_Rotation(rot)
    pcall(function() chara["<CharaController>k__BackingField"]:call("warp") end)
end

local function tell_cameras()
    pcall(function() sdk.get_managed_singleton("app.CameraManager"):call("setCurrentCameraReset(app.CameraDefine.ResetOption)", 6) end)
    pcall(function()
        local sm = sdk.get_native_singleton("via.SceneManager")
        local scn = sdk.call_native_func(sm, sdk.find_type_definition("via.SceneManager"), "get_CurrentScene")
        local list = scn:call("findComponents(System.Type)", sdk.typeof("app.CameraControllerBase"))
        for i = 0, list:get_size() - 1 do
            pcall(function()
                local cc = list:get_element(i)
                cc.IsFirstProcAfterWarp = true
                cc:call("onWarpTarget()")
            end)
        end
    end)
end

local scene -- the arrival scene, see start_scene
local camOverride -- { pos, rot } written over the game camera while set
local gamePose -- the game camera's own pose this frame { pos, rot }
local walkStick -- { x, y } injected into the player's left stick while set
local pendingPlace -- { chara, dest, rot, frames, first }: done inside the input hook
local inputLocked = false -- while set, the player's buttons and sticks are zeroed every frame

local function quat(w, x, y, z) return Quaternion.new(w, x, y, z) end
local function qmul(a, b)
    return quat(a.w * b.w - a.x * b.x - a.y * b.y - a.z * b.z,
        a.w * b.x + a.x * b.w + a.y * b.z - a.z * b.y,
        a.w * b.y - a.x * b.z + a.y * b.w + a.z * b.x,
        a.w * b.z + a.x * b.y - a.y * b.x + a.z * b.w)
end
local function qlerp(a, b, t) -- normalised lerp, shortest way
    local d = a.w * b.w + a.x * b.x + a.y * b.y + a.z * b.z
    local sgn = d < 0 and -1 or 1
    local w, x, y, z = a.w + (b.w * sgn - a.w) * t, a.x + (b.x * sgn - a.x) * t, a.y + (b.y * sgn - a.y) * t, a.z + (b.z * sgn - a.z) * t
    local n = math.sqrt(w * w + x * x + y * y + z * z)
    return quat(w / n, x / n, y / n, z / n)
end
local function vlerp(a, b, t) return Vector3f.new(a.x + (b.x - a.x) * t, a.y + (b.y - a.y) * t, a.z + (b.z - a.z) * t) end
local function ease(t) t = math.max(0, math.min(1, t)) return t * t * (3 - 2 * t) end

-- a camera rotation looking from `from` at `to` (RE Engine cameras look down -Z)
local function look_rot(from, to)
    local vx, vy, vz = to.x - from.x, to.y - from.y, to.z - from.z
    local len = math.sqrt(vx * vx + vy * vy + vz * vz)
    local fx, fz = flat_dir(vx, vz)
    if not fx then fx, fz = 0, 1 end
    local pitch = math.asin(vy / len)
    return qmul(yaw_rotation(-fx, -fz), quat(math.cos(pitch / 2), math.sin(pitch / 2), 0, 0))
end

-- camera: right after MainCameraController.lateUpdate, note the game's own pose and write ours to the camera
-- joint - the very thing the game writes every frame, so its next write takes over again when we stop
local mainCam
pcall(function()
    sdk.hook(sdk.find_type_definition("app.MainCameraController"):get_method("lateUpdate"), function(args)
        mainCam = nil
        pcall(function()
            local mc = sdk.to_managed_object(args[2])
            if mc._Role == 0 then mainCam = mc end
        end)
    end, function(ret)
        if mainCam then
            pcall(function() gamePose = { pos = mainCam._Position, rot = mainCam._Rotation } end)
            if not camOverride and gamePose then pcall(M.aim_camera, mainCam) end
            if camOverride then
                pcall(function()
                    local j = mainCam._CameraJoint
                    j:set_Position(camOverride.pos)
                    j:set_Rotation(camOverride.rot)
                end)
            end
        end
        return ret
    end)
end)

-- (Pactblade) aiming: the camera up and to the right (over the shoulder), so the target at the screen centre isn't
-- behind the character's own body. Its rotation stays the game's; blended in 0.3 s, out 0.4 s.
local aimK, aimLastT = 0, nil
function M.aim_camera(mc)
    local now = os.clock()
    local dt = math.min(0.1, now - (aimLastT or now))
    aimLastT = now
    local want = (config.aim_cam and state == "aiming") and 1 or 0
    if want > aimK then aimK = math.min(1, aimK + dt / 0.3) elseif want < aimK then aimK = math.max(0, aimK - dt / 0.4) end
    if aimK <= 0 then return end
    local k = ease(aimK)
    local q, pp = gamePose.rot, gamePose.pos
    local rx, rz = flat_dir(1 - 2 * (q.y * q.y + q.z * q.z), 2 * (q.x * q.z - q.w * q.y))   -- camera right, level
    local bx, by, bz = 2 * (q.x * q.z + q.w * q.y), 2 * (q.y * q.z - q.w * q.x), 1 - 2 * (q.x * q.x + q.y * q.y)   -- camera back
    rx, rz = rx or 0, rz or 0
    local r, u, bk = config.aim_right * k, config.aim_up * k, config.aim_back * k
    mc._CameraJoint:set_Position(Vector3f.new(pp.x + rx * r + bx * bk, pp.y + u + by * bk, pp.z + rz * r + bz * bk))
end

-- walk-out: left-stick values for a world direction, relative to the game's own camera
local function stick_for(dx, dz, strength)
    local q = gamePose and gamePose.rot or sdk.get_primary_camera():get_GameObject():get_Transform():get_Rotation()
    local fx, fz = flat_dir(-(2 * (q.x * q.z + q.w * q.y)), -(1 - 2 * (q.x * q.x + q.y * q.y))) -- camera forward
    local rx, rz = flat_dir(1 - 2 * (q.y * q.y + q.z * q.z), 2 * (q.x * q.z - q.w * q.y))       -- camera right
    if not fx or not rx then return 0, strength end
    return (dx * rx + dz * rz) * strength, (dx * fx + dz * fz) * strength
end

------------------------------------------------------------------------
-- the combo (v0.8.1): hold the game's VOCATION ACTION + give the GO! command - whatever buttons those are bound
-- to (default R1 + d-pad up). The player's app.UserInput flag words have one bit per app.CharacterInput.Action:
-- Come 17, Go 18, Help 19, Wait 20 (the d-pad pawn commands), JobSpecialAction 29 (vocation action). While the
-- vocation action is held the four pawn-command bits are cleared, so the pawns get no command (like the weapon
-- skill button + d-pad switching the d-pad to item shortcuts).
------------------------------------------------------------------------
local BTN_FIELDS = { "ButtonOnFlags", "ButtonTriggerFlags", "ButtonReleaseFlags", "ButtonRepeatFlags" }
local ACT_GO, ACT_VOCATION = 1 << 18, 1 << 29
local PAWN_COMMANDS = (1 << 17) | (1 << 18) | (1 << 19) | (1 << 20)
local padComboPressed = false -- vocation action + Go! pressed; picked up by the update step
local comboHeld = false -- (Pactblade) the vocation button belongs to the door from the combo until its release
local vocationHeld, vocationSeen = false, 0

local function pad_filter(inp)
    local on = inp:get_field("ButtonOnFlags") or 0
    local trig = inp:get_field("ButtonTriggerFlags") or 0
    local rel = inp:get_field("ButtonReleaseFlags") or 0
    -- held from its press until its release: while we block input (aiming) the game stops reporting the button
    -- as held after the first frame, so "on" alone would lose it (user: couldn't close the door holding L1)
    if ((on | trig) & ACT_VOCATION) ~= 0 then vocationHeld, vocationSeen = true, os.clock() end
    if (rel & ACT_VOCATION) ~= 0 then vocationHeld = false end
    -- safety: never block the pawn commands for long if a release went unreported
    if vocationHeld and os.clock() - vocationSeen > 10.0 then vocationHeld = false end
    -- while aiming every input is blocked (so the held Vocation Action isn't reported after its first frame):
    -- Go! alone locks the target then
    if (trig & ACT_GO) ~= 0 and (vocationHeld or state == "aiming") then padComboPressed = true; comboHeld = vocationHeld end
    if not vocationHeld then comboHeld = false; return end
    for _, f in ipairs(BTN_FIELDS) do
        pcall(function() inp:set_field(f, (inp:get_field(f) or 0) & ~PAWN_COMMANDS) end)
    end
end

-- the player's input, right after the game reads the devices: gamepad combo, teleport, input lock, walk-out
local fallGuard -- { chara, groundY, untilT, saves }: see teleport
local fallReset -- { chara, frames }: see teleport
local curInput
pcall(function()
    sdk.hook(sdk.find_type_definition("app.UserInputManager"):get_method("updateInput"), function(args)
        curInput = (inputLocked or walkStick or pendingPlace or aimLock or fallGuard or fallReset or config.pad_combo) and sdk.to_managed_object(args[3]) or nil
    end, function(ret)
        if curInput then
            pcall(function()
                local p = player()
                local mine = p and p:get_Input()
                if not (mine and curInput:get_address() == mine:get_address()) then return end
                if config.pad_combo and active() then pad_filter(curInput) end
                if fallReset then
                    -- no fall damage from the height you jumped into the door at: the character's fall tracking
                    -- (app.FallInfoHolder: highest point in the air / base height) starts again at the arrival
                    pcall(function()
                        local up = transform_of(fallReset.chara):get_UniversalPosition()
                        local fi = fallReset.chara["<FallInfo>k__BackingField"]
                        fi:call("resetBaseHeight(via.Position)", up)
                        fi:call("set_HighestPositionOnAir(via.Position)", up)
                        fi:call("resetFallHeight()")
                    end)
                    fallReset.frames = fallReset.frames - 1
                    if fallReset.frames <= 0 then fallReset = nil end
                end
                if fallGuard then
                    local q = transform_of(fallGuard.chara):get_Position()
                    if q.y < fallGuard.groundY - 0.6 then
                        place(fallGuard.chara, Vector3f.new(q.x, fallGuard.groundY + 0.1, q.z), transform_of(fallGuard.chara):get_Rotation())
                        fallGuard.saves = fallGuard.saves + 1
                    end
                    if os.clock() > fallGuard.untilT then
                        if fallGuard.saves > 0 then event("fell through the ground after arriving - put back on top " .. fallGuard.saves .. "x") end
                        fallGuard = nil
                    end
                end
                if not (inputLocked or walkStick or pendingPlace or aimLock) then return end
                if pendingPlace then
                    local q = transform_of(pendingPlace.chara):get_Position()
                    local dx, dy, dz = q.x - pendingPlace.dest.x, q.y - pendingPlace.dest.y, q.z - pendingPlace.dest.z
                    if pendingPlace.first or dx * dx + dy * dy + dz * dz > 0.25 then
                        place(pendingPlace.chara, pendingPlace.dest, pendingPlace.rot)
                        pendingPlace.first = false
                    end
                    pendingPlace.frames = pendingPlace.frames - 1
                    if pendingPlace.frames <= 0 then
                        tell_cameras()
                        if pendingPlace.groundY then
                            fallGuard = { chara = pendingPlace.chara, groundY = pendingPlace.groundY, untilT = os.clock() + 2.0, saves = 0 }
                        end
                        fallReset = { chara = pendingPlace.chara, frames = 12 }
                        pendingPlace = nil
                    end
                end
                for _, f in ipairs(BTN_FIELDS) do pcall(function() curInput:set_field(f, 0) end) end
                if inputLocked or walkStick then -- while aiming the camera stays yours
                    pcall(function() curInput:call("setAxisR(System.Single, System.Single)", 0.0, 0.0) end)
                end
                local x, y = 0.0, 0.0
                if walkStick then x, y = walkStick.x, walkStick.y end
                curInput:call("setAxisL(System.Single, System.Single)", x, y)
            end)
        end
        return ret
    end)
end)

-- fall guard (v0.7.8): after a long jump the ground's collision at the destination may not be loaded yet and the
-- character falls through it (user: "head out of the ground, then fell inside the map"). For 2 s after the
-- teleport, dropping more than 0.6 m below the ground the beam found puts the character back on top of it.
local function teleport(p, dest, rot, groundY)
    pendingPlace = { chara = p, dest = dest, rot = rot, frames = 8, first = true, groundY = groundY }
end

------------------------------------------------------------------------
-- the arrival scene: controls locked; the camera flies to the side of the arrival door and swings round to its
-- front; the character appears behind the door (facing back toward where you cast from - that side is open, the
-- beam just flew through it) and walks out toward the camera; the camera swings round behind the character onto
-- the game's own camera and hands over.
------------------------------------------------------------------------
local SHOT_R, SHOT_H = 5.5, 0.8
-- camera on a circle around a pivot: theta 0 = in front (along fx, fz), pi/2 = right side, pi = behind
local function orbit_pose(pivot, fx, fz, theta, radius, height)
    local rx, rz = fz, -fx
    local cx = math.cos(theta) * fx + math.sin(theta) * rx
    local cz = math.cos(theta) * fz + math.sin(theta) * rz
    local pos = Vector3f.new(pivot.x + cx * radius, pivot.y + height, pivot.z + cz * radius)
    return pos, look_rot(pos, pivot)
end

local function end_scene(why)
    if not scene then return end
    finish_door(scene.door)
    camOverride, walkStick, inputLocked = nil, nil, false
    pcall(function() sdk.get_managed_singleton("app.CameraManager"):call("setCurrentCameraReset(app.CameraDefine.ResetOption)", 6) end)
    if why ~= "done" then event("arrival scene ended: " .. why) end
    scene = nil
end

local function start_scene(p, dest, dist, dx, dz, air, groundY)
    dx, dz = -dx, -dz
    local doorC = Vector3f.new(dest.x + dx * 0.6, dest.y, dest.z + dz * 0.6)
    if not air then doorC = ground_near(doorC.x, dest.y, doorC.z, 1.0, 2.0) or doorC end
    local pivot = Vector3f.new(doorC.x, doorC.y + 1.1, doorC.z)
    local shot, shotRot = orbit_pose(pivot, dx, dz, 0, SHOT_R, SHOT_H)
    local side, sideRot = orbit_pose(pivot, dx, dz, math.pi / 2, SHOT_R, SHOT_H)
    local tr = sdk.get_primary_camera():get_GameObject():get_Transform()
    local cam = gamePose or { pos = tr:get_Position(), rot = tr:get_Rotation() }
    scene = { phase = "fly", t0 = os.clock(), started = os.clock(), from = cam, shot = shot, shotRot = shotRot,
        side = side, sideRot = sideRot, pivot = pivot, start = dest, door = { center = doorC, nx = dx, nz = dz },
        rot = yaw_rotation(dx, dz), dx = dx, dz = dz, hop = math.min(30.0, dist * 0.25), air = air, groundY = groundY }
    inputLocked = true
    camOverride = { pos = cam.pos, rot = cam.rot }
    play_sound(p, TRAVEL_SOUND)
    event(string.format("stepped through: %.0f ft", dist / FT))
end

local function run_scene(p)
    local sc, now = scene, os.clock()
    local t = now - sc.t0
    if sc.phase == "fly" then
        local k = ease(t / config.fly_time)
        local pos = vlerp(sc.from.pos, sc.side, k)
        pos = Vector3f.new(pos.x, pos.y + math.sin(math.pi * k) * sc.hop, pos.z) -- arc over the terrain
        camOverride = { pos = pos, rot = qlerp(sc.from.rot, sc.sideRot, k) }
        if t >= config.fly_time then sc.phase, sc.t0 = "open", now; play_sound(p, OPEN_SOUND) end
    elseif sc.phase == "open" then
        -- swing from the side to the front while the door opens
        local k = ease(t / 0.9)
        local pos, rot = orbit_pose(sc.pivot, sc.dx, sc.dz, (1 - k) * math.pi / 2, SHOT_R, SHOT_H)
        camOverride = { pos = pos, rot = rot }
        draw_door(p, sc.door)
        if t >= 0.9 then
            teleport(p, sc.start, sc.rot, sc.groundY)
            for _, ids in ipairs(ARRIVE_EFX) do play_efx(p, ids, sc.door.center, sc.rot, 1.0) end
            play_sound(p, ARRIVE_SOUND)
            sc.phase, sc.t0 = "walk", now
        end
    elseif sc.phase == "walk" then
        camOverride = { pos = sc.shot, rot = sc.shotRot }
        draw_door(p, sc.door)
        local pos = transform_of(p):get_Position()
        local past = (pos.x - sc.door.center.x) * sc.dx + (pos.z - sc.door.center.z) * sc.dz
        local far = math.abs(pos.x - sc.start.x) + math.abs(pos.z - sc.start.z) > 6.0
        if far and t < 8.0 then return end -- not there yet
        if far then end_scene("the teleport never arrived"); return end
        if not sc.arrived then sc.arrived, sc.t0, t = true, now, 0 end
        if sc.air then -- arrived in the air: no walk, you fall
            if t > 0.3 then sc.phase, sc.t0 = "turn", now end
            return
        end
        if t > 0.25 then
            local x, y = stick_for(sc.dx, sc.dz, WALK_STRENGTH)
            if sc.flipped then x, y = -x, -y end
            walkStick = { x = x, y = y }
            -- self-check: if we're moving away from the door, turn the stick round
            sc.walkFrom = sc.walkFrom or past
            if not sc.checked and t > 0.75 then
                sc.checked = true
                if past < sc.walkFrom - 0.3 then sc.flipped = true end
            end
        end
        if past >= 0.5 or t > WALK_TIMEOUT then
            walkStick = nil
            sc.phase, sc.t0 = "turn", now
        end
    elseif sc.phase == "turn" then
        -- swing from the front round to behind the character, ending on the game's own camera
        local k = ease(t / TURN_TIME)
        local q = transform_of(p):get_Position()
        local pp = Vector3f.new(q.x, q.y + 1.1, q.z)
        local pivot = vlerp(sc.pivot, pp, k)
        local th1, r1, h1 = math.pi, 3.5, 0.6
        if gamePose then
            local vx, vy, vz = gamePose.pos.x - pp.x, gamePose.pos.y - pp.y, gamePose.pos.z - pp.z
            local rx, rz = sc.dz, -sc.dx
            th1 = math.atan(vx * rx + vz * rz, vx * sc.dx + vz * sc.dz)
            if th1 < 0 then th1 = th1 + 2 * math.pi end -- round via the right side
            r1, h1 = math.sqrt(vx * vx + vz * vz), vy
        end
        local pos, rot = orbit_pose(pivot, sc.dx, sc.dz, th1 * k, SHOT_R + (r1 - SHOT_R) * k, SHOT_H + (h1 - SHOT_H) * k)
        if gamePose then rot = qlerp(rot, gamePose.rot, k * k) end
        camOverride = { pos = pos, rot = rot }
        if t >= TURN_TIME then end_scene("done") end
    end
    if scene and now - scene.started > 20 then end_scene("watchdog timeout") end
end

-- walking through the door: crossing its plane forwards, within its width (more height tolerance in the air)
local function step_through(p)
    local pos = transform_of(p):get_Position()
    local vx, vz = pos.x - s.center.x, pos.z - s.center.z
    local side = vx * s.nx + vz * s.nz
    local across = math.abs(vx * -s.nz + vz * s.nx)
    local was = s.side
    s.side = side
    if was and was < 0 and side >= 0 and across <= DOOR_WIDTH / 2 + 0.3 and math.abs(pos.y - s.center.y) < (s.airDoor and 4.0 or 2.0) then
        local dest, rot, dist, air, groundY = s.dest, s.rot, s.dist, s.air, s.groundY
        local fx, fz = forward_of(rot)
        finish_door(s)
        state, s = nil, nil
        if config.cutscene then
            start_scene(p, dest, dist, fx, fz, air, groundY)
            return
        end
        teleport(p, dest, rot, groundY)
        for _, ids in ipairs(ARRIVE_EFX) do play_efx(p, ids, dest, rot, 1.0) end
        play_sound(p, ARRIVE_SOUND)
        event(string.format("stepped through: %.0f ft", dist / FT))
    end
end

local keyWasDown = false

-- everything that moves things or spawns effects runs here (in the game's update step)
re.on_pre_application_entry("UpdateBehavior", function()
    local ok, err = pcall(function()
        local p = player()
        -- a new player object (save loaded / back from the title) while aiming: start clean
        local pAddr = p and p:get_address() or nil
        if pAddr ~= lastPlayerAddr then
            if lastPlayerAddr and (state == "aiming" or cast) then
                pcall(function() pause_fsm(p, false) end); fsmPaused = nil
                cast, aimLock, castInfo = nil, false, "idle"
                if state == "aiming" then state, s = nil, nil; pcall(pillar_off) end
                event("character changed (load) - the cast was reset")
            end
            lastPlayerAddr = pAddr
        end
        if not p then
            if state then cancel("cancelled") end
            end_scene("no player")
            return
        end
        if not active() then   -- (Pactblade) not available now: aiming / an open door end, a running arrival finishes
            comboHeld, padComboPressed = false, false
            if state then cancel("not available now (Pactblade not active)") end
            cast_update(p)
            if scene then run_scene(p) end
            return
        end

        local down = reframework:is_key_down(config.key)
        local pressed = down and not keyWasDown
        keyWasDown = down
        if padComboPressed then padComboPressed = false; if config.pad_combo then pressed = true end end

        if config.cast_anim and not cast and os.clock() >= nextBankTry then
            nextBankTry = os.clock() + 5.0
            pcall(ensure_cast_bank, p) -- preloaded, so the first cast has its animations ready
        end
        cast_update(p)

        if scene then run_scene(p); return end

        if state == nil then
            if pressed then start(p) end
        elseif state == "aiming" then
            if pressed then lock_beam(p); return end
            aim_update(p)
        elseif state == "door" then
            if pressed then cancel("door closed"); return end
            if os.clock() > s.untilT then cancel("door faded"); return end
            draw_door(p, s)
            draw_door(p, s.remote)
            if s then step_through(p) end
        end
    end)
    if not ok then event("error: " .. tostring(err)); state, s = nil, nil; end_scene("error") end
end)

re.on_script_reset(function()
    pillar_off()
    pcall(function() local p = player(); if p then cast_end(p) end end)
    pause_fsm(nil, false)
    aimLock = false
    finish_door(s)
    if scene then finish_door(scene.door) end
    pendingPlace, fallGuard, fallReset = nil, nil, nil
    end_scene("script reset")
    for _, e in ipairs(liveEfx) do pcall(finish_effect, e.container) end
end)

------------------------------------------------------------------------
-- UI
------------------------------------------------------------------------
local KEY_NAMES = {}
for c = 0x41, 0x5A do KEY_NAMES[c] = string.char(c) end
for n = 1, 12 do KEY_NAMES[0x6F + n] = "F" .. n end
local waitingKey = false

function M.draw()
    local changed, c = false, false
    c, config.enabled = imgui.checkbox("Dimension Door on", config.enabled); changed = changed or c
    c, config.all_vocations = imgui.checkbox("   also with other vocations (not only Pactblade)", config.all_vocations); changed = changed or c
    imgui.text("   Gamepad: hold Vocation Action + Go! (d-pad up). Keyboard: the key below.")
    if waitingKey then
        imgui.text("Press a letter or F-key...")
        for code, _ in pairs(KEY_NAMES) do
            if reframework:is_key_down(code) then config.key = code; waitingKey = false; changed = true; keyWasDown = true end
        end
    elseif imgui.button("Key: " .. (KEY_NAMES[config.key] or tostring(config.key)) .. " (click to change)") then
        waitingKey = true
    end
    c, config.max_ft = imgui.slider_int("Max range (ft)", config.max_ft, 30, 1000); changed = changed or c
    c, config.door_time = imgui.slider_int("Door stays open (s)", config.door_time, 5, 300); changed = changed or c
    c, config.door_style = imgui.combo("Door look", config.door_style, { "Shimmer frame + wisps + glow", "Classic (shimmer frame only)" }); changed = changed or c
    local st = "ready"
    if state == "aiming" then st = s.b and string.format("aiming, %.0f ft%s", s.b.dist / FT, s.b.hit and "" or " (open air)") or "aiming"
    elseif state == "door" then st = string.format("door open, %.0f ft, %ds left", s.dist / FT, math.floor(s.untilT - os.clock())) end
    if scene then st = "arriving" end
    imgui.text("Now: " .. st .. (cast_ray and "" or "   - _ScriptCore (_SharedCore) MISSING, the spell can't work"))
    if not M.release and imgui.tree_node("Aiming look (test sliders)") then   -- (patch_i_008, now built in) no test sliders in release builds
        c, config.aim_cam = imgui.checkbox("camera over the shoulder while aiming", config.aim_cam); changed = changed or c
        c, config.aim_up = imgui.slider_float("camera up (m)", config.aim_up, 0, 3, "%.2f"); changed = changed or c
        c, config.aim_right = imgui.slider_float("camera right (m)", config.aim_right, -2, 2, "%.2f"); changed = changed or c
        c, config.aim_back = imgui.slider_float("camera back (m)", config.aim_back, -2, 4, "%.2f"); changed = changed or c
        c, config.pillar = imgui.checkbox("target pillar", config.pillar); changed = changed or c
        c, config.pillar_h = imgui.slider_float("pillar height (m)", config.pillar_h, 1, 20, "%.1f"); changed = changed or c
        c, config.pillar_step = imgui.slider_float("pillar spacing (m)", config.pillar_step, 0.2, 1.5, "%.2f"); changed = changed or c
        c, config.pillar_ring = imgui.slider_int("pillar pieces per ring", math.floor(config.pillar_ring), 1, 6); changed = changed or c
        c, config.pillar_r = imgui.slider_float("pillar radius (m)", config.pillar_r, 0, 1.5, "%.2f"); changed = changed or c
        c, config.sparks = imgui.checkbox("target sparks too", config.sparks); changed = changed or c
        imgui.text(("pillar pieces now: %d"):format(pillar and #pillar.items or 0))
        imgui.tree_pop()
    end
    imgui.text("Last: " .. tostring(lastMsg))
    if changed then save_config() end
end

-- (Pactblade) the vocation button belongs to the door while aiming / arriving, and from the combo until its release
function M.block() return state == "aiming" or scene ~= nil or comboHeld end

return M
