local mq                = require('mq')
local ICONS             = require('mq.Icons')
local ImGui             = require('ImGui')
local parcelInv         = require('parcel_inv')
local actors            = require 'actors'

local openGUI           = false
local shouldDrawGUI     = false

local terminate         = false

local parcelTarget      = ""
local startParcel       = false

local animItems         = mq.FindTextureAnimation("A_DragItem")

local status            = "Idle..."
local sourceIndex       = 1
local nearestVendor     = nil

local ColumnID_ItemIcon = 0
local ColumnID_Item     = 1
local ColumnID_Remove   = 2
local ColumnID_Sent     = 3
local ColumnID_LAST     = ColumnID_Sent + 1
local settings_file     = mq.configDir .. "/parcel.lua"
local custom_sources    = mq.configDir .. "/parcel_sources.lua"

local settings          = {}

local function has_value(tab, val)
    for index, value in ipairs(tab) do
        if value == val then
            return true
        end
    end

    return false
end

local Output = function(msg, ...)
    local formatted = msg
    if ... then
        formatted = string.format(msg, ...)
    end
    printf('\aw[' .. mq.TLO.Time() .. '] [\aoBFO Parcel\aw] ::\a-t %s', formatted)
end

local function SaveSettings()
    mq.pickle(settings_file, settings)
    actors.send({ from = mq.TLO.Me.DisplayName(), script = "BFOParcel", event = "SaveSettings", })
end

local function LoadSettings()
    local config, err = loadfile(settings_file)
    if err or not config then
        Output("\ayNo valid configuration found. Creating a new one: %s", settings_file)
        settings = {}
        SaveSettings()
    else
        settings = config()
    end

    local customSources = {}
    local config, err = loadfile(custom_sources)
    if not err and config then
        customSources = config()
    end

    parcelInv = parcelInv:new(customSources)
end

local function findParcelVendor()
    status = "Finding Nearest Parcel Vendor"
    local parcelSpawns = mq.getFilteredSpawns(function(spawn)
        return (string.find(spawn.Surname(), "Parcels") ~= nil) or
            (string.find(spawn.Surname(), "Parcel Services") ~= nil) or
            (string.find(spawn.Name(), "Postmaster") ~= nil)
    end)

    if #parcelSpawns <= 0 then
        status = "Idle..."
        return nil
    end

    local dist = 999999
    for _, s in ipairs(parcelSpawns) do
        if s.Distance() < dist then
            nearestVendor = s
            dist = s.Distance()
        end
    end

    status = "Idle..."

    return nearestVendor
end

local function gotoParcelVendor()
    local spawn = findParcelVendor()

    if not spawn then return end

    status = "Naving to Parcel Vendor: " .. spawn.DisplayName()

    Output("\atFound parcel vendor: \am%s", spawn.DisplayName())

    mq.cmdf("/nav id %d | distance=10", spawn.ID())
end


local function targetParcelVendor()
    local spawn = findParcelVendor()

    if not spawn then return end

    Output("\atFound parcel vendor: \am%s", spawn.DisplayName())

    mq.cmdf("/target id %d", spawn.ID())
end

