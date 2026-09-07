extends Node
## Checks the invite-code encoding. Development tool, not shipped.
##
##   Godot --headless --path . tools/invite_codes.tscn
##
## Invite codes are the entire joining story: get this wrong and multiplayer is
## unreachable, with a failure that looks like a networking problem rather than
## an arithmetic one. It is also the one piece of this codebase that is pure
## logic with no scene, no physics and no network, so it is the cheapest thing
## here to test exhaustively — this walks several thousand addresses rather than
## a handful of hand-picked ones.

## Every octet boundary worth worrying about, plus a few ordinary numbers.
const OCTETS := [0, 1, 10, 31, 32, 127, 128, 192, 168, 200, 254, 255]
const PORTS := [1, 80, 255, 256, 1024, 27015, 32768, 65534, 65535]

var _failures: int = 0
var _checks: int = 0


func _ready() -> void:
	print("invite_codes: starting")
	_round_trip()
	_shape()
	_normalisation()
	_rejects_rubbish()
	_address_selection()
	_public_address()

	print("invite_codes: %d checks, %d failures" % [_checks, _failures])
	print("invite_codes: %s" % ("PASS" if _failures == 0 else "FAIL"))
	get_tree().quit(1 if _failures > 0 else 0)


func _check(what: String, got: Variant, want: Variant) -> void:
	_checks += 1
	if got == want:
		return
	_failures += 1
	# Cap the noise: a broken codec fails thousands of times and the first few
	# say everything the rest would.
	if _failures <= 10:
		print("  FAIL  %s: got %s, wanted %s" % [what, str(got), str(want)])
	elif _failures == 11:
		print("  ... further failures suppressed")


# ------------------------------------------------------------------- checks ---

## Encode then decode every combination and require the address back intact.
func _round_trip() -> void:
	print("-- round trip")
	var seen := {}
	var collisions := 0
	for a: int in OCTETS:
		for d: int in OCTETS:
			for port: int in PORTS:
				var ip := "%d.%d.%d.%d" % [a, 168, d, 1]
				var code := InviteCode.encode(ip, port)
				var back := InviteCode.decode(code)
				_check("%s:%d survives" % [ip, port], back.get("ip"), ip)
				_check("%s:%d keeps its port" % [ip, port], back.get("port"), port)
				# Two different endpoints must never produce the same code, or
				# players would silently join the wrong host.
				if seen.has(code):
					collisions += 1
				seen[code] = true
	_check("no two endpoints share a code", collisions, 0)
	print("   %d endpoints, all distinct" % seen.size())


## The format players actually see, and the promise that it is always the same
## length — a code box that has to cope with variable-length input is a worse
## code box.
func _shape() -> void:
	print("-- shape")
	var code := InviteCode.encode("192.168.1.50", 27015)
	_check("length including the dash", code.length(), 11)
	_check("dash sits in the middle", code[5], "-")
	_check("valid", InviteCode.is_valid(code), true)

	var body: String = code.replace("-", "")
	_check("payload length", body.length(), InviteCode.CODE_LENGTH)
	var stray := ""
	for c in body:
		if InviteCode.ALPHABET.find(c) < 0:
			stray += c
	_check("only alphabet characters", stray, "")

	# The alphabet exists to stop 1/I and 0/O being confused on a phone screen
	# read out loud; letting them back in would defeat it.
	var forbidden := ""
	for c in "ILOU":
		if InviteCode.ALPHABET.find(c) >= 0:
			forbidden += c
	_check("no ambiguous letters in the alphabet", forbidden, "")


## However a player mangles a code on the way from chat to the join box, it
## should still work.
func _normalisation() -> void:
	print("-- normalisation")
	var ip := "10.0.7.200"
	var port := 27015
	var code := InviteCode.encode(ip, port)
	var body: String = code.replace("-", "")

	var variants := {
		"as issued": code,
		"lower case": code.to_lower(),
		"no dash": body,
		"padded with spaces": "  %s  " % code,
		"split by a space": "%s %s" % [body.substr(0, 5), body.substr(5, 5)],
		"with a stray newline": "%s\n" % code,
	}
	for label: String in variants:
		var back := InviteCode.decode(variants[label])
		_check("%s decodes" % label, back.get("ip"), ip)
		_check("%s keeps its port" % label, back.get("port"), port)

	# The four letters the alphabet leaves out are the four people type anyway.
	# Substituting them is what makes a code readable down a phone line.
	var typo_source := InviteCode.encode("1.1.1.1", 100)
	var typo_body: String = typo_source.replace("-", "")
	var typoed := typo_body.replace("1", "I").replace("0", "O")
	_check("I and O are read as 1 and 0",
		InviteCode.decode(typoed).get("ip"), InviteCode.decode(typo_source).get("ip"))


