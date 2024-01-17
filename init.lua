local mq                = require('mq')
local ICONS             = require('mq.Icons')
local ImGui             = require('ImGui')
local parcelInv         = require('parcel_inv')

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
local ColumnID_Sent     = 2
local ColumnID_LAST     = ColumnID_Sent + 1

local function findParcelVendor()
    status = "Finding Nearest Parcel Vendor"
    local parcelSpawns = mq.getFilteredSpawns(function(spawn) return string.find(spawn.Surname(), "Parcels") ~= nil end)

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
        ImGui.TableSetupColumn('Sent', bit32.bor(ImGuiTableColumnFlags.NoSort, ImGuiTableColumnFlags.WidthFixed), 20.0,
            ColumnID_Sent)
        ImGui.PopStyleColor()
        ImGui.TableHeadersRow()
        --ImGui.TableNextRow()

        for _, item in ipairs(parcelInv.items) do
            local currentItem = item.Item
            ImGui.TableNextColumn()
            animItems:SetTextureCell((tonumber(currentItem.Icon()) or 500) - 500)
            ImGui.DrawTextureAnimation(animItems, 20, 20)
            ImGui.TableNextColumn()
            if ImGui.Selectable(currentItem.Name(), false, 0) then
                currentItem.Inspect()
            end
            ImGui.TableNextColumn()
            ImGui.Text(item.Sent)
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

            --if not parcelTSItems then
            ImGui.Text("Select Bag: ")
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

findParcelVendor()

parcelInv:createContainerInventory()
parcelInv:getItems(sourceIndex)

print("\aw>>> \ayBFO Parcel tool loaded! Use \at/parcel\ay to open UI!")

while not terminate do
    if mq.TLO.MacroQuest.GameState() ~= "INGAME" then return end

    doParceling()

    mq.doevents()
    mq.delay(400)
end
