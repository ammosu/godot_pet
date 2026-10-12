extends SceneTree

## Dumps the whole right-click menu tree — every row's text, id, separator,
## check/radio state, disabled state, a hash of its tooltip, and which submenu it
## opens — one line per row, to the file named by $MENU_OUT.
##
## This is how a menu change is proven to change nothing else. The row count and
## pixel heights in CLAUDE.md are measured values, and the PetMenu move was
## accepted on this dump coming out byte-identical before and after.
##
##   XDG_DATA_HOME=/tmp/iso/data MENU_OUT=/tmp/before.txt \
##     godot --headless --path . -s tools/menu_dump.gd
##   …make the change…
##   XDG_DATA_HOME=/tmp/iso/data MENU_OUT=/tmp/after.txt \
##     godot --headless --path . -s tools/menu_dump.gd
##   diff /tmp/before.txt /tmp/after.txt
##
## Run the "before" twice and diff those first: rows reflect config, installed
## packs and the voice service's state, so a baseline that is not deterministic
## proves nothing. Keep XDG_DATA_HOME pointed at a scratch directory so the run
## neither reads nor writes the real config.
##
## A `-s` script is compiled before autoloads and `class_name` scripts are
## registered, which is why nothing here names PetMenu or a service directly.

func _initialize() -> void:
	_go.call_deferred()


func _dump(menu: PopupMenu, depth: int, out: PackedStringArray) -> void:
	out.append("%s[%s] items=%d" % ["  ".repeat(depth), menu.name, menu.item_count])
	for i in menu.item_count:
		var sub := menu.get_item_submenu_node(i)
		out.append("%s- id=%d text=%s sep=%s check=%s/%s radio=%s disabled=%s tip=%s%s" % [
			"  ".repeat(depth + 1), menu.get_item_id(i), menu.get_item_text(i),
			menu.is_item_separator(i), menu.is_item_checkable(i), menu.is_item_checked(i),
			menu.is_item_radio_checkable(i), menu.is_item_disabled(i),
			menu.get_item_tooltip(i).sha256_text().substr(0, 8),
			(" -> " + sub.name) if sub != null else ""])
		if sub != null:
			_dump(sub, depth + 2, out)


func _go() -> void:
	var target := OS.get_environment("MENU_OUT")
	if target.is_empty():
		push_error("menu_dump: set MENU_OUT to the file to write")
		quit(1)
		return
	var pet: Node = load("res://pet/pet.tscn").instantiate()
	root.add_child(pet)
	await create_timer(0.5).timeout
	var menu: PopupMenu = pet.get_node("Menu")
	menu.call("rebuild")
	var out := PackedStringArray()
	_dump(menu, 0, out)
	var file := FileAccess.open(target, FileAccess.WRITE)
	file.store_string("\n".join(out) + "\n")
	file.close()
	print("menu_dump: %d lines to %s" % [out.size(), target])
	quit()
