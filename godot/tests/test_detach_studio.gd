extends SceneTree

const PlotStudio := preload("res://scripts/authoring_plot_studio.gd")
const DocumentStore := preload("res://scripts/authoring_document_store.gd")

func _init() -> void:
	print("--- Testing PlotStudio Detach & Dock Logic ---")
	var doc = DocumentStore.new()
	var studio = PlotStudio.new(doc)
	root.add_child(studio)
	studio._ready()

	print("Initial: is_detached=", studio._is_detached, " parent=", studio.get_parent().name)

	# Test Detach
	studio.detach_to_os_window()
	print("After detach: is_detached=", studio._is_detached, " parent=", studio.get_parent().get_class())
	assert(studio._is_detached == true, "Must be detached")
	assert(studio._os_window != null, "OS window must exist")

	# Test Dock
	studio.dock_to_main_window()
	print("After dock: is_detached=", studio._is_detached, " parent=", studio.get_parent().name)
	assert(studio._is_detached == false, "Must be docked")
	assert(studio._os_window == null, "OS window must be cleared")

	studio.queue_free()
	print("Detach & Dock Test PASSED!")
	quit(0)
