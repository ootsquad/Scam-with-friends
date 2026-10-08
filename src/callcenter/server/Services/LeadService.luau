--[[
	LeadService (server, Call Center Place)
	Every player gets their own list of made-up leads (people to call) with random personas and avatars
	(AvatarService dresses a rig for each one).
	Scammed leads get replaced with new ones; leads who hung up on you won't pick up for a while.

	LeadService.Start()
	LeadService.Get(player) -> { LeadRecord }
	LeadService.Find(player, id) -> LeadRecord?
	LeadService.RandomAvailable(player) -> LeadRecord?
	LeadService.SetStatus(player, lead, status)
	LeadService.MarkScammed(player, lead) / Block(player, lead)
	LeadService.Public(lead) -> Network.Call Lead
	LeadService.IsReady(player) -> boolean     the client has loaded the Phone app and can receive call packets
	LeadService.ReadyPlayers() -> { Player }
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")

local Shared = ReplicatedStorage:WaitForChild("Shared")
local CallConfig = require(Shared.Config.CallConfig)
local Call = require(Shared:WaitForChild("Network")).Call
local Personas = require(script.Parent.Parent.Data.Personas)
local AvatarService = require(script.Parent.AvatarService)

local Status = CallConfig.LeadStatus

export type LeadRecord = {
	Id: number,
	DisplayName: string,
	Username: string,
	Tag: string,
	Status: number,
	VoiceId: string,
	Persona: Personas.Persona,
	Look: Personas.Look,
	Slot: number,
	Memory: { string }, -- recaps of earlier calls with this lead, oldest first (CallService)
}

local LeadService = {}

local random = Random.new()
local leadsOf: { [Player]: { LeadRecord } } = {}
local ready: { [Player]: boolean } = {}
local nextId = 0

local function newLead(slot: number): LeadRecord
	nextId = nextId % 65000 + 1
	local generated = Personas.new(random)
	AvatarService.Generate(nextId, generated.Look.Skin)
	return {
		Id = nextId,
		DisplayName = generated.DisplayName,
		Username = generated.Username,
		Tag = generated.Tag,
		Status = Status.Available,
		VoiceId = generated.VoiceId,
		Persona = generated.Persona,
		Look = generated.Look,
		Slot = slot,
		Memory = {},
	}
end

function LeadService.Public(lead: LeadRecord)
	return {
		Id = lead.Id,
		DisplayName = lead.DisplayName,
		Username = lead.Username,
		Tag = lead.Tag,
		Status = lead.Status,
		Look = lead.Look,
	}
end

function LeadService.Get(player: Player): { LeadRecord }
	local leads = leadsOf[player]
	if not leads then
		leads = {}
		for slot = 1, CallConfig.LeadsPerPlayer do
			leads[slot] = newLead(slot)
		end
		leadsOf[player] = leads
	end
	return leads
end

local function snapshot(player: Player)
	local out = {}
	for _, lead in LeadService.Get(player) do
		table.insert(out, LeadService.Public(lead))
	end
	return out
end

local function push(player: Player)
	if ready[player] and player.Parent then
		Call.packets.Leads.sendTo(snapshot(player), player)
	end
end

function LeadService.Find(player: Player, id: number): LeadRecord?
	for _, lead in LeadService.Get(player) do
		if lead.Id == id then
			return lead
		end
	end
	return nil
end

function LeadService.RandomAvailable(player: Player): LeadRecord?
	local available = {}
	for _, lead in LeadService.Get(player) do
		if lead.Status == Status.Available then
			table.insert(available, lead)
		end
	end
	if #available == 0 then
		return nil
	end
	return available[random:NextInteger(1, #available)]
end

function LeadService.SetStatus(player: Player, lead: LeadRecord, status: number)
	if lead.Status ~= status then
		lead.Status = status
		push(player)
	end
end

-- Replaces a lead in its slot (if it's still there) after a delay.
local function replaceLater(player: Player, lead: LeadRecord, delaySeconds: number)
	task.delay(delaySeconds, function()
		local leads = leadsOf[player]
		if leads and leads[lead.Slot] == lead then
			AvatarService.Remove(lead.Id)
			leads[lead.Slot] = newLead(lead.Slot)
			push(player)
		end
	end)
end

function LeadService.MarkScammed(player: Player, lead: LeadRecord)
	LeadService.SetStatus(player, lead, Status.Scammed)
	replaceLater(player, lead, CallConfig.ReplaceLeadAfter)
end

function LeadService.Block(player: Player, lead: LeadRecord)
	LeadService.SetStatus(player, lead, Status.Blocked)
	task.delay(CallConfig.BlockedFor, function()
		if lead.Status == Status.Blocked then
			LeadService.SetStatus(player, lead, Status.Available)
		end
	end)
end

function LeadService.IsReady(player: Player): boolean
	return ready[player] == true
end

function LeadService.ReadyPlayers(): { Player }
	local out = {}
	for player in ready do
		if player.Parent then
			table.insert(out, player)
		end
	end
	return out
end

function LeadService.Start()
	Call.queries.GetLeads.listen(function(_: nil, player: Player)
		ready[player] = true
		return snapshot(player)
	end)
	Players.PlayerRemoving:Connect(function(player)
		for _, lead in leadsOf[player] or {} do
			AvatarService.Remove(lead.Id)
		end
		leadsOf[player] = nil
		ready[player] = nil
	end)
end

return LeadService
