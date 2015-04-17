-- XEP-0355 (Namespace Delegation)
-- Copyright (C) 2015 Jérôme Poisson
--
-- This module is MIT/X11 licensed. Please see the
-- COPYING file in the source package for more information.

-- This module manage namespace delegation, a way to delegate server features
-- to an external entity/component. Only the admin mode is implemented so far

-- TODO: client mode, managing entity error handling

local jid = require("util/jid")
local st = require("util/stanza")
local set = require("util/set")

local delegation_session = module:shared("/*/delegation/session")

if delegation_session.connected_cb == nil then
	-- set used to have connected event listeners
	-- which allow a host to react on events from
	-- other hosts
	delegation_session.connected_cb = set.new()
end
local connected_cb = delegation_session.connected_cb

local _DELEGATION_NS = 'urn:xmpp:delegation:1'
local _FORWARDED_NS = 'urn:xmpp:forward:0'
local _ORI_ID_PREFIX = "IQ_RESULT_"

module:log("debug", "Loading namespace delegation module ");


--> Configuration management <--

local ns_delegations = module:get_option("delegations", {})

local jid2ns = {}
for namespace, ns_data in pairs(ns_delegations) do
	-- "connected" contain the full jid of connected managing entity
	ns_data.connected = nil
	if ns_data.jid then
		if jid2ns[ns_data.jid] == nil then
			jid2ns[ns_data.jid] = {}
		end
		jid2ns[ns_data.jid][namespace] = ns_data
		module:log("debug", "Namespace %s is delegated%s to %s", namespace, ns_data.filtering and " (with filtering)" or "", ns_data.jid)
	else
		module:log("warn", "Ignoring delegation for %s: no jid specified", tostring(namespace))
		ns_delegations[namespace] = nil
	end
end


local function advertise_delegations(session, to_jid)
	-- send <message/> stanza to advertise delegations
	-- as expained in § 4.2
	local message = st.message({from=module.host, to=to_jid})
					  :tag("delegation", {xmlns=_DELEGATION_NS})

	-- we need to check if a delegation is granted because the configuration
	-- can be complicated if some delegations are granted to bare jid
	-- and other to full jids, and several resources are connected.
	local have_delegation = false

	for namespace, ns_data  in pairs(jid2ns[to_jid]) do
		if ns_data.connected == to_jid then
			have_delegation = true
			message:tag("delegated", {namespace=namespace})
			if type(ns_data.filtering) == "table" then
				for _, attribute in pairs(ns_data.filtering) do
					message:tag("attribute", {name=attribute}):up()
				end
				message:up()
			end
		end
	end

	if have_delegation then
		session.send(message)
	end
end

local function set_connected(entity_jid)
	-- set the "connected" key for all namespace managed by entity_jid
	-- if the namespace has already a connected entity, ignore the new one
	local function set_config(jid_)
		for _, ns_data in pairs(jid2ns[jid_]) do
			if ns_data.connected == nil then
				ns_data.connected = entity_jid
			end
		end
	end
	local bare_jid = jid.bare(entity_jid)
	set_config(bare_jid)
	-- We can have a bare jid of a full jid specified in configuration
	-- so we try our luck with both (first connected resource will
	-- manage the namespaces in case of bare jid)
	if bare_jid ~= entity_jid then
		set_config(entity_jid)
		jid2ns[entity_jid] = jid2ns[bare_jid]
	end
end

local function on_presence(event)
	local session = event.origin
	local bare_jid = jid.bare(session.full_jid)

	if jid2ns[bare_jid] or jid2ns[session.full_jid] then
		set_connected(session.full_jid)
		advertise_delegations(session, session.full_jid)
	end
end

local function on_component_connected(event)
	-- method called by the module loaded by the component
	-- /!\ the event come from the component host,
	-- not from the host of this module
	local session = event.session
	local bare_jid = jid.join(session.username, session.host)

	local jid_delegations = jid2ns[bare_jid]
	if jid_delegations ~= nil then
		set_connected(bare_jid)
		advertise_delegations(session, bare_jid)
	end
end

local function on_component_auth(event)
	-- react to component-authenticated event from this host
	-- and call the on_connected methods from all other hosts
	-- needed for the component to get delegations advertising
	for callback in connected_cb:items() do
		callback(event)
	end
