local addonName, addonTable = ...

---@class ArcaneMageHelper
ArcaneMageHelper = LibStub("AceAddon-3.0"):NewAddon(addonName, "AceEvent-3.0", "AceConsole-3.0")
local AceGUI = LibStub("AceGUI-3.0")
local AceConfig = LibStub("AceConfig-3.0")
local AceConfigDialog = LibStub("AceConfigDialog-3.0")

local defaults = {
	profile = {
		lowManaThreshold = 30,
		frameWidth = 250,
		frameHeight = 150,
	},
}

local phases = {
	CONSERVE = "Conserve",
	BURN_READY = "Burn Ready",
	MINI_BURN = "Mini Burn",
	FULL_BURN = "Full Burn",
	BURN_RAMP = "Full Burn Ramp",
}

local spells = {
	EVOCATION = 12051,
	ARCANE_SURGE = 365350,
	TOUCH_OF_THE_MAGI = 321507,
	RADIANT_SPARK = 376103,
	ARCANE_BLAST = 30451,
	ARCANE_BARRAGE = 44425,
	ARCANE_MISSILES = 5143,
	NETHER_TEMPEST = 114923,
	ARCANE_ORB = 153626,
	SHIFTING_POWER = 314791,
	CLEARCASTING = 263725,
	NETHER_PRECISION = 264354,
	ARCANE_HARMONY = 332777,
	ARCANE_ECHO = 342231,
	ORB_BARRAGE = 274741,
	PRESENCE_OF_MIND = 205025,
	ARCANE_BOMBARDMENT = 205035,
	RUNE_OF_POWER = 116011,
	MANA_GEM = 759,
}

local warned = {}
local function WarnOncePerInterval(text, interval)
	local t = GetTime()
	if not warned[text] or t - warned[text] > 10 then
		warned[text] = t
		UIErrorsFrame:AddMessage(text, 1, 0, 0)
	end
end

local function SpellRemaining(id, t)
	local start, dur = GetSpellCooldown(id)

	if not dur or dur < 1.2 then
		return 0
	end

	return dur + start - t
end

local function BurnTimeRemaining()
	local time = GetTime()

	local touch = SpellRemaining(spells.TOUCH_OF_THE_MAGI, time)
	local spark = SpellRemaining(spells.RADIANT_SPARK, time)
	local evocation = SpellRemaining(spells.EVOCATION, time)
	local surge = max(0, SpellRemaining(spells.ARCANE_SURGE, time) - 10) -- full burn starts before surge CD finishes
	return max(touch, spark), max(touch, spark, evocation, surge)
end

function ArcaneMageHelper:OnInitialize()
	self.db = LibStub("AceDB-3.0"):New("ArcaneMageHelperDB", defaults)

	self.phase = phases.CONSERVE
	self.mana = UnitPower("player", Enum.PowerType.Mana)
	self.maxMana = UnitPowerMax("player", Enum.PowerType.Mana)
	self.clearcastingStacks = 0
	self.netherPrecision = false
	self.orbBarrage = false
	self.arcaneHarmony = IsSpellKnown(spells.ARCANE_HARMONY)
	self.arcaneEcho = IsSpellKnown(spells.ARCANE_ECHO)
	self.arcaneBombardment = IsSpellKnown(spells.ARCANE_BOMBARDMENT)
	self.arcaneCharges = UnitPower("player", Enum.PowerType.ArcaneCharges)
	self.seenSpark = false

	self:RegisterEvent("UNIT_POWER_UPDATE")
	self:RegisterEvent("UNIT_SPELLCAST_SUCCEEDED")
	self:RegisterEvent("UNIT_AURA")
	self:RegisterEvent("BAG_UPDATE", "Refresh")
	self:RegisterEvent("PLAYER_REGEN_ENABLED", "Refresh")
	self:RegisterEvent("PLAYER_ENTERING_WORLD", "Refresh")

	self:SetupOptions()
	self:SetupUI()
end

function ArcaneMageHelper:UNIT_POWER_UPDATE(event, unit, powerType)
	if unit == "player" then
		if powerType == "MANA" then
			self.mana = UnitPower("player", Enum.PowerType.Mana)
			self.maxMana = UnitPowerMax("player", Enum.PowerType.Mana)
			self:UpdateBars()
		elseif powerType == "ARCANE_CHARGES" then
			self.arcaneCharges = UnitPower("player", Enum.PowerType.ArcaneCharges)
		end
	end
	self:Refresh()
