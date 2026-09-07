extends Node
## Transport, roster and chat. Autoloaded as `Net`.
##
## Shape of the session (see docs/DECISIONS.md D-004): the host is peer 1, runs
## the authoritative match, and also plays. This node owns three things and
## deliberately nothing else:
##
##   * the ENet peer and its lifecycle,
##   * the roster — who is here, what they are called, which team they are on,
##   * lobby chat.
##
## Match rules, scoring and spawning live in `MatchState`. Keeping them apart
## means a disconnect during a match is handled in exactly one place, and the
## lobby can be exercised without any match code loaded.
##
## The roster is host-authoritative: clients never mutate it directly, they send
## a request and the host broadcasts the new roster. With a cap of eight players
## the whole roster is a few hundred bytes, so pushing it whole on every change
## is simpler and less bug-prone than diffing it.

const DEFAULT_PORT := 27015
const MAX_NAME_LENGTH := 16
const CHAT_MAX_LENGTH := 160
const CONNECT_TIMEOUT := 8.0

## Reasons a session ended, for the message shown on the way back to the menu.
enum Leave {
	LOCAL_REQUEST,
	HOST_CLOSED,
	CONNECTION_LOST,
	CONNECTION_FAILED,
	LOBBY_FULL,
	MATCH_IN_PROGRESS,
}

signal roster_changed()
## A peer has gone, and whatever they left behind in the world is now orphaned.
## `MatchState` listens for this to clear up their Gub — the roster is this
## node's business, but a body standing in the arena is not.
signal player_left(peer_id: int)
signal joined_lobby()
signal join_failed(message: String)
signal left_lobby(reason: Leave, message: String)
signal chat_received(peer_id: int, text: String)
signal config_changed()
signal match_start_requested()
## The host has ended the match for everyone: back to the lobby, together.
signal return_to_lobby_requested()
## The host wants the same match again, same roster, same settings.
signal rematch_requested()

## peer_id -> {name: String, team: int, ready: bool}
var players: Dictionary = {}
var config: MatchConfig = MatchConfig.new()

var is_host: bool = false
var in_session: bool = false
## True in a solo session with no socket. Everything else about it — authority,
## RPC shape, the roster — is identical to hosting, on purpose.
var is_offline: bool = false
## Set by MatchState; the host refuses new joiners into a running match unless
## they are joining as spectators.
var match_running: bool = false

var _bound_port: int = 0
var _connect_timer: SceneTreeTimer = null

## The endpoint the invite code advertises when the host has a public address
## configured, resolved once when the lobby opens. Empty means the ordinary
## LAN/tailnet path is in use. See `_resolve_public_address`.
var _public_ip: String = ""
var _public_port: int = 0
## The one line the lobby shows instead of the scope caption when a public
## address was typed and could not be used. Empty in every ordinary case,
## including the far more common one of no public address at all.
var _public_problem: String = ""

## Set by `tools/net_loopback.gd` before it hosts. Two copies of this project on
## one machine share Godot's user data directory — it is keyed on the project
## *name*, not the path — so the harness reads the `public_address` of whoever
## is running it. Without this, a developer who has set up a playit tunnel gets
## a loopback test that resolves their tunnel's hostname over real DNS and
## encodes a real public address into a code meant to dial 127.0.0.1.
var ignore_public_address: bool = false


func _ready() -> void:
	multiplayer.peer_connected.connect(_on_peer_connected)
	multiplayer.peer_disconnected.connect(_on_peer_disconnected)
	multiplayer.connected_to_server.connect(_on_connected_to_server)
	multiplayer.connection_failed.connect(_on_connection_failed)
	multiplayer.server_disconnected.connect(_on_server_disconnected)


# ---------------------------------------------------------------- session ---

