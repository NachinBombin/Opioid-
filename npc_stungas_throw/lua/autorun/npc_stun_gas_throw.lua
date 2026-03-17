-- ============================================================
--  NPC Stun Gas Throw  |  npc_stun_gas_throw.lua
--  Shared (SERVER logic + CLIENT trail + screen effects).
--
--  Enemy NPCs periodically lob a stun gas vial (prop_physics)
--  toward the player they are targeting.  On impact an orange
--  gas cloud is emitted.  The cloud deals NO damage but applies
--  a disorientation effect to any player caught inside:
--    - Motion blur (durgz_alcohol style, 30-75 s duration)
--    - Camera sway (sinusoidal roll + pitch drift)
--    - Movement disruption (random involuntary inputs)
--
--  CLIENT trail: a thin orange smoke tracer follows the vial.
--  CLIENT cloud: orange particle burst fired at detonation point.
--
--  No external addon dependencies.
--
--  [NARCAN PATCH]
--  Exposes NPCStunGas_NarcanClear(ply) so the Narcan syringe
--  (arctic_med_shots/narcan.lua) can clear this effect on demand.
--  The function lives inside the SERVER block and has closure
--  access to the local playerHighEnd table.
-- ============================================================

-- ============================================================
--  Shared network strings (must run on both realms)
-- ============================================================
util.AddNetworkString("NPCStunGas_VialSpawned")
util.AddNetworkString("NPCStunGas_CloudEffect")
util.AddNetworkString("NPCStunGas_ApplyHigh")

-- ============================================================
--  SERVER
-- ============================================================
if SERVER then

AddCSLuaFile()

-- ============================================================
--  ConVars
-- ============================================================
local SHARED_FLAGS = bit.bor(FCVAR_ARCHIVE, FCVAR_REPLICATED, FCVAR_NOTIFY)

local cv_enabled    = CreateConVar("npc_stun_gas_throw_enabled",    "1",    SHARED_FLAGS, "Enable/disable NPC stun gas throws.")
local cv_chance     = CreateConVar("npc_stun_gas_throw_chance",     "0.20", SHARED_FLAGS, "Probability (0-1) that an eligible NPC throws a stun gas vial each check.")
local cv_interval   = CreateConVar("npc_stun_gas_throw_interval",   "8",    SHARED_FLAGS, "Seconds between throw-eligibility checks per NPC.")
local cv_cooldown   = CreateConVar("npc_stun_gas_throw_cooldown",   "18",   SHARED_FLAGS, "Minimum seconds between throws for the same NPC.")
local cv_speed      = CreateConVar("npc_stun_gas_throw_speed",      "700",  SHARED_FLAGS, "Launch speed of the stun gas vial (units/s).")
local cv_arc        = CreateConVar("npc_stun_gas_throw_arc",        "0.25", SHARED_FLAGS, "Upward arc factor (0 = flat, higher = more lob).")
local cv_spawn_dist = CreateConVar("npc_stun_gas_throw_spawn_dist", "52",   SHARED_FLAGS, "Forward distance from NPC eye to spawn the vial (avoids self-collision).")
local cv_max_dist   = CreateConVar("npc_stun_gas_throw_max_dist",   "2200", SHARED_FLAGS, "Max distance to player for a throw to be attempted.")
local cv_min_dist   = CreateConVar("npc_stun_gas_throw_min_dist",   "120",  SHARED_FLAGS, "Min distance to player (no throw if closer than this).")
local cv_spin       = CreateConVar("npc_stun_gas_throw_spin",       "1",    SHARED_FLAGS, "Apply a random spin impulse to the vial (1 = enabled).")
local cv_announce   = CreateConVar("npc_stun_gas_throw_announce",   "0",    SHARED_FLAGS, "Print a debug message to console each time an NPC throws.")
local cv_cloud_min  = CreateConVar("npc_stun_gas_throw_cloud_min",  "150",  SHARED_FLAGS, "Minimum stun gas cloud radius in units (randomized per detonation).")
local cv_cloud_max  = CreateConVar("npc_stun_gas_throw_cloud_max",  "300",  SHARED_FLAGS, "Maximum stun gas cloud radius in units (randomized per detonation).")
local cv_high_min   = CreateConVar("npc_stun_gas_throw_high_min",   "30",   SHARED_FLAGS, "Minimum stun effect duration in seconds.")
local cv_high_max   = CreateConVar("npc_stun_gas_throw_high_max",   "75",   SHARED_FLAGS, "Maximum stun effect duration in seconds.")

