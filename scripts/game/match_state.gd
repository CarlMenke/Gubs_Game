extends Node
## Authoritative match lifecycle: phases, scoring, spawns. Autoloaded as `MatchState`.
##
## Placeholder for Phase 5 — the roster and transport it builds on top of live
## in `Net`. Declared now so the autoload list is stable and other scripts can
## reference it while it fills in.

enum Phase { IDLE, WARMUP, PLAYING, POST_MATCH }

signal phase_changed(phase: Phase)

var phase: Phase = Phase.IDLE


func _ready() -> void:
	Net.left_lobby.connect(_on_left_lobby)


func _on_left_lobby(_reason: int, _message: String) -> void:
	phase = Phase.IDLE
	phase_changed.emit(phase)