## Anything that is not a code must come back empty rather than as a plausible
## address, because `is_valid` is what the join button is gated on.
func _rejects_rubbish() -> void:
	print("-- rejects rubbish")
	var rubbish := {
		"empty": "",
		"too short": "ABCD-EFG",
		"too long": "ABCDE-FGHIJ-KLMNO",
		"a sentence": "join my game please",
		"punctuation": "!!!!!-!!!!!",
		"an actual IP": "192.168.1.50",
	}
	for label: String in rubbish:
		_check("%s is rejected" % label, InviteCode.is_valid(rubbish[label]), false)

	# A well-formed code whose port decodes to zero is not joinable, and must be
	# refused rather than handed to the network layer.
	var zero_port := InviteCode.encode("192.168.1.50", 0)
	_check("port 0 is not a valid code", InviteCode.is_valid(zero_port), false)


## Which address ends up *in* the code, which is the other half of the joining
## story and the half that fails silently. A wrong choice here still produces a
## perfectly valid code - it just encodes an address the other player cannot
## reach, so the join looks like a firewall problem instead of an addressing one.
func _address_selection() -> void:
	print("-- address selection")

	var lan := {"name": "eth0", "friendly": "Ethernet", "addresses": ["192.168.1.50"]}
	var ten := {"name": "eth0", "friendly": "Ethernet", "addresses": ["10.0.7.200"]}
	var tail := {"name": "tailscale0", "friendly": "Tailscale", "addresses": ["100.101.102.103"]}
	var loop := {"name": "lo", "friendly": "Loopback", "addresses": ["127.0.0.1"]}
	var link := {"name": "eth1", "friendly": "Ethernet 2", "addresses": ["169.254.4.4"]}
	var wan := {"name": "eth2", "friendly": "WAN", "addresses": ["203.0.113.7"]}

	# The bug this exists to prevent: a tailnet address must beat a LAN one. It
	# reaches both - two peers on one tailnet route directly across a shared LAN -
	# whereas a LAN address strands everybody who is not in the building.
	_check("tailnet beats LAN", Net.select_ipv4([loop, lan, tail]), "100.101.102.103")
	_check("tailnet beats LAN whichever order they arrive in",
		Net.select_ipv4([tail, lan]), Net.select_ipv4([lan, tail]))
	_check("LAN when no tailnet is up", Net.select_ipv4([loop, lan]), "192.168.1.50")
	_check("10.x is a LAN too", Net.select_ipv4([loop, ten]), "10.0.7.200")

	# A tailnet is recognised by interface name as well as by range, because the
	# range alone cannot tell a mesh from a carrier doing NAT.
	_check("named interface counts even off-range",
		Net.select_ipv4([lan, {"name": "tailscale0", "friendly": "", "addresses": ["10.55.0.1"]}]),
		"10.55.0.1")
	_check("range counts even when the name is opaque",
		Net.select_ipv4([lan, {"name": "utun3", "friendly": "", "addresses": ["100.90.1.2"]}]),
		"100.90.1.2")
	_check("100.x above the block is not a tailnet",
		Net.select_ipv4([{"name": "eth9", "friendly": "", "addresses": ["100.200.1.2"]}, lan]),
		"192.168.1.50")
	_check("100.x below the block is not a tailnet",
		Net.select_ipv4([{"name": "eth9", "friendly": "", "addresses": ["100.63.1.2"]}, lan]),
		"192.168.1.50")

	# Addresses that are well-formed and useless.
	_check("link-local is skipped", Net.select_ipv4([loop, link, lan]), "192.168.1.50")
	_check("loopback is skipped", Net.select_ipv4([loop, lan]), "192.168.1.50")
	_check("a routable address beats nothing", Net.select_ipv4([loop, wan]), "203.0.113.7")
	_check("LAN still beats a routable address", Net.select_ipv4([wan, lan]), "192.168.1.50")

	# Nothing usable at all must still return something dialable rather than "".
	_check("no usable interface falls back to loopback", Net.select_ipv4([loop]), "127.0.0.1")
	_check("no interfaces at all falls back to loopback", Net.select_ipv4([]), "127.0.0.1")

	# The 172.16-31 carrier-private window, at both edges.
	for octet: int in [16, 31]:
		_check("172.%d is a LAN" % octet,
			Net.select_ipv4([{"name": "e", "friendly": "", "addresses": ["172.%d.0.9" % octet]}]),
			"172.%d.0.9" % octet)
	for octet: int in [15, 32]:
		_check("172.%d is not a LAN, so LAN wins" % octet,
			Net.select_ipv4([{"name": "e", "friendly": "", "addresses": ["172.%d.0.9" % octet]}, lan]),
			"192.168.1.50")


