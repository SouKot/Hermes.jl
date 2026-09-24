#include "register_types.h"
#include "simplot_bridge.h"
#include "simplot_view.h"
#include "simplot_context.h"

#include <gdextension_interface.h>
#include <godot_cpp/core/defs.hpp>
#include <godot_cpp/godot.hpp>

using namespace godot;

void initialize_simplot_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    SimPlotContextManager::ensure_contexts();

    ClassDB::register_class<SimPlot>();
    ClassDB::register_class<SimPlotView>();
}

void uninitialize_simplot_module(ModuleInitializationLevel p_level) {
    if (p_level != MODULE_INITIALIZATION_LEVEL_SCENE) {
        return;
    }

    SimPlotView::cleanup_static_resources();
    SimPlotContextManager::cleanup();
}

extern "C" {
GDExtensionBool GDE_EXPORT simplot_library_init(
    GDExtensionInterfaceGetProcAddress p_get_proc_address,
    const GDExtensionClassLibraryPtr p_library,
    GDExtensionInitialization *r_initialization
) {
    godot::GDExtensionBinding::InitObject init_obj(p_get_proc_address, p_library, r_initialization);

    init_obj.register_initializer(initialize_simplot_module);
    init_obj.register_terminator(uninitialize_simplot_module);
    init_obj.set_minimum_library_initialization_level(MODULE_INITIALIZATION_LEVEL_SCENE);

    return init_obj.init();
}
}