end

local queued = false
local function RefreshNow()
	queued = false
	ArcaneMageHelper:Refresh()
end

local function QueueRefresh()
	if not queued then
		queued = true
		C_Timer.After(0.05, RefreshNow)
	end
end

function ArcaneMageHelper:UNIT_SPELLCAST_SUCCEEDED(event, unit, _, spellID)
	if unit ~= "player" then
		return
	end

	if spellID == spells.EVOCATION then
		self:SetPhase(phases.BURN_RAMP)
	elseif spellID == spells.RADIANT_SPARK then
		local failed = false
		if GetSpellCooldown(spells.TOUCH_OF_THE_MAGI) ~= 0 then
			WarnOncePerInterval("Radiant Spark casted without touch of the magi ready")
			self:SetPhase(phases.CONSERVE)
			failed = true
		elseif self.arcaneCharges < 2 then
			WarnOncePerInterval("Burn started without arcane charges >= 2")
		end

		if not failed then
			self.seenSpark = false

			local siphonStorm = C_UnitAuras.GetAuraDataBySpellName("player", "Siphon Storm", "HELPFUL")

			if siphonStorm then
				self:SetPhase(phases.FULL_BURN)
				if SpellRemaining(spells.ARCANE_SURGE, GetTime()) > 0 then
					WarnOncePerInterval("Arcane Surge still on cooldown after starting full burn sequence")
				end
			else
				self:SetPhase(phases.MINI_BURN)
			end

			if self.arcaneBombardment and UnitHealth("target") / UnitHealthMax("target") < 0.35 then
				C_Timer.After(5, function()
					UIErrorsFrame:AddMessage("Target low health! Use Arcane Barrage before Touch of the Magi ends.", 1, 0.5, 0)
				end)
			end
		end
	elseif spellID == spells.ARCANE_BARRAGE then
		self.arcaneCharges = 0
	elseif spellID == spells.CLEARCASTING then
		self.clearcastingStacks = self.clearcastingStacks + 1
	elseif spellID == spells.ARCANE_BLAST and self.netherPrecision then
		self.netherPrecision = false
	end
	QueueRefresh()
end

function ArcaneMageHelper:UNIT_AURA(event, unit)
	if unit ~= "player" then
		return
	end

	local netherPrecision = AuraUtil.FindAuraByName("Nether Precision", "player", "HELPFUL")
	local orbBarrage = AuraUtil.FindAuraByName("Orb Barrage", "player", "HELPFUL")

	self.netherPrecision = netherPrecision ~= nil
	self.orbBarrage = orbBarrage ~= nil
end

function ArcaneMageHelper:SetPhase(phase)
	self.phase = phase
	self:Refresh()
end

function ArcaneMageHelper:CheckPreCombatBuffs()
	local hasSiphonStorm = AuraUtil.FindAuraByName("Siphon Storm", "player", "HELPFUL")
	local hasManaGemCharges = C_Item.GetItemCount(36799) > 0

	self:ShowWarning(not hasSiphonStorm, self.siphonStormWarning, "Interface/Icons/ability_monk_forcesphere_arcane")
	self:ShowWarning(not hasManaGemCharges, self.manaGemWarning, "Interface/Icons/inv_misc_gem_sapphire_02")
end

function ArcaneMageHelper:ShowWarning(condition, frame, icon)
	if condition then
		frame:Show()
		frame.icon:SetTexture(icon)
	else
		frame:Hide()
	end
end

function ArcaneMageHelper:Refresh()
	self.frame.title:SetText("Arcanic - " .. self.phase)
	if self.phase == phases.CONSERVE then
		self.frame.title:SetTextColor(1, 1, 1)
	elseif self.phase == phases.MINI_BURN then
		self.frame.title:SetTextColor(1, 0.5, 0)
	else
		self.frame.title:SetTextColor(0, 1, 0)
	end
	self:CheckPreCombatBuffs()
	self:UpdateBars()
end

