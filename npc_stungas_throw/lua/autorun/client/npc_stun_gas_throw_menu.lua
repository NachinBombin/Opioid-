-- ============================================================
--  NPC Stun Gas Throw  |  npc_stun_gas_throw_menu.lua
--  Client-side Options menu panel.
--
--  Registers under the shared "Bombin Addons" category inside
--  the Options tab of the spawnmenu.
-- ============================================================

if SERVER then return end

local ADDON_CATEGORY = "Bombin Addons"

hook.Add("AddToolMenuCategories", "NPCStunGasThrow_AddCategory", function()
    spawnmenu.AddToolMenuCategory(ADDON_CATEGORY)
end)

hook.Add("PopulateToolMenu", "NPCStunGasThrow_PopulateMenu", function()
    spawnmenu.AddToolMenuOption(
        "Options",
        ADDON_CATEGORY,
        "npc_stun_gas_throw_settings",
        "NPC Stun Gas Throw",
        "",
        "",
        function(panel)

            panel:ClearControls()

            -- ------------------------------------------------
            --  Header
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "NPC Stun Gas Throw Settings",
                Height      = "40",
            })

            panel:CheckBox("Enable NPC Stun Gas Throws", "npc_stun_gas_throw_enabled")
            panel:ControlHelp("  Master on/off switch for the entire addon.")

            panel:CheckBox("Debug Announce in Console", "npc_stun_gas_throw_announce")
            panel:ControlHelp("  Print a console message every time an NPC throws.")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Probability & timing
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "Probability & Timing",
                Height      = "30",
            })

            panel:NumSlider("Throw Chance",
                "npc_stun_gas_throw_chance", 0, 1, 2)
            panel:ControlHelp("  Probability (0.00 - 1.00) that an eligible NPC throws\n  a stun gas vial each time it is checked.  Default: 0.20")

            panel:NumSlider("Check Interval (seconds)",
                "npc_stun_gas_throw_interval", 1, 30, 0)
            panel:ControlHelp("  How many seconds between throw-eligibility checks\n  for each individual NPC.  Default: 8")

            panel:NumSlider("Throw Cooldown (seconds)",
                "npc_stun_gas_throw_cooldown", 1, 60, 0)
            panel:ControlHelp("  Minimum seconds that must pass between throws\n  for the same NPC.  Default: 18")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Projectile behaviour
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "Projectile Behaviour",
                Height      = "30",
            })

            panel:NumSlider("Launch Speed (units/s)",
                "npc_stun_gas_throw_speed", 100, 1500, 0)
            panel:ControlHelp("  How fast the stun gas vial is thrown.  Default: 700")

            panel:NumSlider("Arc Factor",
                "npc_stun_gas_throw_arc", 0, 1, 2)
            panel:ControlHelp("  Upward lob strength.\n  0.00 = nearly flat,  1.00 = very high arc.  Default: 0.25")

            panel:NumSlider("Spawn Offset (units)",
                "npc_stun_gas_throw_spawn_dist", 20, 150, 0)
            panel:ControlHelp("  Forward distance from the NPC's eye to where the\n  vial spawns.  Increase if you see self-collision.  Default: 52")

            panel:CheckBox("Apply Random Spin to Vial", "npc_stun_gas_throw_spin")
            panel:ControlHelp("  Adds a random angular impulse to the vial in flight,\n  making it tumble naturally before impact.")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Engagement range
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "Engagement Range",
                Height      = "30",
            })

            panel:NumSlider("Max Distance",
                "npc_stun_gas_throw_max_dist", 200, 6000, 0)
            panel:ControlHelp("  NPCs will not throw if the player is farther than\n  this many units away.  Default: 2200")

            panel:NumSlider("Min Distance",
                "npc_stun_gas_throw_min_dist", 0, 500, 0)
            panel:ControlHelp("  NPCs will not throw if the player is closer than\n  this many units (too close to lob).  Default: 120")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Gas Cloud Size
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "Gas Cloud Size",
                Height      = "30",
            })

            panel:NumSlider("Cloud Radius Min (units)",
                "npc_stun_gas_throw_cloud_min", 50, 600, 0)
            panel:ControlHelp("  Minimum radius of the stun gas cloud.\n  Each detonation picks a random size between min and max.  Default: 150")

            panel:NumSlider("Cloud Radius Max (units)",
                "npc_stun_gas_throw_cloud_max", 50, 600, 0)
            panel:ControlHelp("  Maximum radius of the stun gas cloud.\n  Set equal to Min to disable randomization.  Default: 300")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Effect Duration
            -- ------------------------------------------------
            panel:AddControl("Header", {
                Description = "Effect Duration",
                Height      = "30",
            })

            panel:NumSlider("Min Duration (seconds)",
                "npc_stun_gas_throw_high_min", 5, 120, 0)
            panel:ControlHelp("  Minimum duration of the stun disorientation effect.\n  Each exposure rolls randomly between min and max.  Default: 30")

            panel:NumSlider("Max Duration (seconds)",
                "npc_stun_gas_throw_high_max", 5, 120, 0)
            panel:ControlHelp("  Maximum duration of the stun disorientation effect.\n  Set equal to Min for a fixed duration.  Default: 75")

            panel:AddControl("Label", { Text = "" })

            -- ------------------------------------------------
            --  Info footer
            -- ------------------------------------------------
            panel:ControlHelp("  Changes take effect immediately.\n  No external addon dependencies required.\n  Kill credit is assigned to the throwing NPC.")

        end
    )
end)
