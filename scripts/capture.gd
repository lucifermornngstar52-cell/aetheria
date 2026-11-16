extends Node
## Служебный скрипт: собирает мир и снимает два кадра для проверки. Работает в низком качестве,
## чтобы прогон под xvfb (софтверный OpenGL) не занимал десятки минут.

func _ready() -> void:
	var main = load("res://scenes/main.tscn").instantiate()
	add_child(main)
	# минимальное качество: софтверный рендер иначе очень медленный
	var world = get_tree().get_first_node_in_group("world")
	if world != null:
		world.set("quality", 0)
	get_viewport().scaling_3d_scale = 0.5
	await get_tree().create_timer(7.0).timeout
	var pl = get_tree().get_first_node_in_group("player")
	await RenderingServer.frame_post_draw
	get_viewport().get_texture().get_image().save_png("user://shot.png")
	print("SHOT OK")
	if pl != null:
		pl.call("do_attack")
		await get_tree().create_timer(0.3).timeout
		await RenderingServer.frame_post_draw
		get_viewport().get_texture().get_image().save_png("user://shot_attack.png")
		print("SHOT ATTACK OK")
	print("SHOT PATH " + ProjectSettings.globalize_path("user://shot.png"))
	get_tree().quit()