func host_lobby(port: int = DEFAULT_PORT) -> bool:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_server(port, MatchConfig.MAX_PLAYERS)
	if err != OK:
		join_failed.emit("Could not open port %d (error %d).\nAnother copy of the game may already be hosting." % [port, err])
		return false

	multiplayer.multiplayer_peer = peer
	is_host = true
	in_session = true
	_bound_port = port
	config = MatchConfig.new()
	# Once, here, rather than inside `invite_code()`: see `_resolve_public_address`.
	_resolve_public_address()

	players = {1: _make_player(Settings.sanitized_player_name(), 0)}
	roster_changed.emit()
	joined_lobby.emit()
	return true


## Start a one-player session that opens no port at all.
##
## `OfflineMultiplayerPeer` reports itself as peer 1 and as the server, so every
## `is_host` branch, every `@rpc` call and every authority check downstream takes
## exactly the path it would take when hosting for real — the `rpc()` half simply
## reaches nobody, and the `rpc()`-then-call-locally pattern used throughout the
## game still delivers the local half. That is the point: the testbeds and any
## future single-player mode exercise the shipping code rather than a parallel
## offline branch that can rot without anyone noticing.
func start_offline() -> void:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	multiplayer.multiplayer_peer = OfflineMultiplayerPeer.new()
	is_host = true
	in_session = true
	is_offline = true
	_bound_port = 0
	_clear_public_address()
	config = MatchConfig.new()

	players = {1: _make_player(Settings.sanitized_player_name(), 0)}
	roster_changed.emit()
	joined_lobby.emit()


func join_lobby(code: String) -> bool:
	var endpoint := InviteCode.decode(code)
	if endpoint.is_empty():
		join_failed.emit("\"%s\" is not a valid invite code." % code.strip_edges())
		return false
	return join_address(endpoint["ip"], endpoint["port"])


## Dial a host directly. `ip` is a dotted IPv4 literal and nothing here cares
## where it came from or what kind of address it is: a LAN address, a tailnet
## address and a playit anycast address are all just four bytes to ENet, which
## speaks plain UDP to whatever it is pointed at. That is why routing the game
## through a tunnel needed no change at all on the joining side (D-028).
func join_address(ip: String, port: int) -> bool:
	leave_lobby(Leave.LOCAL_REQUEST, "", false)

	var peer := ENetMultiplayerPeer.new()
	var err := peer.create_client(ip, port)
	if err != OK:
		join_failed.emit("Could not reach %s:%d (error %d)." % [ip, port, err])
		return false

	multiplayer.multiplayer_peer = peer
	is_host = false
	in_session = true
	players.clear()
	roster_changed.emit()

	# ENet reports an unreachable host by simply never connecting, so put a
	# clock on it rather than leaving the player on a dead "Connecting..." screen.
	_connect_timer = get_tree().create_timer(CONNECT_TIMEOUT)
	_connect_timer.timeout.connect(_on_connect_timeout)
	return true


func leave_lobby(reason: Leave = Leave.LOCAL_REQUEST, message: String = "",
		announce: bool = true) -> void:
	_cancel_connect_timer()
	if multiplayer.multiplayer_peer != null \
			and not multiplayer.multiplayer_peer is OfflineMultiplayerPeer:
		multiplayer.multiplayer_peer.close()
	multiplayer.multiplayer_peer = null
	var was_in_session := in_session
	is_host = false
	in_session = false
	is_offline = false
	match_running = false
	_clear_public_address()
	players.clear()
	roster_changed.emit()
	if announce and was_in_session:
		left_lobby.emit(reason, message)


# ------------------------------------------------------------------ roster ---

func local_id() -> int:
	if multiplayer.multiplayer_peer == null:
		return 0
	return multiplayer.get_unique_id()


func has_player(peer_id: int) -> bool:
	return players.has(peer_id)


func player_name(peer_id: int) -> String:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("name", "Gub")


func player_team(peer_id: int) -> int:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("team", MatchConfig.TEAM_NONE)


func is_ready(peer_id: int) -> bool:
	var info: Dictionary = players.get(peer_id, {})
	return info.get("ready", false)


func peer_ids() -> Array:
	var ids := players.keys()
	ids.sort()
	return ids


func player_count() -> int:
	return players.size()


