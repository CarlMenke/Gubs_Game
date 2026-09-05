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