function ArcaneMageHelper:CreateBarFrame(parent)
	local bar = CreateFrame("StatusBar", nil, self.frame)
	bar:SetSize(self.db.profile.frameWidth - 20, 20)
	bar:SetStatusBarTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar:SetMinMaxValues(0, 100)
	bar:SetValue(100)
	bar:SetStatusBarColor(0, 0.5, 0.5)

	bar.Text = bar:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	bar.Text:SetPoint("CENTER", bar)
	bar.Text:SetText("100%")

	bar.BG = bar:CreateTexture(nil, "BACKGROUND")
	bar.BG:SetAllPoints(bar)
	bar.BG:SetTexture("Interface\\TargetingFrame\\UI-StatusBar")
	bar.BG:SetVertexColor(0, 0, 0, 0.5)

	return bar
end

function ArcaneMageHelper:SetupUI()
	self.frame = CreateFrame("Frame", "ArcaneMageHelperFrame", UIParent, "BackdropTemplate")
	self.frame:SetPoint("CENTER")
	self.frame:SetSize(self.db.profile.frameWidth, self.db.profile.frameHeight)
	self.frame:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		tile = true,
		tileSize = 16,
		edgeSize = 16,
		insets = { left = 4, right = 4, top = 4, bottom = 4 },
	})
	self.frame:SetBackdropColor(0, 0, 0, 0.8)
	self.frame:SetMovable(true)
	self.frame:EnableMouse(true)
	self.frame:RegisterForDrag("LeftButton")
	self.frame:SetScript("OnDragStart", self.frame.StartMoving)
	self.frame:SetScript("OnDragStop", self.frame.StopMovingOrSizing)

	self.frame.title = self.frame:CreateFontString(nil, "OVERLAY", "GameFontNormal")
	self.frame.title:SetPoint("TOP", 0, -10)
	self.frame.title:SetText("Arcanic")

	self.frame.manaBar = self:CreateBarFrame(self.frame)
	self.frame.manaBar:SetPoint("TOP", self.frame.title, "BOTTOM", 0, -5)
	self.frame.fullBurnBar = self:CreateBarFrame(self.frame)
	self.frame.fullBurnBar:SetPoint("TOP", self.frame.manaBar, "BOTTOM", 0, -5)
	self.frame.miniBurnBar = self:CreateBarFrame(self.frame)
	self.frame.miniBurnBar:SetPoint("TOP", self.frame.fullBurnBar, "BOTTOM", 0, -5)

	self.manaGemWarning = self:CreateWarningFrame(self.frame)
	self.manaGemWarning:SetPoint("BOTTOMLEFT", 10, 10)

	self.siphonStormWarning = self:CreateWarningFrame(self.frame)
	self.siphonStormWarning:SetPoint("LEFT", self.manaGemWarning, "RIGHT", 10, 0)

	self:UpdateBars()
end

function ArcaneMageHelper:CreateWarningFrame(parent)
	local warningFrame = CreateFrame("Frame", nil, parent, "BackdropTemplate")
	warningFrame:SetSize(30, 30)

	warningFrame.icon = warningFrame:CreateTexture(nil, "OVERLAY")
	warningFrame.icon:SetAllPoints(true)

	warningFrame:SetBackdrop({
		bgFile = "Interface/Tooltips/UI-Tooltip-Background",
		edgeFile = "Interface/Tooltips/UI-Tooltip-Border",
		tile = true,
		tileSize = 8,
		edgeSize = 8,
		insets = { left = 2, right = 2, top = 2, bottom = 2 },
	})
	warningFrame:SetBackdropColor(0, 0, 0, 0.8)
	warningFrame:SetBackdropBorderColor(1, 0, 0)

	return warningFrame
end

local conserveWarned = 0

local function barPercentage(remaining, maxBarCd)
	if remaining < 2 then
		return 100
	end

	if remaining > maxBarCd then
		return 0
	end

	return 100 - (remaining / maxBarCd) * 100
end

local function barText(remaining, ty)
	if remaining > 2 then
		return math.floor(remaining) .. "s"
	end
	return ty .. " Burn Ready"
end

