class_name InviteCode
extends RefCounted
## Short, shareable lobby keys.
##
## An invite code is a Crockford-base32 encoding of the host's IPv4 address and
## port, formatted `XXXXX-XXXXX`. Six bytes of payload become exactly ten
## characters, so there is no padding and every code is the same length.
##
## Why encode the endpoint rather than look it up? A code that is only a random
## key needs a server somewhere that maps keys to hosts. Baking the address into
## the code keeps the whole thing peer-to-peer: it works on a LAN, over a VPN,
## and over the internet through one forwarded port, with nothing to operate.
## `Net` dials an abstract MultiplayerPeer, so a relay transport can be added
## later without game code changing.
##
## The payload is XOR-masked before encoding purely so codes do not read as
## bare IP addresses when someone pastes one into chat. This is obfuscation for
## tidiness, not secrecy — anyone with the code can and should be able to join.

## Crockford base32: no I, L, O or U, so codes cannot be misread as 1/0 and
## cannot accidentally spell much.
const ALPHABET := "0123456789ABCDEFGHJKMNPQRSTVWXYZ"
const MASK: Array[int] = [0x5A, 0x3C, 0xE7, 0x91, 0x6D, 0xB4]
const CODE_LENGTH := 10

## Characters people commonly type in place of the ones the alphabet omits.
const SUBSTITUTIONS := {"I": "1", "L": "1", "O": "0", "U": "V"}


static func encode(ip: String, port: int) -> String:
	var octets := ip.split(".")
	if octets.size() != 4:
		return ""
	var payload := PackedByteArray()
	for octet in octets:
		payload.append(int(octet) & 0xFF)
	payload.append((port >> 8) & 0xFF)
	payload.append(port & 0xFF)

	for i in payload.size():
		payload[i] ^= MASK[i]

	# 6 bytes = 48 bits = 10 base32 characters, exactly.
	var bits := 0
	var acc := 0
	var out := ""
	for byte in payload:
		acc = (acc << 8) | byte
		bits += 8
		while bits >= 5:
			bits -= 5
			out += ALPHABET[(acc >> bits) & 0x1F]
	if bits > 0:
		out += ALPHABET[(acc << (5 - bits)) & 0x1F]
	return "%s-%s" % [out.substr(0, 5), out.substr(5, 5)]


## Returns `{"ip": String, "port": int}`, or an empty Dictionary if the code is
## malformed.
static func decode(code: String) -> Dictionary:
	var cleaned := normalize(code)
	if cleaned.length() != CODE_LENGTH:
		return {}

	var acc := 0
	var bits := 0
	var payload := PackedByteArray()
	for c in cleaned:
		var value := ALPHABET.find(c)
		if value < 0:
			return {}
		acc = (acc << 5) | value
		bits += 5
		if bits >= 8:
			bits -= 8
			payload.append((acc >> bits) & 0xFF)
	if payload.size() != 6:
		return {}

	for i in payload.size():
		payload[i] ^= MASK[i]

	var port := (payload[4] << 8) | payload[5]
	if port <= 0 or port > 65535:
		return {}
	return {
		"ip": "%d.%d.%d.%d" % [payload[0], payload[1], payload[2], payload[3]],
		"port": port,
	}


## Strip formatting and fix the usual typos, so a player can paste a code with
## or without its dash and in any case.
static func normalize(code: String) -> String:
	var out := ""
	for c in code.to_upper():
		if c == "-" or c == " " or c == "\t" or c == "\n" or c == "\r":
			continue
		out += SUBSTITUTIONS.get(c, c)
	return out


static func is_valid(code: String) -> bool:
	return not decode(code).is_empty()