## True when the host is allowed to press Start.
func can_start_match() -> bool:
	if not is_host or players.size() < MatchConfig.MIN_PLAYERS:
		return false
	for peer_id: int in players:
		if peer_id != 1 and not is_ready(peer_id):
			return false
	if config.mode == MatchConfig.Mode.TEAMS:
		# Every team that exists must have someone on it, or a team wins by
		# default the moment the match starts.
		var occupied := {}
		for peer_id: int in players:
			occupied[player_team(peer_id)] = true
		if occupied.size() < 2:
			return false
	return true


func _make_player(display_name: String, team: int) -> Dictionary:
	return {"name": display_name, "team": team, "ready": false}


## Put the next joiner on whichever team is smallest, so lobbies self-balance.
func _smallest_team() -> int:
	if config.mode != MatchConfig.Mode.TEAMS:
		return 0
	var counts := PackedInt32Array()
	counts.resize(config.team_count)
	counts.fill(0)
	for peer_id: int in players:
		var team := player_team(peer_id)
		if team >= 0 and team < counts.size():
			counts[team] += 1
	var best := 0
	for i in counts.size():
		if counts[i] < counts[best]:
			best = i
	return best


static func sanitize_name(raw: String, fallback: String = "Gub") -> String:
	var text := raw.strip_edges()
	var out := ""
	for c in text:
		# Control characters would let a name break the nameplate or the chat log.
		if c.unicode_at(0) < 32:
			continue
		out += c
		if out.length() >= MAX_NAME_LENGTH:
			break
	out = out.strip_edges()
	return out if not out.is_empty() else fallback


## Names must be distinct or the nameplates above two Gubs become useless.
func _unique_name(desired: String, for_peer: int) -> String:
	var taken := {}
	for peer_id: int in players:
		if peer_id != for_peer:
			taken[player_name(peer_id).to_lower()] = true
	if not taken.has(desired.to_lower()):
		return desired
	for suffix in range(2, 100):
		var tag := " (%d)" % suffix
		var trimmed := desired.substr(0, MAX_NAME_LENGTH - tag.length())
		var candidate := trimmed + tag
		if not taken.has(candidate.to_lower()):
			return candidate
	return desired


# ------------------------------------------------------- signal plumbing ----

func _on_peer_connected(peer_id: int) -> void:
	# The host waits for the newcomer to introduce itself before adding it to
	# the roster; a peer with no name yet would flash as a blank row.
	if not is_host:
		return
	if players.size() >= config.max_players:
		_reject.rpc_id(peer_id, Leave.LOBBY_FULL, "This lobby is full.")
		return
	if match_running:
		_reject.rpc_id(peer_id, Leave.MATCH_IN_PROGRESS,
			"That match has already started.")
		return


func _on_peer_disconnected(peer_id: int) -> void:
	if not is_host:
		return
	if players.erase(peer_id):
		_announce_departure.rpc(peer_id)
		_announce_departure(peer_id)
		_broadcast_roster()
		roster_changed.emit()


## Told to everyone, not just the host, because every peer is carrying its own
## copy of the departed player's Gub. Before this existed a client who alt-F4'd
## mid-match left their Gub standing in the arena on all seven other machines,
## for the rest of the match — a permanently motionless target that could still
## be thrown at and still counted toward "last Gub standing".
@rpc("authority", "call_remote", "reliable")
func _announce_departure(peer_id: int) -> void:
	player_left.emit(peer_id)


func _on_connected_to_server() -> void:
	_cancel_connect_timer()
	_request_join.rpc_id(1, Settings.sanitized_player_name())


func _on_connection_failed() -> void:
	_cancel_connect_timer()
	leave_lobby(Leave.CONNECTION_FAILED, "", false)
	join_failed.emit("Could not connect. Check the invite code, and that the host has the game open.")


func _on_server_disconnected() -> void:
	leave_lobby(Leave.HOST_CLOSED, "The host closed the lobby.")


