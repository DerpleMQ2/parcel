local mq = require('mq')
require('lib/bfoutils')
local LIP = require('lib/LIP')
require('lib/ed/utils')
local ICONS = require('mq.Icons')
local ImGui = require('ImGui')
ImGuiCol = ImGuiCol
ImGuiInputTextFlags = ImGuiInputTextFlags
ImGuiTableColumnFlags = ImGuiTableColumnFlags
ImGuiTableFlags = ImGuiTableFlags
ImGuiSelectableFlags = ImGuiSelectableFlags
ImGuiButtonFlags = ImGuiButtonFlags
ImGuiMouseButton = ImGuiMouseButton
ImGuiTreeNodeFlags = ImGuiTreeNodeFlags
ImGuiStyleVar = ImGuiStyleVar
ImVec2 = ImVec2
bit32 = bit32

local openGUI = false
local shouldDrawGUI = false

local terminate = false

local parcelTarget = ""
local startParcel = false
local parcelTSItems = false

local animItems = mq.FindTextureAnimation("A_DragItem")
local bagIndex = 0
local currentSendItemIdx = 1

local status = "Idle..."

local config_dir = mq.TLO.MacroQuest.Path():gsub('\\', '/')
local parcel_settings_file = '/lua/parcel/config/parcel.ini'
local parcel_settings_path = config_dir .. parcel_settings_file

local parcelSettings = {}

local LoadSettings = function()
    CharConfig = mq.TLO.Me.CleanName()

    if file_exists(parcel_settings_path) then
        parcelSettings = LIP.load(parcel_settings_path)
    end
end

local nearestVendor = nil
local bags = {}
local bagNames = {}

---@type table<any>
local items = {}

local function create_container_inventory()
    bags = {}
    bagNames = {}

    for i = 23, 34, 1 do
        local slot = mq.TLO.Me.Inventory(i)
        if slot.Container() and slot.Container() > 0 then
            local bagName = string.format("%s (%d)", slot.Name(), slot.ItemSlot())
            bags[bagName] = slot
            table.insert(bagNames, bagName)
        end
    end
end

-- Converts between ItemSlot and /itemnotify pack numbers
local function to_pack(slot_number)
    return "pack" .. tostring(slot_number - 22)
end

-- Converts between ItemSlot2 and /itemnotify numbers
local function to_bag_slot(slot_number)
    return slot_number + 1
end

local function get_items_in_bag(bagName)
    if not bagName then return end

    status = "Loading Bag Items..."

    local slot = bags[bagName]
    items = {}
    for j = 1, (slot.Container()), 1 do
        if (slot.Item(j)() and not slot.Item(j).NoDrop() and not slot.Item(j).NoRent()) then
            table.insert(items, { Item = slot.Item(j), Sent = ICONS.MD_CLOUD_QUEUE })
        end
    end

    currentSendItemIdx = 1

    status = "Idle..."
end

-- TODO: Update this to be able to find items with various attributes
local function get_all_ts_items()
    status = "Loading TS Items..."
    items = {}
    for i = 23, 34, 1 do
        local slot = mq.TLO.Me.Inventory(i)
        if slot.Container() and slot.Container() > 0 then
            for j = 1, (slot.Container()), 1 do
                if (slot.Item(j)() and not slot.Item(j).NoDrop() and not slot.Item(j).NoRent() and slot.Item(j).Tradeskills() and slot.Item(j).Stackable()) then
                    table.insert(items, { Item = slot.Item(j), Sent = ICONS.MD_CLOUD_QUEUE })
                end
            end
        else
            if (slot() and not slot.NoDrop() and not slot.NoRent() and slot.Tradeskills() and slot.Stackable()) then
                table.insert(items, { Item = slot, Sent = ICONS.MD_CLOUD_QUEUE })
            end
        end
    end

    status = "Idle..."
end

local function findParcelVendor()
    status = "Finding Nearest Parcel Vendor"
    local parcelSpawns = mq.getFilteredSpawns(function(spawn) return string.find(spawn.Surname(), "Parcels") ~= nil end)

    if #parcelSpawns <= 0 then
        --print("\arNo Parcel Vendor Found in Zone!")
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

    print(string.format("\atFound parcel vendor: \am%s", spawn.DisplayName()))

    mq.cmdf("/nav id %d", spawn.ID())
end


local function targetParcelVendor()
    local spawn = findParcelVendor()

    if not spawn then return end

    print(string.format("\atFound parcel vendor: \am%s", spawn.DisplayName()))

    mq.cmdf("/target id %d", spawn.ID())
end