-- ============================================================
--  Constants
-- ============================================================

local VIAL_MODEL    = "models/healthvial.mdl"
local VIAL_MATERIAL = "models/weapons/gv/nerve_vial.vmt"

local IMPACT_SPEED  = 80
local MIN_FLIGHT    = 0.25
local MAX_VIAL_LIFE = 8

local vialCounter   = 0

-- ============================================================
--  Helpers
-- ============================================================

local STUN_GAS_THROWERS = {
    ["npc_combine_s"]     = true,
    ["npc_metropolice"]   = true,
    ["npc_combine_elite"] = true,
}

local function IsEligibleThrower(npc)
    if not IsValid(npc) or not npc:IsNPC() then return false end
    return STUN_GAS_THROWERS[npc:GetClass()] == true
end

local function CalcLaunchVelocity(from, to, speed, arcFactor)
    local dir        = (to - from)
    local horizontal = Vector(dir.x, dir.y, 0)
    local dist       = horizontal:Length()
    if dist < 1 then dist = 1 end
    horizontal:Normalize()
    local velH = horizontal * speed
    local velZ = dist * arcFactor + (to.z - from.z) * 0.3
    velZ = math.Clamp(velZ, -speed * 0.5, speed * 0.8)
    return Vector(velH.x, velH.y, velZ)
end

-- ============================================================
--  Stun "High" state
--  [NARCAN PATCH] NPCStunGas_NarcanClear has closure access to
--  playerHighEnd because it is defined in this same SERVER block.
-- ============================================================

local playerHighEnd = {}  -- keyed by UserID

