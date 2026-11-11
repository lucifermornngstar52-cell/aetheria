extends Node
## Служебный скрипт: собирает мир, ждёт кадр и сохраняет скриншот для проверки.

func _ready() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	await get_tree().create_timer(16.0).timeout
	await RenderingServer.frame_post_draw
	var img := get_viewport().get_texture().get_image()
	img.save_png("user://shot.png")
	print("SHOT OK %dx%d" % [img.get_width(), img.get_height()])
	print("SHOT PATH " + ProjectSettings.globalize_path("user://shot.png"))
	get_tree().quit()