local barsQueued = false
function ArcaneMageHelper:UpdateBars()
	local miniburn, fullburn = BurnTimeRemaining()

	self.frame.miniBurnBar:SetValue(barPercentage(miniburn, 45))
	self.frame.miniBurnBar.Text:SetText(barText(miniburn, "Mini"))
	self.frame.fullBurnBar:SetValue(barPercentage(fullburn, 45))
	self.frame.fullBurnBar.Text:SetText(barText(fullburn, "Full"))

	local mb = self.frame.manaBar

	if self.phase == phases.BURN_RAMP then
		local siphonStorm = C_UnitAuras.GetAuraDataBySpellName("player", "Siphon Storm", "HELPFUL")
		if siphonStorm then
			local dur = siphonStorm.duration - 17
			local rem = (siphonStorm.expirationTime - GetTime()) - 17
			if rem <= 0 or (self.mana / self.maxMana) < 0.15 then
				mb:SetValue(0)
				mb.Text:SetText("Full Burn NOW")
				WarnOncePerInterval("Full Burn! Cast radiant spark and nether precision into burn macro")
			else
				mb:SetValue(100 * rem / dur)
				mb.Text:SetText(math.floor(rem) .. "s until burn")
			end
		else
			WarnOncePerInterval("Siphon Storm expired without a burn")
			self:SetPhase(phases.CONSERVE)
		end
	end

	if self.phase == phases.FULL_BURN or self.phase == phases.MINI_BURN then
		local radiantSpark = nil

		AuraUtil.ForEachAura("target", "HARMFUL", 100, function(aura)
			if aura.isFromPlayerOrPlayerPet and aura.spellId == spells.RADIANT_SPARK then
				radiantSpark = aura
				return true
			end
			return false
		end, true)

		local dur = radiantSpark and radiantSpark.duration or 0
		local rem = radiantSpark and (radiantSpark.expirationTime - GetTime()) or 0
		if rem <= 0 and self.seenSpark then
			mb:SetValue(0)
			mb.Text:SetText("Spark Expired")
			WarnOncePerInterval("Spark expired")
			self:SetPhase(phases.CONSERVE)
		elseif radiantSpark then
			self.seenSpark = true
			mb:SetValue(100 * rem / dur)
			mb.Text:SetText(math.floor(rem) .. "s until spark expires")
		else
			mb:SetValue(100)
			mb.Text:SetText("waiting for radiant spark aura")
		end
	end

	if self.phase == phases.CONSERVE then
		local manaPercent = math.floor(self.mana / self.maxMana * 100)
		if self.maxMana == 0 or manaPercent ~= manaPercent then
			manaPercent = 0.1
		end
		mb:SetValue(manaPercent)
		mb.Text:SetText(manaPercent .. "%")

		if self.phase == phases.CONSERVE and manaPercent < self.db.profile.lowManaThreshold then
			mb:SetStatusBarColor(1, 0.01, 0.1)
			WarnOncePerInterval("Low Mana! Use Arcane Barrage")
		else
			mb:SetStatusBarColor(0, 0.1, 1)
		end
	end

	if fullburn > 0 then
		if not barsQueued then
			barsQueued = true
			C_Timer.After(1, function()
				barsQueued = false
				self:UpdateBars()
			end)
		end
	end
end

function ArcaneMageHelper:SetupOptions()
	self.options = {
		name = "Arcane Mage Helper",
		type = "group",
		args = {
			lowManaThreshold = {
				name = "Low Mana Threshold",
				desc = "Set the mana percentage for the Low Mana warning.",
				type = "range",
				min = 0,
				max = 100,
				step = 1,
				get = function()
					return self.db.profile.lowManaThreshold
				end,
				set = function(_, value)
					self.db.profile.lowManaThreshold = value
				end,
			},
			frameWidth = {
				name = "Frame Width",
				desc = "Set the width of the addon frame.",
				type = "range",
				min = 150,
				max = 600,
				step = 1,
				get = function()
					return self.db.profile.frameWidth
				end,
				set = function(_, value)
					self.db.profile.frameWidth = value
					self.frame:SetWidth(value)
				end,
			},
			frameHeight = {
				name = "Frame Height",
				desc = "Set the height of the addon frame.",
				type = "range",
				min = 100,
				max = 400,
				step = 1,
				get = function()
					return self.db.profile.frameHeight
				end,
				set = function(_, value)
					self.db.profile.frameHeight = value
					self.frame:SetHeight(value)
				end,
			},
		},
	}
	AceConfig:RegisterOptionsTable(addonName, self.options)
	AceConfigDialog:AddToBlizOptions(addonName, addonName .. " - Arcane Mage Helper")
	self:RegisterChatCommand(addonName, "ChatCommand")
end

function ArcaneMageHelper:ChatCommand(input)
	if not input or input:trim() == "" then
		AceConfigDialog:Open(addonName)
	else
		LibStub("AceConfigCmd-3.0"):HandleCommand(addonName, addonName, input)
	end
end