func _on_connect_timeout() -> void:
	_connect_timer = null
	if in_session and not is_host and players.is_empty():
		leave_lobby(Leave.CONNECTION_FAILED, "", false)
		join_failed.emit("Timed out reaching the host.\nIf they are not on your network, they need playit.gg running (or UDP %d forwarded)." % DEFAULT_PORT)


func _cancel_connect_timer() -> void:
	if _connect_timer != null and _connect_timer.timeout.is_connected(_on_connect_timeout):
		_connect_timer.timeout.disconnect(_on_connect_timeout)
	_connect_timer = null


# --------------------------------------------------------------- transfer ---

func _broadcast_roster() -> void:
	_sync_roster.rpc(players, config.to_dict())


@rpc("any_peer", "call_remote", "reliable")
func _request_join(desired_name: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if players.size() >= config.max_players:
		_reject.rpc_id(peer_id, Leave.LOBBY_FULL, "This lobby is full.")
		return
	var clean := _unique_name(sanitize_name(desired_name), peer_id)
	players[peer_id] = _make_player(clean, _smallest_team())
	_broadcast_roster()
	roster_changed.emit()


@rpc("authority", "call_remote", "reliable")
func _sync_roster(roster: Dictionary, config_data: Dictionary) -> void:
	var was_empty := players.is_empty()
	players = roster
	config.apply_dict(config_data)
	roster_changed.emit()
	config_changed.emit()
	if was_empty and players.has(local_id()):
		joined_lobby.emit()


@rpc("authority", "call_remote", "reliable")
func _reject(reason: Leave, message: String) -> void:
	leave_lobby(reason, "", false)
	join_failed.emit(message)


# ------------------------------------------------------- roster mutations ---
#
# Each of these is "ask the host to change my row". The host *is* the host, so it
# calls the handler directly and only a client sends. Written the other way round
# — send unconditionally, then call locally if we are the host — the host asks
# peer 1 to do something, and peer 1 is itself: Godot refuses with `RPC on
# yourself is not allowed by selected mode`, once per chat line, ready toggle,
# team pick and rename, for the whole session. Nothing was lost, because the
# local call did the work, but the log filled up.
#
# `OfflineMultiplayerPeer` swallows `rpc_id` silently, so no testbed could see
# this. It took two real processes to find (`tools/net_test.sh`).

func set_ready(value: bool) -> void:
	if is_host:
		_request_ready(value)
	else:
		_request_ready.rpc_id(1, value)


@rpc("any_peer", "call_remote", "reliable")
func _request_ready(value: bool) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1  # host calling into itself
	if not players.has(peer_id):
		return
	players[peer_id]["ready"] = bool(value)
	_broadcast_roster()
	roster_changed.emit()


func set_team(team: int) -> void:
	if is_host:
		_request_team(team)
	else:
		_request_team.rpc_id(1, team)


@rpc("any_peer", "call_remote", "reliable")
func _request_team(team: int) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id) or config.mode != MatchConfig.Mode.TEAMS:
		return
	players[peer_id]["team"] = clampi(int(team), 0, config.team_count - 1)
	_broadcast_roster()
	roster_changed.emit()


func set_name_local(new_name: String) -> void:
	Settings.set_value("player_name", new_name)
	if not in_session:
		return
	if is_host:
		_request_rename(new_name)
	else:
		_request_rename.rpc_id(1, new_name)


@rpc("any_peer", "call_remote", "reliable")
func _request_rename(new_name: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id):
		return
	players[peer_id]["name"] = _unique_name(sanitize_name(new_name), peer_id)
	_broadcast_roster()
	roster_changed.emit()


## Host only. Pushes an edited match configuration to everyone.
func update_config(new_config: MatchConfig) -> void:
	if not is_host:
		return
	config.apply_dict(new_config.to_dict())
	# Changing team count can strand players on a team that no longer exists.
	if config.mode == MatchConfig.Mode.TEAMS:
		for peer_id: int in players:
			var team: int = players[peer_id].get("team", 0)
			if team < 0 or team >= config.team_count:
				players[peer_id]["team"] = _smallest_team()
	_broadcast_roster()
	roster_changed.emit()
	config_changed.emit()


