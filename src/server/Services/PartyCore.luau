--[[
	PartyCore (server, lobby place)
	Cross-server parties, like Blackhawk Rescue Mission 5: every player sits in their own lobby server, and a
	party is shared between those servers. Nobody is teleported to join a party; members only travel when the
	leader starts the shift, and then they all land in the same reserved call center server.

	Where a party lives: MemoryStore (a HashMap keyed by party code), changed only through UpdateAsync so two
	servers can't overwrite each other. One PartyCore runs in each lobby server and looks after that server's
	players. After every change it publishes { c = code, v = version } on the party's MessagingService topic;
	the other members' servers re-read the party and update their players straight away. Every PollInterval
	they also re-read it anyway, so a lost message only delays an update a few seconds.

	Party record:
		Code, Version, Leader (userId), Difficulty, Phase ("open" | "starting" | "launching"),
		StartAt (unix time the countdown ends), Members { [userId]: Member }, Kicked { [userId]: unix time },
		Launch { AccessCode, PrivateServerId, At }?, Note { Id, Text }?, Created
	Member: UserId, Name, DisplayName, Desk, Ready, Server (JobId), Joined, Seen

	Keeping it healthy (every HeartbeatInterval, from each member's server):
	  - members' Seen times are refreshed; a member whose server stopped refreshing for StaleAfter seconds
	    (crashed, lost connection) is dropped, and if that was the leader the longest-serving member leads
	  - the record's expiry is pushed back (PartyTTL), so a party nobody is in any more simply expires
	  - a countdown whose leader's server never launched is cancelled after LaunchTimeout

	Starting: the leader starts once everyone is ready. When the countdown ends, the leader's server reserves a
	call center server, stores the shift details, and writes the access code into the party ("launching").
	Every member's server then teleports its own players with that code (deps.launch). A player whose teleport
	keeps failing is taken out of the party with a message (LaunchFailed).

	PartyCore.new(deps) -> core       deps: see Deps below (MemoryStore, MessagingService, teleports, clock)
	core:Create(player) -> Result
	core:Join(player, code) -> Result
	core:Leave(player)
	core:SetReady(player, ready) / SetDifficulty(player, index) / PickDesk(player, desk) / Kick(player, userId)
	core:Start(player)
	core:PlayerAdded(player) / PlayerRemoving(player)
	core:Tick()                       call about once a second: heartbeats, polling, countdowns
	core:OnMessage(code, data)        a message arrived on the party's topic
	core:LaunchFailed(player, message)
	core:PartyOf(player) -> Party?
	core:Snapshot(party) -> table     the party as the client's LobbyState
]]

export type Member = {
	UserId: number,
	Name: string,
	DisplayName: string,
	Desk: number,
	Ready: boolean,
	Server: string,
	Joined: number,
	Seen: number,
}

export type Party = {
	Code: string,
	Version: number,
	Leader: number,
	Difficulty: number,
	Phase: string,
	StartAt: number,
	Members: { [string]: Member },
	Kicked: { [string]: number },
	Launch: { AccessCode: string, PrivateServerId: string, At: number }?,
	Note: { Id: number, Text: string }?,
	Created: number,
}

export type Result = { Ok: boolean, Message: string }

export type Deps = {
	store: {
		get: (code: string) -> (boolean, any),
		-- UpdateAsync: transform gets the current value (nil if none) and returns the new one, or nil to leave
		-- it alone. Returns ok and the value that was stored (nil if the transform declined).
		update: (code: string, transform: (any) -> any, ttl: number) -> (boolean, any),
		remove: (code: string) -> boolean,
	},
	bus: {
		publish: (topic: string, data: any) -> boolean,
		subscribe: (topic: string, handler: (any) -> ()) -> any, -- a connection with :Disconnect(), or nil
	},
	jobId: string,
	now: () -> number,
	config: any, -- LobbyConfig
	push: (player: any, party: Party?) -> (), -- send this player their party (nil = not in one)
	notice: (player: any, message: string) -> (),
	launch: (players: { any }, party: Party) -> (), -- teleport these players into party.Launch
	reserve: () -> (boolean, string?, string?, string?), -- ok, accessCode, privateServerId, error
	storeShift: (privateServerId: string, info: any) -> (),
	random: Random,
}

type Local = { player: any, code: string? }
type Tracked = {
	party: Party?,
	connection: any,
	lastBeat: number,
	lastPoll: number,
	launched: string?, -- access code we already teleported our members with
	noteSeen: number,
	countdownFor: number, -- StartAt we already tried to launch for
}

local PHASE_NUMBER = { open = 1, starting = 2, launching = 3 }

local PartyCore = {}
PartyCore.__index = PartyCore

local function ok(message: string): Result
	return { Ok = true, Message = message }
end

local function fail(message: string): Result
	return { Ok = false, Message = message }
end

local function key(userId: number): string
	return tostring(userId)
end

local function copy(value: any): any
	if type(value) ~= "table" then
		return value
	end
	local out = {}
	for k, v in value do
		out[k] = copy(v)
	end
	return out
end

local function count(members: { [string]: Member }): number
	local n = 0
	for _ in members do
		n += 1
	end
	return n
end

-- The member who has been in the party longest (lowest Joined, then lowest desk).
local function longestServing(members: { [string]: Member }): Member?
	local best: Member? = nil
	for _, member in members do
		if not best or member.Joined < best.Joined or (member.Joined == best.Joined and member.Desk < best.Desk) then
			best = member
		end
	end
	return best
end

local function firstFreeDesk(members: { [string]: Member }, maxDesks: number): number?
	local taken = {}
	for _, member in members do
		taken[member.Desk] = true
	end
	for desk = 1, maxDesks do
		if not taken[desk] then
			return desk
		end
	end
	return nil
end

function PartyCore.new(deps: Deps)
	local self = setmetatable({}, PartyCore)
	self.deps = deps
	self.config = deps.config
	self.players = {} :: { [string]: Local }
	self.tracked = {} :: { [string]: Tracked }
	self.noteCounter = 0
	return self
end

-- ---------------------------------------------------------------------------
-- Helpers
-- ---------------------------------------------------------------------------

function PartyCore:_now(): number
	return self.deps.now()
end

function PartyCore:_topic(code: string): string
	return self.config.PartyTopicPrefix .. code
end

function PartyCore:_normalize(raw: string): string
	return string.upper((string.gsub(raw, "[^%w]", "")))
end

function PartyCore:_makeCode(): string
	local alphabet = self.config.CodeAlphabet
	local chars = table.create(self.config.CodeLength)
	for i = 1, self.config.CodeLength do
		local n = self.deps.random:NextInteger(1, #alphabet)
		chars[i] = string.sub(alphabet, n, n)
	end
	return table.concat(chars)
end

function PartyCore:_memberFor(player: any, desk: number): Member
	local now = self:_now()
	return {
		UserId = player.UserId,
		Name = player.Name,
		DisplayName = player.DisplayName,
		Desk = desk,
		Ready = false,
		Server = self.deps.jobId,
		Joined = now,
		Seen = now,
	}
end

function PartyCore:_localEntry(player: any): Local
	local id = key(player.UserId)
	local entry = self.players[id]
	if not entry then
		entry = { player = player, code = nil }
		self.players[id] = entry
	end
	entry.player = player
	return entry
end

function PartyCore:_localMembers(code: string): { any }
	local list = {}
	for _, entry in self.players do
		if entry.code == code then
			table.insert(list, entry.player)
		end
	end
	return list
end

function PartyCore:_track(code: string): Tracked
	local tracked = self.tracked[code]
	if not tracked then
		local now = self:_now()
		tracked = {
			party = nil,
			connection = nil,
			lastBeat = now,
			lastPoll = now,
			launched = nil,
			noteSeen = 0,
			countdownFor = 0,
		}
		self.tracked[code] = tracked
		tracked.connection = self.deps.bus.subscribe(self:_topic(code), function(data)
			self:OnMessage(code, data)
		end)
	end
	return tracked
end

function PartyCore:_untrackIfEmpty(code: string)
	if #self:_localMembers(code) > 0 then
		return
	end
	local tracked = self.tracked[code]
	if tracked then
		if tracked.connection then
			pcall(function()
				tracked.connection:Disconnect()
			end)
		end
		self.tracked[code] = nil
	end
end

function PartyCore:_publish(party: Party)
	self.deps.bus.publish(self:_topic(party.Code), { c = party.Code, v = party.Version, from = self.deps.jobId })
end

-- Runs `change` on a fresh copy of the party inside UpdateAsync. `change` returns the party to store, or nil
-- and a reason to leave it unchanged; a third value of true stores it without a new Version (bookkeeping
-- players never see, like heartbeat times). Returns (stored, party or nil, reason).
function PartyCore:_update(
	code: string,
	change: (Party?) -> (Party?, string?, boolean?)
): (boolean, Party?, string?)
	local reason: string? = nil
	local stored, value = self.deps.store.update(code, function(current: any): any
		local party: Party? = if type(current) == "table" then copy(current) else nil
		local new, why, quiet = change(party)
		reason = why
		if new and not (quiet and party) then
			new.Version = (if party then party.Version else 0) + 1
		end
		return new
	end, self.config.PartyTTL)
	if not stored then
		return false, nil, "busy"
	end
	return true, if type(value) == "table" then value :: Party else nil, reason
end

-- Removes members whose server has stopped checking in, and fixes the leader. Never removes `keep`'s players.
function PartyCore:_prune(party: Party, keepServer: string)
	local now = self:_now()
	for id, member in party.Members do
		if member.Server ~= keepServer and now - member.Seen > self.config.StaleAfter then
			party.Members[id] = nil
		end
	end
	for id, at in party.Kicked do
		if now - at > self.config.KickCooldown then
			party.Kicked[id] = nil
		end
	end
	if not party.Members[key(party.Leader)] then
		local next = longestServing(party.Members)
		if next then
			party.Leader = next.UserId
		end
	end
end

function PartyCore:_note(party: Party, text: string)
	self.noteCounter += 1
	party.Note = { Id = math.floor(self:_now() * 1000) % 1e9 + self.noteCounter, Text = text }
end

local REASONS: { [string]: string } = {
	busy = "Parties are busy right now. Try again in a moment.",
	missing = "No party found with that code.",
	started = "That party already started their shift.",
	kicked = "You were removed from that party. Try again later.",
	full = "That party is full.",
	leader = "Only the party leader can do that.",
	notopen = "The shift is already starting.",
	gone = "Your party closed.",
}

-- ---------------------------------------------------------------------------
-- Applying a party to this server's players
-- ---------------------------------------------------------------------------

function PartyCore:_detach(entry: Local, message: string?)
	local code = entry.code
	entry.code = nil
	self.deps.push(entry.player, nil)
	if message then
		self.deps.notice(entry.player, message)
	end
	if code then
		self:_untrackIfEmpty(code)
	end
end

-- Takes a party we just read or wrote and brings this server's members up to date: pushes the new state,
-- tells them who joined or left, detaches anyone no longer in it, and teleports them if it's launching.
function PartyCore:_apply(code: string, party: Party?)
	local tracked = self.tracked[code]
	if not tracked then
		return
	end
	local previous = tracked.party
	if party and previous and party.Version < previous.Version then
		return -- older than what we already showed
	end
	tracked.party = party
	local unchanged = party ~= nil and previous ~= nil and party.Version == previous.Version

	for _, entry in self.players do
		if entry.code == code and not unchanged then
			local id = key(entry.player.UserId)
			if not party then
				self:_detach(entry, REASONS.gone)
			elseif not party.Members[id] then
				local kicked = party.Kicked[id] ~= nil
				self:_detach(entry, if kicked then "The party leader removed you from the party." else REASONS.gone)
			else
				self.deps.push(entry.player, party)
				if previous then
					for otherId, member in party.Members do
						if otherId ~= id and not previous.Members[otherId] then
							self.deps.notice(entry.player, `{member.DisplayName} joined the party.`)
						end
					end
					for otherId, member in previous.Members do
						if otherId ~= id and not party.Members[otherId] then
							local how = if party.Kicked[otherId] then "was removed from" else "left"
							self.deps.notice(entry.player, `{member.DisplayName} {how} the party.`)
						end
					end
					if party.Leader == entry.player.UserId and previous.Leader ~= party.Leader then
						self.deps.notice(entry.player, "You're the party leader now.")
					end
				end
				if previous and party.Note and party.Note.Id ~= tracked.noteSeen then
					self.deps.notice(entry.player, party.Note.Text)
				end
			end
		end
	end
	if party and party.Note then
		tracked.noteSeen = party.Note.Id
	end

	-- Launching: teleport our members into the shared server (once per access code).
	if party and party.Phase == "launching" and party.Launch and tracked.launched ~= party.Launch.AccessCode then
		local members = {}
		for _, player in self:_localMembers(code) do
			if party.Members[key(player.UserId)] then
				table.insert(members, player)
			end
		end
		if #members > 0 then
			tracked.launched = party.Launch.AccessCode
			self.deps.launch(members, party)
		end
	end
	self:_untrackIfEmpty(code)
end

-- Writes a change, applies it here, and tells the other servers.
function PartyCore:_change(code: string, change: (Party?) -> (Party?, string?)): (Party?, string?)
	local stored, party, reason = self:_update(code, change)
	if not stored then
		return nil, "busy"
	end
	if party then
		self:_apply(code, party)
		self:_publish(party)
	end
	return party, reason
end

function PartyCore:_refresh(code: string)
	local tracked = self.tracked[code]
	if not tracked then
		return
	end
	tracked.lastPoll = self:_now()
	local read, value = self.deps.store.get(code)
	if not read then
		return -- MemoryStore hiccup: keep what we have and try again next poll
	end
	self:_apply(code, if type(value) == "table" then value :: Party else nil)
end

-- ---------------------------------------------------------------------------
-- Requests
-- ---------------------------------------------------------------------------

function PartyCore:Create(player: any): Result
	local entry = self:_localEntry(player)
	if entry.code then
		return ok(`You're already in party {entry.code}.`)
	end
	for _ = 1, 6 do
		local code = self:_makeCode()
		local stored, party = self:_update(code, function(existing: Party?)
			if existing then
				return nil, "taken"
			end
			local now = self:_now()
			local id = key(player.UserId)
			return {
				Code = code,
				Version = 0,
				Leader = player.UserId,
				Difficulty = self.config.DefaultDifficulty,
				Phase = "open",
				StartAt = 0,
				Members = { [id] = self:_memberFor(player, 1) },
				Kicked = {},
				Launch = nil,
				Note = nil,
				Created = now,
			}
		end)
		if not stored then
			return fail(REASONS.busy)
		end
		if party then
			entry.code = code
			self:_track(code)
			self:_apply(code, party)
			return ok(`Party {code} is open. Share the code with your crew.`)
		end
	end
	return fail("Couldn't make a party code. Try again.")
end

-- Takes `userId` out of `code` (handing over leadership, closing the party if they were the last one).
function PartyCore:_removeMember(code: string, userId: number)
	local id = key(userId)
	local _, reason = self:_change(code, function(existing: Party?)
		if not existing or not existing.Members[id] then
			return nil, "absent"
		end
		existing.Members[id] = nil
		if count(existing.Members) == 0 then
			return nil, "empty"
		end
		if existing.Leader == userId then
			local next = longestServing(existing.Members)
			existing.Leader = if next then next.UserId else existing.Leader
		end
		return existing
	end)
	if reason == "empty" then
		self.deps.store.remove(code)
	end
end

function PartyCore:Join(player: any, rawCode: string): Result
	local entry = self:_localEntry(player)
	local code = self:_normalize(rawCode)
	if #code ~= self.config.CodeLength then
		return fail(`Party codes are {self.config.CodeLength} letters or numbers.`)
	end
	if entry.code == code then
		return ok("You're already in that party.")
	end
	local current = if entry.code then self.tracked[entry.code] else nil
	if current and current.party and current.party.Phase ~= "open" then
		return fail("Your shift is starting. Finish it first.")
	end

	local id = key(player.UserId)
	local stored, party, why = self:_update(code, function(existing: Party?)
		if not existing then
			return nil, "missing"
		end
		self:_prune(existing, self.deps.jobId)
		if existing.Phase ~= "open" then
			return nil, "started"
		end
		local kickedAt = existing.Kicked[id]
		if kickedAt and self:_now() - kickedAt < self.config.KickCooldown then
			return nil, "kicked"
		end
		local member = existing.Members[id]
		if member then
			-- Rejoining from a new server (or joining twice): same seat, now on this server.
			member.Server = self.deps.jobId
			member.Seen = self:_now()
			return existing
		end
		local desk = firstFreeDesk(existing.Members, self.config.MaxDesks)
		if not desk then
			return nil, "full"
		end
		existing.Members[id] = self:_memberFor(player, desk)
		return existing
	end)
	if not stored then
		return fail(REASONS.busy)
	end
	if not party then
		if why == "missing" then
			return fail(`No party found with code {code}.`)
		elseif why == "full" then
			return fail(`Party {code} is full ({self.config.MaxDesks}/{self.config.MaxDesks}).`)
		end
		return fail(REASONS[why or ""] or REASONS.missing)
	end

	-- In the new party now, so leave the old one.
	local previous = entry.code
	if previous then
		entry.code = nil
		self:_removeMember(previous, player.UserId)
		self:_untrackIfEmpty(previous)
	end
	entry.code = code
	self:_track(code)
	self:_apply(code, party)
	self:_publish(party)
	return ok(`Joined party {code}.`)
end

-- force: leave even while the shift is starting (the player is leaving the game or their teleport failed).
function PartyCore:Leave(player: any, force: boolean?)
	local entry = self.players[key(player.UserId)]
	if not entry or not entry.code then
		return
	end
	local code = entry.code :: string
	local tracked = self.tracked[code]
	if not force and tracked and tracked.party and tracked.party.Phase ~= "open" then
		self.deps.notice(player, "The shift is starting. Too late to leave!")
		return
	end
	entry.code = nil
	self:_removeMember(code, player.UserId)
	if not force then
		self.deps.push(player, nil)
	end
	self:_untrackIfEmpty(code)
end

-- Applies a small change to the player's party: `change(party, member)` edits and returns true, or returns
-- false and a reason to leave it alone (a REASONS key or a message for the player).
function PartyCore:_edit(player: any, change: (Party, Member) -> (boolean, string?))
	local entry = self.players[key(player.UserId)]
	if not entry or not entry.code then
		return
	end
	local id = key(player.UserId)
	local _, reason = self:_change(entry.code, function(existing: Party?)
		if not existing then
			return nil, "gone"
		end
		local member = existing.Members[id]
		if not member then
			return nil, "gone"
		end
		if existing.Phase ~= "open" then
			return nil, "notopen"
		end
		member.Seen = self:_now()
		local changed, why = change(existing, member)
		if not changed then
			return nil, why
		end
		return existing
	end)
	-- A reason is either a REASONS key or a message of its own.
	if reason and reason ~= "gone" then
		self.deps.notice(player, REASONS[reason] or reason)
	end
end

function PartyCore:SetReady(player: any, ready: boolean)
	self:_edit(player, function(_, member)
		if member.Ready == ready then
			return false
		end
		member.Ready = ready
		return true
	end)
end

function PartyCore:SetDifficulty(player: any, index: number)
	if self.config.Difficulties[index] == nil then
		return
	end
	self:_edit(player, function(party, member)
		if party.Leader ~= member.UserId then
			return false, "leader"
		end
		if party.Difficulty == index then
			return false
		end
		party.Difficulty = index
		return true
	end)
end

function PartyCore:PickDesk(player: any, desk: number)
	if desk < 1 or desk > self.config.MaxDesks then
		return
	end
	self:_edit(player, function(party, member)
		if member.Desk == desk then
			return false
		end
		for _, other in party.Members do
			if other.Desk == desk then
				return false, `That's {other.DisplayName}'s desk. Pick a free one.`
			end
		end
		member.Desk = desk
		return true
	end)
end

function PartyCore:Kick(player: any, targetUserId: number)
	if targetUserId == player.UserId then
		return
	end
	local target = key(targetUserId)
	self:_edit(player, function(party, member)
		if party.Leader ~= member.UserId then
			return false, "leader"
		end
		if not party.Members[target] then
			return false
		end
		party.Members[target] = nil
		party.Kicked[target] = self:_now()
		return true
	end)
end

function PartyCore:Start(player: any)
	self:_edit(player, function(party, member)
		if party.Leader ~= member.UserId then
			return false, "leader"
		end
		local ready = 0
		for _, other in party.Members do
			if other.Ready then
				ready += 1
			end
		end
		local total = count(party.Members)
		if ready < total then
			return false, `Not everyone is ready yet ({ready}/{total}).`
		end
		party.Phase = "starting"
		party.StartAt = self:_now() + self.config.StartCountdown
		party.Note = nil
		return true
	end)
end

-- ---------------------------------------------------------------------------
-- Launching
-- ---------------------------------------------------------------------------

function PartyCore:_cancelStart(code: string, message: string)
	self:_change(code, function(existing: Party?)
		if not existing or existing.Phase ~= "starting" then
			return nil
		end
		existing.Phase = "open"
		existing.StartAt = 0
		self:_note(existing, message)
		return existing
	end)
end

-- The countdown ended and this server has the leader: reserve the shared server and send everyone.
function PartyCore:_launch(code: string)
	local tracked = self.tracked[code]
	local party = tracked and tracked.party
	if not party then
		return
	end
	local reserved, accessCode, privateServerId, err = self.deps.reserve()
	if not reserved or not accessCode or not privateServerId then
		self:_cancelStart(code, err or "Couldn't reach the call center. Try starting again.")
		return
	end
	local crew = {}
	for _, member in party.Members do
		table.insert(crew, member.UserId)
	end
	self.deps.storeShift(privateServerId, {
		LobbyCode = code,
		Difficulty = party.Difficulty,
		HostUserId = party.Leader,
		Crew = crew,
	})
	self:_change(code, function(existing: Party?)
		if not existing or existing.Phase ~= "starting" then
			return nil
		end
		existing.Phase = "launching"
		existing.Launch = { AccessCode = accessCode :: string, PrivateServerId = privateServerId :: string, At = self:_now() }
		return existing
	end)
end

-- A member's teleport kept failing: take them out of the party so they can try again.
function PartyCore:LaunchFailed(player: any, message: string)
	local entry = self.players[key(player.UserId)]
	if not entry or not entry.code then
		return
	end
	local code = entry.code :: string
	entry.code = nil
	self:_removeMember(code, player.UserId)
	self.deps.push(player, nil)
	self.deps.notice(player, message)
	self:_untrackIfEmpty(code)
end

-- ---------------------------------------------------------------------------
-- Keeping in sync
-- ---------------------------------------------------------------------------

function PartyCore:_heartbeat(code: string)
	local locals = self:_localMembers(code)
	local changed = false
	local stored, party, why = self:_update(code, function(existing: Party?)
		if not existing then
			return nil, "gone"
		end
		local now = self:_now()
		for _, player in locals do
			local member = existing.Members[key(player.UserId)]
			if member then
				member.Seen = now
				member.Server = self.deps.jobId
			end
		end
		local before, leader, phase = count(existing.Members), existing.Leader, existing.Phase
		self:_prune(existing, self.deps.jobId)
		if existing.Phase == "starting" and now > existing.StartAt + self.config.LaunchTimeout then
			existing.Phase = "open"
			existing.StartAt = 0
			self:_note(existing, "The shift didn't start in time. The leader can start it again.")
		end
		if count(existing.Members) == 0 then
			return nil, "empty"
		end
		changed = count(existing.Members) ~= before or existing.Leader ~= leader or existing.Phase ~= phase
		return existing, nil, not changed -- only Seen times changed: same Version, nothing to show anyone
	end)
	if not stored then
		return
	end
	if party then
		self:_apply(code, party)
		if changed then
			self:_publish(party)
		end
	elseif why == "gone" then
		self:_apply(code, nil) -- expired or closed
	elseif why == "empty" then
		self.deps.store.remove(code)
		self:_apply(code, nil)
	end
end

function PartyCore:Tick()
	local now = self:_now()
	local codes = {}
	for code in self.tracked do
		table.insert(codes, code)
	end
	for _, code in codes do
		local tracked = self.tracked[code]
		if tracked then
			local party = tracked.party
			-- Countdown over: the leader's server launches.
			if party and party.Phase == "starting" and now >= party.StartAt and tracked.countdownFor ~= party.StartAt then
				local leader = self.players[key(party.Leader)]
				if leader and leader.code == code then
					tracked.countdownFor = party.StartAt
					self:_launch(code)
				end
			end
			-- The countdown should have launched by now: check in right away (cancels it if the leader is gone).
			local overdue = party ~= nil and party.Phase == "starting" and now > party.StartAt + self.config.LaunchTimeout
			if self.tracked[code] then
				if overdue or now - tracked.lastBeat >= self.config.HeartbeatInterval then
					tracked.lastBeat = now
					tracked.lastPoll = now
					self:_heartbeat(code)
				elseif now - tracked.lastPoll >= self.config.PollInterval then
					self:_refresh(code)
				end
			end
		end
	end
end

function PartyCore:OnMessage(code: string, data: any)
	if type(data) == "table" and data.from == self.deps.jobId then
		return -- our own change, already applied
	end
	local tracked = self.tracked[code]
	if not tracked then
		return
	end
	if type(data) == "table" and tracked.party and type(data.v) == "number" and data.v <= tracked.party.Version then
		return
	end
	self:_refresh(code)
end

-- ---------------------------------------------------------------------------
-- Players and reads
-- ---------------------------------------------------------------------------

function PartyCore:PlayerAdded(player: any)
	self:_localEntry(player)
end

function PartyCore:PlayerRemoving(player: any)
	self:Leave(player, true)
	self.players[key(player.UserId)] = nil
end

function PartyCore:PartyOf(player: any): Party?
	local entry = self.players[key(player.UserId)]
	if not entry or not entry.code then
		return nil
	end
	local tracked = self.tracked[entry.code]
	return tracked and tracked.party
end

function PartyCore:CodeOf(player: any): string?
	local entry = self.players[key(player.UserId)]
	return entry and entry.code
end

-- The party as the client's LobbyState (Network.Lobby).
function PartyCore:Snapshot(party: Party): any
	local seats = {}
	for _, member in party.Members do
		table.insert(seats, {
			Desk = member.Desk,
			UserId = member.UserId,
			DisplayName = member.DisplayName,
			Username = member.Name,
			Ready = member.Ready,
		})
	end
	table.sort(seats, function(a, b)
		return a.Desk < b.Desk
	end)
	local countdown = 0
	if party.Phase == "starting" then
		countdown = math.clamp(math.ceil(party.StartAt - self:_now()), 0, 255)
	end
	return {
		Revision = party.Version,
		Code = party.Code,
		Phase = PHASE_NUMBER[party.Phase] or 1,
		HostUserId = party.Leader,
		Difficulty = party.Difficulty,
		Countdown = countdown,
		Seats = seats,
	}
end

return PartyCore