## The host's typed public address, which is the third way an endpoint can end
## up in a code and the only one a person enters by hand. Parsing is pure and
## does no DNS on purpose — see `Net.parse_public_address` — so all of this runs
## with no network and no socket, exactly like everything above it.
##
## The failure it guards against is `_address_selection`'s failure arriving by a
## different road: a half-understood address still produces a well-formed
## ten-character code, and the join then fails looking like the host is offline.
func _public_address() -> void:
	print("-- public address")

	# The shape playit hands out, which is what will be pasted 99 times in 100.
	var good := Net.parse_public_address("angry-gub.at.ply.gg:41235")
	_check("a playit address parses", good.get("host"), "angry-gub.at.ply.gg")
	_check("and keeps its port", good.get("port"), 41235)

	# Clipboards add whitespace at both ends, and a dashboard that puts the
	# hostname and the port in separate spans adds it in the middle. None of it
	# should cost anybody a lobby.
	var padded := {
		"leading and trailing spaces": "  angry-gub.at.ply.gg:41235  ",
		"spaces around the colon": "angry-gub.at.ply.gg : 41235",
		"a trailing newline": "angry-gub.at.ply.gg:41235\n",
		"a leading tab": "\tangry-gub.at.ply.gg:41235",
	}
	for label: String in padded:
		var parsed := Net.parse_public_address(padded[label])
		_check("%s is ignored" % label, parsed.get("host"), "angry-gub.at.ply.gg")
		_check("%s does not eat the port" % label, parsed.get("port"), 41235)

	# An IPv4 literal is accepted as-is and with no lookup: a host who typed the
	# tunnel's address rather than its name should not wait on a resolver.
	var literal := Net.parse_public_address("147.185.221.19:41235")
	_check("an IPv4 literal parses", literal.get("host"), "147.185.221.19")
	_check("an IPv4 literal keeps its port", literal.get("port"), 41235)
	_check("and is recognised as one, so no lookup happens",
		Net.is_ipv4_literal("147.185.221.19"), true)
	_check("a hostname is not", Net.is_ipv4_literal("angry-gub.at.ply.gg"), false)
	_check("a partial address is not", Net.is_ipv4_literal("147.185.221"), false)
	_check("an octet over 255 is not", Net.is_ipv4_literal("147.185.221.256"), false)
	_check("a signed octet is not", Net.is_ipv4_literal("147.185.221.+9"), false)
	_check("an empty octet is not", Net.is_ipv4_literal("147.185..19"), false)
	_check("IPv6 is not", Net.is_ipv4_literal("2606:4700:4700::1111"), false)

	# Everything that is not an address. Each must come back empty rather than
	# half-filled: `_resolve_public_address` treats a non-empty answer as usable.
	var rubbish := {
		"empty": "",
		"only whitespace": "   ",
		"no port": "angry-gub.at.ply.gg",
		"a bare colon": ":",
		"no host": ":41235",
		"nothing after the colon": "angry-gub.at.ply.gg:",
		"a word for a port": "angry-gub.at.ply.gg:port",
		"a decimal port": "angry-gub.at.ply.gg:412.35",
		"a negative port": "angry-gub.at.ply.gg:-41235",
		"port zero": "angry-gub.at.ply.gg:0",
		"port past the top": "angry-gub.at.ply.gg:65536",
		"a URL": "udp://angry-gub.at.ply.gg:41235",
		"a bare IPv6 address": "2606:4700:4700::1111",
		"two ports": "angry-gub.at.ply.gg:41235:41236",
	}
	for label: String in rubbish:
		_check("%s is rejected" % label,
			Net.parse_public_address(rubbish[label]).is_empty(), true)

	# The port range, at both edges and in the middle.
	for port: int in [1, 27015, 65535]:
		_check("port %d is allowed" % port,
			Net.parse_public_address("h:%d" % port).get("port"), port)

	# What the code ends up carrying. The *public* port goes in, not the local
	# one the agent forwards to: they are different numbers by design (D-028),
	# and encoding the local one would hand out a code that dials the tunnel's
	# public IP on a port nothing out there is listening on.
	var resolved := "147.185.221.19"
	var round_trip := InviteCode.decode(InviteCode.encode(resolved, 41235))
	_check("a tunnel endpoint survives the codec", round_trip.get("ip"), resolved)
	_check("with the public port intact", round_trip.get("port"), 41235)