local function doParceling()
    if openGUI and (not nearestVendor or not nearestVendor.ID() or nearestVendor.ID() <= 0) then
        findParcelVendor()
    end

    if not startParcel then return end

    settings.History = settings.History or {}
    if not has_value(settings.History, parcelTarget) then
        table.insert(settings.History, parcelTarget)
        SaveSettings()
    end

    if not nearestVendor then
        Output("\arNo Parcel Vendor found in zone!")
        startParcel = false
        return
    end

    if not mq.TLO.Navigation.Active() and (nearestVendor.Distance() or 0) > 10 then
        gotoParcelVendor()
    end

    if mq.TLO.Navigation.Active() and not mq.TLO.Navigation.Paused() then
        status = string.format("Naving to %s (%d)", nearestVendor.DisplayName(), nearestVendor.Distance())
        return
    end

    if mq.TLO.Target.ID() ~= nearestVendor.ID() then
        status = "Targeting: " .. nearestVendor.DisplayName()
        targetParcelVendor()
        return
    end

    if not mq.TLO.Window("MerchantWnd").Open() then
        status = "Opening Parcel Window..."
        mq.cmd("/click right target")
        return
    end

    local tabPage = mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows")
    if tabPage.CurrentTab.Name() ~= "MW_MailPage" then
        status = "Selecting Parcel Tab..." ..
            tostring(tabPage.CurrentTabIndex())
        tabPage.SetCurrentTab(tabPage.CurrentTabIndex() + 1)
        return
    end

    if mq.TLO.Window("MerchantWnd").Child("MW_Send_To_Edit").Text() ~= parcelTarget then
        status = "Setting Name to send to..."
        mq.TLO.Window("MerchantWnd").Child("MW_Send_To_Edit").SetText(parcelTarget)
        return
    end

    if mq.TLO.Window("MerchantWnd").Child("MW_Send_Button").Enabled() == false and mq.TLO.Window("MerchantWnd").Child("MW_Send_Button")() == "TRUE" then
        -- waiting for previous send to finish...
        status = "Waiting on send to finish..."
        return
    end

    local item = parcelInv:getNextItem()
    if item then
        if item.Sent == ICONS.MD_CLOUD_DONE then
            return
        end

        status = string.format("Sending: %s", item["Item"].Name())

        mq.cmd("/itemnotify in " ..
            parcelInv.toPack(item["Item"].ItemSlot()) ..
            " " .. parcelInv.toBagSlot(item["Item"].ItemSlot2()) .. " leftmouseup")

        repeat
            mq.delay(10)
        until mq.TLO.Window("MerchantWnd").Child("MW_Send_Button")() == "TRUE" and mq.TLO.Window("MerchantWnd").Child("MW_Send_Button").Enabled()

        item.Sent = ICONS.MD_CLOUD_UPLOAD

        mq.cmd("/shift /notify MerchantWnd MW_Send_Button leftmouseup")

        item.Sent = ICONS.MD_CLOUD_DONE
    else
        startParcel = false
        status = "Idle..."
        parcelInv:resetState()
    end
end

local function renderItems()
    ImGui.Text("Items to Send:")
    if ImGui.BeginTable("BagItemList", ColumnID_LAST, bit32.bor(ImGuiTableFlags.Resizable, ImGuiTableFlags.Borders)) then
        ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0, 1.0, 1)
        ImGui.TableSetupColumn('Icon', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_ItemIcon)
        ImGui.TableSetupColumn('Item',
            bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.PreferSortDescending,
                ImGuiTableColumnFlags.WidthStretch),
            150.0, ColumnID_Item)
        ImGui.TableSetupColumn('', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_Remove)
        ImGui.TableSetupColumn('Sent', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_Sent)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()
        --ImGui.TableNextRow()

        for idx, item in ipairs(parcelInv.items) do
            local currentItem = item.Item
            ImGui.TableNextColumn()
            animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
            ImGui.DrawTextureAnimation(animItems, 20, 20)
            ImGui.TableNextColumn()
            if ImGui.Selectable(currentItem.Name(), false, 0) then
                currentItem.Inspect()
            end
            ImGui.TableNextColumn()
            ImGui.PushStyleColor(ImGuiCol.Text, 0.8, 0.02, 0.02, 1.0)
            ImGui.PushID("#_btn_" .. tostring(idx))
            if ImGui.Selectable(ICONS.MD_REMOVE_CIRCLE_OUTLINE) then
                table.remove(parcelInv.items, idx)
            end
            ImGui.PopID()
            ImGui.PopStyleColor()
            ImGui.TableNextColumn()
            ImGui.Text(item.Sent)
        end

        ImGui.EndTable()
    end
end

