extends Node
## Служебный скрипт: собирает мир, снимает кадры (обычный вид, удар мечом, танец) для проверки.

func _ready() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(14.0).timeout
	var pl = get_tree().get_first_node_in_group("player")
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://shot.png")
	print("SHOT OK %dx%d" % [img.get_width(), img.get_height()])
	if pl != null:
		pl.call("do_attack")
		await get_tree().create_timer(0.35).timeout
		await RenderingServer.frame_post_draw
		var img2 := get_viewport().get_texture().get_image()
		img2.save_png("user://shot_attack.png")
		print("SHOT ATTACK OK")
		await get_tree().create_timer(1.2).timeout
		pl.call("play_emote", "ual/Dance", "Танец")
		await get_tree().create_timer(1.0).timeout
		await RenderingServer.frame_post_draw
		var img3 := get_viewport().get_texture().get_image()
		img3.save_png("user://shot_dance.png")
		print("SHOT DANCE OK")
	print("SHOT PATH " + ProjectSettings.globalize_path("user://shot.png"))
	get_tree().quit()