end

connected_cb:add(on_component_connected)
module:hook('component-authenticated', on_component_auth)
module:hook('presence/initial', on_presence)


--> delegated namespaces hook <--

local function managing_ent_result(event)
	-- this function manage iq results from the managing entity
	-- it do a couple of security check before sending the
	-- result to the managed entity
	local session, stanza = event.origin, event.stanza
	if stanza.attr.to ~= module.host then
		module:log("warn", 'forwarded stanza result has "to" attribute not addressed to current host, id conflict ?')
		return
	end
	module:unhook("iq-result/host/"..stanza.attr.id, managing_ent_result)

	-- lot of checks to do...
	local delegation = stanza.tags[1]
	if #stanza ~= 1 or delegation.name ~= "delegation" or
		delegation.attr.xmlns ~= _DELEGATION_NS then
		session.send(st.error_reply(stanza, 'modify', 'not-acceptable'))
		return true
	end

	local forwarded = delegation.tags[1]
	if #delegation ~= 1 or forwarded.name ~= "forwarded" or
		forwarded.attr.xmlns ~= _FORWARDED_NS then
		session.send(st.error_reply(stanza, 'modify', 'not-acceptable'))
		return true
	end

	local iq = forwarded.tags[1]
	if #forwarded ~= 1 or iq.name ~= "iq" or #iq ~= 1 then
		session.send(st.error_reply(stanza, 'modify', 'not-acceptable'))
		return true
	end

	local namespace = iq.tags[1].xmlns
	local ns_data = ns_delegations[namespace]
	local original = ns_data[_ORI_ID_PREFIX..stanza.attr.id]

	if stanza.attr.from ~= ns_data.connected or iq.attr.type ~= "result" or
		iq.attr.id ~= original.attr.id or iq.attr.to ~= original.attr.from then
		session.send(st.error_reply(stanza, 'auth', 'forbidden'))
		module:send(st.error_reply(original, 'cancel', 'service-unavailable'))
		return true
	end

	-- at this point eveything is checked,
	-- and we (hopefully) can send the the result safely
	module:send(iq)
end

local function forward_iq(stanza, ns_data)
	local to_jid = ns_data.connected
	local iq_stanza  = st.iq({ from=module.host, to=to_jid, type="set" })
		:tag("delegation", { xmlns=_DELEGATION_NS })
		:tag("forwarded", { xmlns=_FORWARDED_NS })
		:add_child(stanza)
	local iq_id = iq_stanza.attr.id
	-- we save the original stanza to check the managing entity result
	ns_data[_ORI_ID_PREFIX..iq_id] = stanza
	module:log("debug", "stanza forwarded to "..to_jid..": "..tostring(iq_stanza))
	module:hook("iq-result/host/"..iq_id, managing_ent_result)
	module:send(iq_stanza)
end

local function iq_hook(event)
	-- general hook for all the iq which forward delegated ones
	-- and continue normal behaviour else. If a namespace is
	-- delegated but managing entity is offline, a service-unavailable
	-- error will be sent, as requested by the XEP
	local session, stanza = event.origin, event.stanza
	if #stanza == 1 and stanza.attr.type == 'get' or stanza.attr.type == 'set' then
		local namespace = stanza.tags[1].attr.xmlns
		local ns_data = ns_delegations[namespace]

		if ns_data then
			module:log("debug", "Namespace %s is delegated", namespace)
			if ns_data.filtering then
				local first_child = stanza.tags[1]
				for _, attribute in ns_data.filtering do
					-- if any filtered attribute if not present,
					-- we must continue the normal bahaviour
					if not first_child.attr[attribute] then
						module:log("debug", "Filtered attribute %s not present, doing normal workflow", attribute)
						return;
					end
				end
			end
			if not ns_data.connected then
				module:log("warn", "No connected entity to manage "..namespace)
				session.send(st.error_reply(stanza, 'cancel', 'service-unavailable'))
			else
				local managing_entity = ns_data.connected
				module:log("debug", "Entity %s is managing %s", managing_entity, namespace)
				forward_iq(stanza, ns_data)
			end
			return true
		else
			-- we have no delegation, we continue normal behaviour
			return
		end
	end
end

module:hook("iq/self", iq_hook, 2^32)
module:hook("iq/host", iq_hook, 2^32)
