extends SceneTree
## Write `resources/ui/gub_theme.tres` from `UITheme.build()`. Development tool,
## not shipped.
##
## The theme is described in code (see the header of `scripts/ui/ui_theme.gd`
## for why) but committed as a resource, so the editor previews the real styling
## and a fresh clone needs no build step. This is the bridge between the two.
##
##     Godot --headless --path . --script tools/bake_theme.gd

const OUT_PATH := "res://resources/ui/gub_theme.tres"


func _initialize() -> void:
	var theme := UITheme.build()
	# Bundle the sub-resources into the one file rather than scattering forty
	# `.tres` fragments beside it.
	var err := ResourceSaver.save(theme, OUT_PATH, ResourceSaver.FLAG_BUNDLE_RESOURCES)
	if err != OK:
		push_error("bake_theme: could not write %s (error %d)" % [OUT_PATH, err])
	else:
		print("bake_theme: wrote %s" % OUT_PATH)
	quit(0 if err == OK else 1)


## A `SceneTree` script whose `_initialize` throws would otherwise spin forever
## with no window and no output; returning true from the first idle frame means
## this tool always terminates.
func _process(_delta: float) -> bool:
	return true