local function doParceling()
    if openGUI and (not nearestVendor or not nearestVendor.ID() or nearestVendor.ID() <= 0) then
        findParcelVendor()
    end

    if not startParcel then return end

    if not nearestVendor then
        print("\arNo Parcel Vendor found in zone!")
        startParcel = false
        return
    end

    if not mq.TLO.Nav.Active() and (nearestVendor.Distance() or 0) > 10 then
        gotoParcelVendor()
    end

    if mq.TLO.Nav.Active() and not mq.TLO.Nav.Paused() then
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

    if mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows").CurrentTabIndex() ~= 3 then
        status = "Selecting Parcel Tab..." ..
            tostring(mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows").CurrentTabIndex())
        mq.TLO.Window("MerchantWnd").Child("MW_MerchantSubWindows").SetCurrentTab(3)
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

    -- send an item
    if currentSendItemIdx > #items then
        currentSendItemIdx = 1
        startParcel = false
        status = "Idle..."
        return
    end

    local item = items[currentSendItemIdx]
    currentSendItemIdx = currentSendItemIdx + 1

    if item["Sent"] == ICONS.MD_CLOUD_DONE then
        return
    end

    status = string.format("Sending: %s", item["Item"].Name())

    mq.cmd("/itemnotify in " ..
        to_pack(item["Item"].ItemSlot()) .. " " .. to_bag_slot(item["Item"].ItemSlot2()) .. " leftmouseup")

    repeat
        mq.delay(10)
    until mq.TLO.Window("MerchantWnd").Child("MW_Send_Button")() == "TRUE" and mq.TLO.Window("MerchantWnd").Child("MW_Send_Button").Enabled()

    item["Sent"] = ICONS.MD_CLOUD_UPLOAD

    mq.cmd("/shift /notify MerchantWnd MW_Send_Button leftmouseup")

    item["Sent"] = ICONS.MD_CLOUD_DONE
end

local ColumnID_ItemIcon = 0
local ColumnID_Item = 1
local ColumnID_Sent = 2
local ColumnID_LAST = ColumnID_Sent + 1

local function renderItems()
    ImGui.Text("Items to Send:")
    if ImGui.BeginTable("BagItemList", ColumnID_LAST, ImGuiTableFlags.Resizable + ImGuiTableFlags.Borders) then
        ImGui.PushStyleColor(ImGuiCol.Text, 255, 0, 255, 1)
        ImGui.TableSetupColumn('Icon', (ImGuiTableColumnFlags.NoSort), 20.0, ColumnID_ItemIcon)
        ImGui.TableSetupColumn('Item',
            (ImGuiTableColumnFlags.NoSort + ImGuiTableColumnFlags.PreferSortDescending + ImGuiTableColumnFlags.WidthFixed),
            300.0, ColumnID_Item)
        ImGui.TableSetupColumn('Sent', (ImGuiTableColumnFlags.NoSort), 20.0, ColumnID_Sent)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()
        --ImGui.TableNextRow()

        for _, item in ipairs(items) do
            local currentItem = item["Item"]
            ImGui.TableNextColumn()
            animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
            ImGui.DrawTextureAnimation(animItems, 20, 20)
            ImGui.TableNextColumn()
            if ImGui.Selectable(currentItem.Name(), false, 0) then
                currentItem.Inspect()
            end
            ImGui.TableNextColumn()
            ImGui.Text(item["Sent"])
        end

        ImGui.EndTable()
    end
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
            local tmp_name, selected_name = ImGui.InputText("##Send To", parcelTarget, 0)
            if selected_name then parcelTarget = tmp_name end

            ImGui.Separator()

            if not parcelTSItems then
                ImGui.Text("Select Bag: ")
                ImGui.SameLine()
                bagIndex, pressed = ImGui.Combo("##Select Bag", bagIndex, bagNames, #bagNames)
                if pressed then
                    get_items_in_bag(bagNames[bagIndex])
                end
                ImGui.SameLine()

                if ImGui.SmallButton(ICONS.MD_REFRESH) then
                    create_container_inventory()
                    get_items_in_bag(bagNames[bagIndex])
                end

                ImGui.Text("Or")
            end

            ImGui.Text("Send all TS Items: ")
            ImGui.SameLine()
            parcelTSItems, pressed = ImGui.Checkbox("##ts_chk", parcelTSItems)
            if pressed then
                if not parcelTSItems then
                    create_container_inventory()
                    get_items_in_bag(bagNames[bagIndex])
                else
                    get_all_ts_items()
                end
            end

            ImGui.Separator()

            ImGui.Text(string.format("Status: %s", status))

            ImGui.Separator()

            if #items > 0 and parcelTarget:len() >= 4 then
                if ImGui.Button(startParcel and "Cancel" or "Send", 150, 25) then
                    startParcel = not startParcel
                    currentSendItemIdx = 1
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

create_container_inventory()

print("\ayBFO Parcel tool loaded! Use \ag/parcel\ay to open UI!")

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    doParceling()

    mq.doevents()
    mq.delay(400) -- equivalent to '400ms'
end