local COMBO_POPUP_FLAGS = bit32.bor(ImGuiWindowFlags.NoTitleBar, ImGuiWindowFlags.NoMove, ImGuiWindowFlags.NoResize, ImGuiWindowFlags.ChildWindow)
local function popupcombo(label, current_value, options)
    local result, changed = ImGui.InputText(label, current_value)
    local active = ImGui.IsItemActive()
    local activated = ImGui.IsItemActivated()
    if activated then ImGui.OpenPopup('##combopopup' .. label) end
    local itemrectX, _ = ImGui.GetItemRectMin()
    local _, itemRectY = ImGui.GetItemRectMax()
    ImGui.SetNextWindowPos(itemrectX, itemRectY)
    ImGui.SetNextWindowSize(ImVec2(200, 200))
    if ImGui.BeginPopup('##combopopup' .. label, COMBO_POPUP_FLAGS) then
        for _, value in ipairs(options or {}) do
            if ImGui.Selectable(value) then
                result = value
            end
        end
        if changed or (not active and not ImGui.IsWindowFocused()) then
            ImGui.CloseCurrentPopup()
        end
        ImGui.EndPopup()
    end
    return result
end

local function parcelGUI()
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    if openGUI then
        openGUI, shouldDrawGUI = ImGui.Begin('BFO Parcel', openGUI)
        ImGui.PushStyleColor(ImGuiCol.Text, 1, 1, 1, 1)
        local pressed

        if shouldDrawGUI then
            if nearestVendor then
                ImGui.Text(string.format("Nearest Parcel Vendor: %s", nearestVendor.DisplayName()))
                ImGui.SameLine()
                if ImGui.SmallButton("Nav to Parcel") then
                    gotoParcelVendor()
                end
            end
            ImGui.SameLine()
            if ImGui.SmallButton("Recheck Nearest") then
                findParcelVendor()
            end
            ImGui.Separator()

            ImGui.Text("Send To:      ")
            ImGui.SameLine()
            --local tmp_name, selected_name = ImGui.InputText("##Send To", parcelTarget, 0)
            --if selected_name then parcelTarget = tmp_name end

            parcelTarget = popupcombo('', parcelTarget, settings.History)

            ImGui.Separator()

            --if not parcelTSItems then
            ImGui.Text("Select Items: ")
            ImGui.SameLine()
            sourceIndex, pressed = ImGui.Combo("##Select Bag", sourceIndex, function(idx) return parcelInv.sendSources[idx].name end, #parcelInv.sendSources)
            if pressed then
                status = "Loading Bag Items..."
                parcelInv:getItems(sourceIndex)
                status = "Idle..."
            end
            ImGui.SameLine()

            if ImGui.SmallButton(ICONS.MD_REFRESH) then
                status = "Loading Bag Items..."
                parcelInv:createContainerInventory()
                parcelInv:getItems(sourceIndex)
                status = "Idle..."
            end

            ImGui.Separator()

            ImGui.Text(string.format("Status: %s", status))

            ImGui.Separator()

            if #parcelInv.items > 0 and parcelTarget:len() >= 4 then
                if ImGui.Button(startParcel and "Cancel" or "Send", 150, 25) then
                    startParcel = not startParcel
                    mq.cmdf("/nav stop")
                    parcelInv:resetState()
                end
            end

            renderItems()
        end

        ImGui.End()
    end
end

mq.imgui.init('parcelGUI', parcelGUI)

mq.bind("/parcel", function()
    openGUI = not openGUI
end
)

LoadSettings()
findParcelVendor()

parcelInv:createContainerInventory()
parcelInv:getItems(sourceIndex)

Output("\aw>>> \ayBFO Parcel tool loaded! Use \at/parcel\ay to open UI!")

-- Global Messaging callback
---@diagnostic disable-next-line: unused-local
local script_actor = actors.register(function(message)
    local msg = message()

    if msg["from"] == mq.TLO.Me.DisplayName() then
        return
    end
    if msg["script"] ~= "BFOParcel" then
        return
    end

    ---@diagnostic disable-next-line: redundant-parameter
    Output("\ayGot Event from(\am%s\ay) event(\at%s\ay)", msg["from"], msg["event"])

    if msg["event"] == "SaveSettings" then
        LoadSettings()
    end
end)

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    doParceling()

    mq.doevents()
    mq.delay(400)
end
