--[[
	ChatTags (client, Call Center Place)
	A gold [VIP] in front of the names of VIP Employees (game pass) in Roblox chat. PerkService marks them with
	the player attribute VIP.

	ChatTags.Start()
]]

local Players = game:GetService("Players")
local ReplicatedStorage = game:GetService("ReplicatedStorage")
local TextChatService = game:GetService("TextChatService")

local ShopConfig = require(ReplicatedStorage:WaitForChild("Shared").Config.ShopConfig)

local ChatTags = {}

function ChatTags.Start()
	local ok, err = pcall(function()
		TextChatService.OnIncomingMessage = function(message: TextChatMessage)
			local source = message.TextSource
			local sender = source and Players:GetPlayerByUserId(source.UserId)
			if not sender or sender:GetAttribute("VIP") ~= true then
				return nil
			end
			local properties = Instance.new("TextChatMessageProperties")
			properties.PrefixText = `<font color="{ShopConfig.Vip.NametagColor}">[VIP]</font> {message.PrefixText}`
			return properties
		end
	end)
	if not ok then
		warn(`[ChatTags] can't add VIP chat tags: {err}`)
	end
end

return ChatTags