# ------------------------------------------------------------------- chat ---

func send_chat(text: String) -> void:
	var clean := text.strip_edges().substr(0, CHAT_MAX_LENGTH)
	if clean.is_empty():
		return
	if is_host:
		_submit_chat(clean)
	else:
		_submit_chat.rpc_id(1, clean)


@rpc("any_peer", "call_remote", "reliable")
func _submit_chat(text: String) -> void:
	if not is_host:
		return
	var peer_id := multiplayer.get_remote_sender_id()
	if peer_id == 0:
		peer_id = 1
	if not players.has(peer_id):
		return
	var clean := String(text).strip_edges().substr(0, CHAT_MAX_LENGTH)
	if clean.is_empty():
		return
	_deliver_chat.rpc(peer_id, clean)
	_deliver_chat(peer_id, clean)


@rpc("authority", "call_remote", "reliable")
func _deliver_chat(peer_id: int, text: String) -> void:
	chat_received.emit(peer_id, text)


# ------------------------------------------------------------ match start ---

## Host only. Tells everyone to load the arena.
func request_match_start() -> void:
	if not is_host or not can_start_match():
		return
	_begin_match.rpc()
	_begin_match()


@rpc("authority", "call_remote", "reliable")
func _begin_match() -> void:
	match_running = true
	match_start_requested.emit()


## Host only. Ends the match for everybody and sends the whole lobby home.
##
## Without this the host's "back to the lobby" button moved exactly one person:
## every client stayed sitting on a results screen with no way out but leaving
## the session entirely. A match is a thing the lobby does together, so ending
## one is a broadcast rather than a local navigation.
func request_return_to_lobby() -> void:
	if not is_host:
		return
	match_running = false
	_return_to_lobby.rpc()
	_return_to_lobby()


@rpc("authority", "call_remote", "reliable")
func _return_to_lobby() -> void:
	match_running = false
	return_to_lobby_requested.emit()


## Host only. Run it again — same roster, same settings, same map seed.
##
## The seed is deliberately left alone. "Rematch" is a request for another go at
## the match everyone just agreed to, and quietly handing them a different island
## would be a different request. Rerolling the map is a lobby control.
func request_rematch() -> void:
	if not is_host:
		return
	match_running = true
	_rematch.rpc()
	_rematch()


@rpc("authority", "call_remote", "reliable")
func _rematch() -> void:
	match_running = true
	rematch_requested.emit()


# ------------------------------------------------------------- addressing ---

## Interfaces belonging to a mesh VPN, by name. Matched case-insensitively as a
## substring, so `tailscale0` and Windows' friendly `Tailscale` both hit.
## Deliberately short and specific: a loose token like `utun` would also match
## every unrelated VPN on macOS and hand out its address instead.
const MESH_INTERFACES: Array[String] = ["tailscale", "zerotier"]


## Which of this machine's addresses to put in an invite code.
##
## The order is the whole point, and it is not the obvious one: a **mesh VPN**
## address beats a LAN address, because it reaches both. Two players on the same
## tailnet connect straight across the LAN when they happen to share one, so a
## tailnet code works at the kitchen table *and* across the country, while a LAN
## code only works at the table. The LAN address wins only when no mesh is up.
##
## Getting this backwards is not a visible failure. It hands out a well-formed
## code encoding an address the other player cannot route to, and the join fails
## looking like a firewall problem rather than an addressing one.
##
## Pure, and takes the interface list rather than reading it, so it can be
## tested against machines this is not one of — see `tools/invite_codes.gd`.
static func select_ipv4(interfaces: Array) -> String:
	var mesh: String = ""
	var lan: String = ""
	var other: String = ""
	for interface: Dictionary in interfaces:
		var meshed := _names_a_mesh(interface)
		for address: String in interface.get("addresses", []):
			if not _is_usable_ipv4(address):
				continue
			if meshed or _is_mesh_range(address):
				if mesh.is_empty():
					mesh = address
			elif _is_lan(address):
				if lan.is_empty():
					lan = address
			elif other.is_empty():
				other = address
	if not mesh.is_empty():
		return mesh
	if not lan.is_empty():
		return lan
	return other if not other.is_empty() else "127.0.0.1"