local function ApplyStunHigh(pl)
    if not IsValid(pl) or not pl:IsPlayer() then return end
    if not pl:Alive() then return end

    -- Gas mask wearers are fully immune to all stun gas effects.
    if pl.GASMASK_Equiped then return end

    local now         = CurTime()
    local uid         = pl:UserID()
    local highDuration = math.Rand(cv_high_min:GetFloat(), cv_high_max:GetFloat())

    if (playerHighEnd[uid] or 0) > now then
        playerHighEnd[uid] = math.max(playerHighEnd[uid], now + highDuration)
        pl:SetNWFloat("npc_stungas_high_end", playerHighEnd[uid])
        return
    end

    playerHighEnd[uid] = now + highDuration

    net.Start("NPCStunGas_ApplyHigh")
        net.WriteFloat(now)
        net.WriteFloat(playerHighEnd[uid])
    net.Send(pl)

    pl:SetNWFloat("npc_stungas_high_start", now)
    pl:SetNWFloat("npc_stungas_high_end",   playerHighEnd[uid])

    local commands = { "left", "right", "moveleft", "moveright", "duck", "attack" }
    local numHits  = math.random(1, 3)

    for i = 1, numHits do
        timer.Simple(math.Rand(2, 8), function()
            if not IsValid(pl) or not pl:Alive() then return end
            if (playerHighEnd[uid] or 0) < CurTime() then return end
            local cmd = commands[math.random(1, #commands)]
            pl:ConCommand("+" .. cmd)
            timer.Simple(math.Rand(0.3, 0.9), function()
                if not IsValid(pl) then return end
                pl:ConCommand("-" .. cmd)
            end)
        end)
    end

    timer.Simple(highDuration * 0.45, function()
        if not IsValid(pl) or not pl:Alive() then return end
        if (playerHighEnd[uid] or 0) < CurTime() then return end
        local cmd = commands[math.random(1, #commands)]
        pl:ConCommand("+" .. cmd)
        timer.Simple(math.Rand(0.4, 1.0), function()
            if not IsValid(pl) then return end
            pl:ConCommand("-" .. cmd)
        end)
    end)

    timer.Simple(highDuration * 0.75, function()
        if not IsValid(pl) or not pl:Alive() then return end
        if (playerHighEnd[uid] or 0) < CurTime() then return end
        local numLate = math.random(1, 2)
        for i = 1, numLate do
            local cmd = commands[math.random(1, #commands)]
            pl:ConCommand("+" .. cmd)
            timer.Simple(math.Rand(0.5, 1.2), function()
                if not IsValid(pl) then return end
                pl:ConCommand("-" .. cmd)
            end)
        end
    end)
end

-- ============================================================
--  Detonation
-- ============================================================

local function DetonateStunGas(pos, owner, uid)

    local cloudRadius = math.Rand(cv_cloud_min:GetFloat(), cv_cloud_max:GetFloat())

    net.Start("NPCStunGas_CloudEffect")
        net.WriteVector(pos)
        net.WriteFloat(cloudRadius)
    net.Broadcast()

    local GAS_DURATION = 18
    local GAS_TICK     = 0.5
    local ticks        = math.floor(GAS_DURATION / GAS_TICK)
    local timerName    = "StunGasDmg_" .. uid
    local atk          = IsValid(owner) and owner or game.GetWorld()

    timer.Create(timerName, GAS_TICK, ticks, function()
        for _, ent in ipairs(ents.FindInSphere(pos, cloudRadius)) do
            if not IsValid(ent) then continue end
            if not ent:IsPlayer() then continue end
            ApplyStunHigh(ent)
        end
    end)
end

-- ============================================================
--  Throw logic
-- ============================================================

local function ThrowStunGas(npc, target)

    do
        local gestureAct  = ACT_GESTURE_RANGE_ATTACK_THROW
        local fallbackAct = ACT_RANGE_ATTACK_THROW
        local seq = npc:SelectWeightedSequence(gestureAct)
        if seq <= 0 then
            seq = npc:SelectWeightedSequence(fallbackAct)
            if seq > 0 then gestureAct = fallbackAct end
        end
        if seq > 0 then npc:AddGesture(gestureAct) end
    end

    npc.__stun_gas_lastThrow = CurTime()
    local distAtTrigger = npc:GetPos():Distance(target:GetPos())

    timer.Simple(1, function()

        if not IsValid(npc) or not IsValid(target) then return end

        local targetPos = target:GetPos() + Vector(0, 0, 36)
        local npcEyePos = npc:EyePos()
        local toTarget  = (targetPos - npcEyePos):GetNormalized()
        local spawnDist = cv_spawn_dist:GetFloat()
        local spawnPos  = npcEyePos + toTarget * spawnDist

        local tr = util.TraceLine({
            start  = npcEyePos,
            endpos = spawnPos,
            filter = { npc },
            mask   = MASK_SOLID_BRUSHONLY,
        })
        if tr.Hit then
            spawnPos = npcEyePos + toTarget * (tr.Fraction * spawnDist * 0.85)
        end

        local vial = ents.Create("prop_physics")
        if not IsValid(vial) then return end

        local eyeAng = toTarget:Angle()
        vial:SetModel(VIAL_MODEL)
        vial:SetMaterial(VIAL_MATERIAL)
        vial:SetPos(spawnPos + eyeAng:Right() * 6 + eyeAng:Up() * -2)
        vial:SetAngles(npc:GetAngles() + Angle(-90, 0, 0))
        vial:SetCollisionGroup(COLLISION_GROUP_PROJECTILE)
        vial:Spawn()
        vial:Activate()

        vial.StunGasOwner = npc

        local phys = vial:GetPhysicsObject()
        if IsValid(phys) then
            local speed = cv_speed:GetFloat()
            local vel   = CalcLaunchVelocity(spawnPos, targetPos, speed, cv_arc:GetFloat())
            phys:SetVelocity(vel)

            if cv_spin:GetBool() then
                local spin   = vel:GetNormalized() * math.random(5, 10)
                local offset = vial:LocalToWorld(vial:OBBCenter())
                             + Vector(0, 0, math.random(10, 15))
                phys:ApplyForceOffset(spin, offset)
            end

            phys:Wake()
        end

        net.Start("NPCStunGas_VialSpawned")
            net.WriteEntity(vial)
        net.Broadcast()

        if cv_announce:GetBool() then
            print(string.format(
                "[NPC Stun Gas Throw] %s threw at %s (dist: %.0f)",
                npc:GetClass(), target:Nick(), distAtTrigger
            ))
        end

        vialCounter = vialCounter + 1
        local uid       = vialCounter
        local spawnTime = CurTime()
        local timerName = "StunGasVial_" .. uid

        timer.Create(timerName, 0.05, 0, function()

            if not IsValid(vial) then
                timer.Remove(timerName)
                DetonateStunGas(spawnPos, npc, uid)
                return
            end

            local age   = CurTime() - spawnTime
            local phys2 = vial:GetPhysicsObject()
            local spd2  = IsValid(phys2) and phys2:GetVelocity():Length() or 0

            local impacted = (age > MIN_FLIGHT) and (spd2 < IMPACT_SPEED)
            local expired  = (age > MAX_VIAL_LIFE)

            if impacted or expired then
                local gasPos = vial:GetPos()
                local owner  = vial.StunGasOwner
                vial:Remove()
                timer.Remove(timerName)
                DetonateStunGas(gasPos, owner, uid)
            end
        end)

    end)  -- end timer.Simple

    return true
end

-- ============================================================
--  Per-NPC state initialisation (lazy)
-- ============================================================

local function InitNPCState(npc)
    if not IsValid(npc) then return end
    if npc.__stun_gas_hooked then return end
    npc.__stun_gas_hooked    = true
    npc.__stun_gas_nextCheck = CurTime() + math.Rand(1, cv_interval:GetFloat())
    npc.__stun_gas_lastThrow = 0
end

-- ============================================================
--  Main Think loop
-- ============================================================

timer.Create("NPCStunGasThrow_Think", 0.5, 0, function()
    if not cv_enabled:GetBool() then return end

    local now      = CurTime()
    local interval = cv_interval:GetFloat()
    local cooldown = cv_cooldown:GetFloat()
    local chance   = cv_chance:GetFloat()
    local maxDist  = cv_max_dist:GetFloat()
    local minDist  = cv_min_dist:GetFloat()

    for _, npc in ipairs(ents.GetAll()) do
        if not IsValid(npc) or not npc:IsNPC() then continue end
        if not IsEligibleThrower(npc) then continue end

        InitNPCState(npc)

        if now < (npc.__stun_gas_nextCheck or 0) then continue end
        npc.__stun_gas_nextCheck = now + interval + math.Rand(-1, 1)

        if now - (npc.__stun_gas_lastThrow or 0) < cooldown then continue end

        if npc:Health() <= 0 then continue end
        local enemy = npc:GetEnemy()
        if not IsValid(enemy) or not enemy:IsPlayer() then continue end
        if not enemy:Alive() then continue end

        local dist = npc:GetPos():Distance(enemy:GetPos())
        if dist > maxDist or dist < minDist then continue end

        local losTr = util.TraceLine({
            start  = npc:EyePos(),
            endpos = enemy:EyePos(),
            filter = { npc },
            mask   = MASK_SOLID,
        })
        if losTr.Entity ~= enemy and losTr.Fraction < 0.85 then continue end

        if math.random() > chance then continue end

        ThrowStunGas(npc, enemy)
    end
end)

-- ============================================================
--  Startup message
-- ============================================================

hook.Add("InitPostEntity", "NPCStunGasThrow_Init", function()
    print("[NPC Stun Gas Throw] Addon loaded.")
    print("[NPC Stun Gas Throw] Use 'npc_stun_gas_throw_*' convars to configure.")
    print("[NPC Stun Gas Throw] Narcan support: active.")
    print("[NPC Stun Gas Throw] Gas mask support: active (full immunity).")
end)

-- Clear the high immediately when a player dies.
hook.Add("PlayerDeath", "NPCStunGasThrow_ClearOnDeath", function(pl)
    if not IsValid(pl) then return end
    local uid = pl:UserID()
    playerHighEnd[uid] = nil
    pl:SetNWFloat("npc_stungas_high_start", 0)
    pl:SetNWFloat("npc_stungas_high_end",   0)
    net.Start("NPCStunGas_ApplyHigh")
        net.WriteFloat(0)
        net.WriteFloat(0)
    net.Send(pl)
end)

-- ============================================================
--  [NARCAN PATCH] Global clear function
--  Called by arctic_med_shots/narcan.lua via:
--      if NPCStunGas_NarcanClear then
--          NPCStunGas_NarcanClear(ply)
--      end
--  Defined inside the SERVER block so it has closure access
--  to the local playerHighEnd table above.
--  Reuses the existing NPCStunGas_ApplyHigh net message with
--  (0, 0) -- identical to what PlayerDeath already does --
--  so no new network strings are needed.
-- ============================================================

--- Clears the stun gas disorientation high for a player immediately.
function NPCStunGas_NarcanClear(ply)
    if not IsValid(ply) then return end

    local uid = ply:UserID()

    -- Zero the server-side expiry so all pending high timer callbacks
    -- find (playerHighEnd[uid] or 0) < CurTime() and self-abort.
    playerHighEnd[uid] = nil

    -- Zero the NWFloat fallback values used by late-joiners.
    ply:SetNWFloat("npc_stungas_high_start", 0)
    ply:SetNWFloat("npc_stungas_high_end",   0)

    -- Send ApplyHigh(0, 0) to the client. The client receiver sets
    -- cl_highStart = 0 and cl_highEnd = 0, which immediately stops
    -- the motion blur, orange tint, and CalcView sway on the next frame.
    net.Start("NPCStunGas_ApplyHigh")
        net.WriteFloat(0)
        net.WriteFloat(0)
    net.Send(ply)
end

end  -- SERVER

-- ============================================================
--  CLIENT
-- ============================================================
if CLIENT then

-- ============================================================
--  Thin orange tracer
-- ============================================================

local activeVials       = {}
local SMOKE_SPRITE_BASE = "particle/smokesprites_000"

net.Receive("NPCStunGas_VialSpawned", function()
    local vial = net.ReadEntity()
    if IsValid(vial) then
        activeVials[vial:EntIndex()] = vial
    end
end)

hook.Add("Think", "NPCStunGasThrow_VialTracer", function()

    if not next(activeVials) then return end

    for idx, vial in pairs(activeVials) do
        if not IsValid(vial) then
            activeVials[idx] = nil
            continue
        end

        local pos     = vial:GetPos()
        local emitter = ParticleEmitter(pos, false)
        if not emitter then continue end

        for i = 1, 2 do
            local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
            if not p then continue end

            p:SetVelocity(Vector(
                math.Rand(-8, 8),
                math.Rand(-8, 8),
                math.Rand(4, 14)
            ))
            p:SetDieTime(math.Rand(0.3, 0.6))
            p:SetColor(255, 120, 20)
            p:SetStartAlpha(math.Rand(180, 220))
            p:SetEndAlpha(0)
            p:SetStartSize(math.Rand(3, 6))
            p:SetEndSize(math.Rand(14, 24))
            p:SetRoll(math.Rand(0, 360))
            p:SetRollDelta(math.Rand(-0.5, 0.5))
            p:SetAirResistance(70)
            p:SetGravity(Vector(0, 0, -6))
        end

        if math.random() > 0.55 then
            local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
            if p then
                p:SetVelocity(Vector(
                    math.Rand(-14, 14),
                    math.Rand(-14, 14),
                    math.Rand(8, 20)
                ))
                p:SetDieTime(math.Rand(0.7, 1.2))
                p:SetColor(240, 90, 10)
                p:SetStartAlpha(math.Rand(70, 110))
                p:SetEndAlpha(0)
                p:SetStartSize(math.Rand(6, 11))
                p:SetEndSize(math.Rand(28, 45))
                p:SetRoll(math.Rand(0, 360))
                p:SetRollDelta(math.Rand(-0.3, 0.3))
                p:SetAirResistance(45)
                p:SetGravity(Vector(0, 0, -4))
            end
        end

        emitter:Finish()
    end
end)

-- ============================================================
--  Orange cloud burst at detonation point
-- ============================================================

net.Receive("NPCStunGas_CloudEffect", function()
    local pos         = net.ReadVector()
    local cloudRadius = net.ReadFloat()

    local emitter = ParticleEmitter(pos, false)
    if not emitter then return end

    local count = math.floor(math.Clamp(cloudRadius / 5, 30, 120))

    for i = 1, count do
        local p = emitter:Add(SMOKE_SPRITE_BASE .. math.random(1, 9), pos)
        if not p then continue end

        local speed = math.Rand(cloudRadius * 0.3, cloudRadius * 1.0)
        p:SetVelocity(VectorRand():GetNormalized() * speed)

        if i <= math.floor(count * 0.1) then
            p:SetDieTime(18)
        else
            p:SetDieTime(math.Rand(8, 18))
        end

        local r = math.random(220, 255)
        local g = math.random(70, 140)
        p:SetColor(r, g, 10)

        p:SetStartAlpha(math.Rand(45, 65))
        p:SetEndAlpha(0)
        p:SetStartSize(math.Rand(40, 60))
        p:SetEndSize(math.Rand(180, 260))
        p:SetRoll(math.Rand(0, 360))
        p:SetRollDelta(math.Rand(-1, 1))
        p:SetAirResistance(100)
        p:SetCollide(true)
        p:SetBounce(1)
    end

    emitter:Finish()
end)

-- ============================================================
--  Stun High -- screen effect
--  Motion blur + warm orange tint + sinusoidal camera sway.
--  Receives both normal ApplyHigh trigger AND Narcan clear
--  (which sends 0, 0 for both values, instantly zeroing state).
-- ============================================================

local STUN_HIGH_TRANSITION = 6
local STUN_HIGH_INTENSITY  = 1

local cl_highStart = 0
local cl_highEnd   = 0

net.Receive("NPCStunGas_ApplyHigh", function()
    cl_highStart = net.ReadFloat()
    cl_highEnd   = net.ReadFloat()
end)

local function GetStunBlurFactor()
    local now = CurTime()

    local highStart = cl_highStart
    local highEnd   = cl_highEnd

    if highStart == 0 then
        highStart = LocalPlayer():GetNWFloat("npc_stungas_high_start", 0)
        highEnd   = LocalPlayer():GetNWFloat("npc_stungas_high_end",   0)
    end

    if highStart == 0 or highEnd <= now then return 0 end

    local factor = 0

    if highStart + STUN_HIGH_TRANSITION > now then
        local s = highStart
        local e = s + STUN_HIGH_TRANSITION
        factor  = ((now - s) / (e - s)) * STUN_HIGH_INTENSITY

    elseif highEnd - STUN_HIGH_TRANSITION < now then
        local e = highEnd
        local s = e - STUN_HIGH_TRANSITION
        factor  = (1 - (now - s) / (e - s)) * STUN_HIGH_INTENSITY

    else
        factor = STUN_HIGH_INTENSITY
    end

    return math.Clamp(factor, 0, 1)
end

hook.Add("RenderScreenspaceEffects", "NPCStunGasThrow_High", function()
    local pl = LocalPlayer()
    if not IsValid(pl) then return end

    local factor = GetStunBlurFactor()
    if factor <= 0 then return end

    DrawMotionBlur(0.03, factor, 0)

    render.SetColorModulation(
        1,
        0.7 + (1 - factor) * 0.3,
        0.4 + (1 - factor) * 0.6
    )
end)

hook.Add("CalcView", "NPCStunGasThrow_Sway", function(pl, origin, angles, fov)
    if not IsValid(pl) then return end

    local factor = GetStunBlurFactor()
    if factor <= 0 then return end

    local t = CurTime()

    local roll  = math.sin(t * 0.9) * 8 * factor
    local pitch = math.sin(t * 1.6 + 1.2) * 3 * factor
    local yaw   = math.sin(t * 0.5 + 0.7) * 1.5 * factor

    local newAngles = Angle(
        angles.p + pitch,
        angles.y + yaw,
        angles.r + roll
    )

    return { origin = origin, angles = newAngles, fov = fov }
end)

hook.Add("PostRender", "NPCStunGasThrow_HighReset", function()
    if cl_highEnd > 0 and cl_highEnd <= CurTime() then
        render.SetColorModulation(1, 1, 1)
        cl_highStart = 0
        cl_highEnd   = 0
    end
end)

end  -- CLIENT