static func _names_a_mesh(interface: Dictionary) -> bool:
	var label := ("%s %s" % [interface.get("name", ""), interface.get("friendly", "")]).to_lower()
	for token: String in MESH_INTERFACES:
		if label.contains(token):
			return true
	return false


## 100.64.0.0/10 — the shared-address block Tailscale and ZeroTier allocate
## from. An ISP doing carrier NAT uses the same block, but that lands on the
## router's WAN side rather than on an interface of this machine, so seeing it
## here means a mesh in every ordinary case.
static func _is_mesh_range(address: String) -> bool:
	if not address.begins_with("100."):
		return false
	var second := address.split(".")[1].to_int()
	return second >= 64 and second <= 127


static func _is_lan(address: String) -> bool:
	return address.begins_with("192.168.") or address.begins_with("10.") \
			or _is_carrier_private(address)


static func _is_carrier_private(address: String) -> bool:
	if not address.begins_with("172."):
		return false
	var second := address.split(".")[1].to_int()
	return second >= 16 and second <= 31


## Loopback is useless to anyone else, and 169.254.x is what an interface gets
## when DHCP failed — a code built from either cannot be joined.
static func _is_usable_ipv4(address: String) -> bool:
	return address.count(".") == 3 and not address.begins_with("127.") \
			and not address.begins_with("169.254.")


# ------------------------------------------------------- a public address ---
#
# What a mesh VPN cannot fix. `select_ipv4` above picks the best address *this
# machine has*, and on a home connection behind NAT that is a private one: it
# reaches the building, and nothing further, unless every player installs
# Tailscale too. That worked and nobody enjoyed it — six people each making an
# account and joining a tailnet before anyone throws a spear.
#
# playit.gg moves the cost onto the one person who was already doing setup. The
# host runs the playit agent, which holds a UDP tunnel open to a public endpoint
# like `angry-gub.at.ply.gg:41235` and forwards it to a local port. Players
# install nothing. The endpoint is stable for the life of the tunnel, so it can
# be typed once into Settings and forgotten.
#
# The game does not talk to playit and knows nothing about it: this is a string
# the host types, resolved to an IPv4 and put in the code in place of the local
# one. See docs/DECISIONS.md D-028.


## Split a typed public address into `{"host": String, "port": int}`, or return
## an empty Dictionary if it is not one.
##
## Forgiving about whitespace, because this arrives via a clipboard and a
## trailing newline is the natural state of anything that has; strict about
## everything else, because a half-understood address is worse than a rejected
## one. It would encode into a code that looks perfectly valid and dials
## nowhere, and the player it fails for would read that as the host being
## offline.
##
## Static, and does no DNS, so the parsing can be tested exhaustively with no
## network and no socket — `tools/invite_codes.gd`. The lookup is a separate
## step in `_resolve_public_address`.
static func parse_public_address(raw: String) -> Dictionary:
	# `strip_escapes` takes out every control character wherever it sits,
	# which covers the newline a clipboard adds; spaces go separately.
	var text := raw.strip_escapes().replace(" ", "")
	# Exactly one colon. Zero is a bare hostname with no port, which cannot be
	# guessed at — playit allocates the public port and it is never 27015. Two
	# or more is an IPv6 address, which this format cannot carry and the
	# six-byte code could not hold anyway.
	var parts := text.split(":")
	if parts.size() != 2:
		return {}
	var host := String(parts[0])
	var port_text := String(parts[1])
	if host.is_empty() or not _is_digits(port_text):
		return {}
	var port := port_text.to_int()
	if port < 1 or port > 65535:
		return {}
	return {"host": host, "port": port}


## Is this already an address, rather than a name that has to be looked up?
##
## Used twice: to skip the DNS lookup when a host types an IP straight in, and
## to check what came *back* from a lookup, since the invite code has four bytes
## for an address and anything else has to be refused rather than truncated.
static func is_ipv4_literal(address: String) -> bool:
	var octets := address.split(".")
	if octets.size() != 4:
		return false
	for octet: String in octets:
		if not _is_digits(octet) or octet.length() > 3 or octet.to_int() > 255:
			return false
	return true


## `String.is_valid_int()` accepts a leading sign, which is not a thing an
## octet or a port number has.
static func _is_digits(text: String) -> bool:
	if text.is_empty():
		return false
	for c in text:
		if c < "0" or c > "9":
			return false
	return true


## Work out, once, what endpoint this lobby advertises.
##
## Once is the point. `IP.resolve_hostname` blocks for the length of a DNS round
## trip, and `invite_code()` is called from `lobby.gd::_refresh_invite`, which
## runs on every roster change — so resolving there would freeze the lobby for a
## moment every single time somebody joined or readied up. The tunnel's address
## does not change while a lobby is open, so this is called where it can be
## called exactly once: when the port is bound.
func _resolve_public_address() -> void:
	_clear_public_address()
	if ignore_public_address:
		return
	var typed := String(Settings.get_value("public_address")).strip_edges()
	if typed.is_empty():
		return
	var parsed := parse_public_address(typed)
	if parsed.is_empty():
		_public_problem = "PUBLIC ADDRESS IS NOT HOST:PORT — USING LAN"
		return
	var host: String = parsed["host"]
	if is_ipv4_literal(host):
		# No lookup to do, and none wanted: a host who typed the tunnel's IP
		# rather than its name should not be made to wait on a resolver.
		_public_ip = host
		_public_port = parsed["port"]
		return
	var resolved := IP.resolve_hostname(host, IP.TYPE_IPV4)
	if not is_ipv4_literal(resolved):
		# Godot hands back an empty string for a name that does not resolve.
		# The literal check also catches an IPv6 answer, which is well-formed
		# and useless to a code with four bytes for an address.
		_public_problem = "PUBLIC ADDRESS DID NOT RESOLVE — USING LAN"
		return
	_public_ip = resolved
	_public_port = parsed["port"]


func _clear_public_address() -> void:
	_public_ip = ""
	_public_port = 0
	_public_problem = ""


## True when the invite code is pointing at the tunnel rather than at an
## interface on this machine.
func using_public_address() -> bool:
	return not _public_ip.is_empty() and _public_port > 0


## Empty when there is nothing to say, which includes the ordinary case of no
## public address configured at all. Otherwise the line the lobby prints in
## place of its scope caption — a typed address that could not be used is a
## silent failure otherwise, because the fallback code is perfectly valid and
## simply does not reach anybody outside the building.
func invite_problem() -> String:
	return _public_problem


# ------------------------------------------------------------- the code ---

## The address other players should dial.
func local_ipv4() -> String:
	return select_ipv4(IP.get_local_interfaces())


## How far the current code reaches, for the caption printed above it. A player
## who can see that a code is LAN-only does not spend ten minutes wondering why
## a friend three states away cannot use it.
func invite_scope() -> String:
	if using_public_address():
		return "INTERNET (PLAYIT)"
	var address := local_ipv4()
	if _is_mesh_range(address):
		return "TAILNET"
	if address == "127.0.0.1":
		return "LOCAL"
	return "LAN" if _is_lan(address) else "INTERNET"


## The invite code to hand to other players. Reaches as far as `invite_scope()`
## says it does.
func invite_code() -> String:
	if using_public_address():
		# The *public* port, not the bound one. They are different numbers and
		# have to be: playit allocates the public side and forwards it to a
		# local port the host configures in the agent, which this game requires
		# to be DEFAULT_PORT. So the socket listens on 27015 and the code says
		# 41235, and neither half needs to know about the other.
		return InviteCode.encode(_public_ip, _public_port)
	return InviteCode.encode(local_ipv4(), _bound_port if _bound_port > 0 else DEFAULT_PORT)


func hosting_port() -> int:
	return _bound_port if _bound_port > 0 else DEFAULT_PORT
