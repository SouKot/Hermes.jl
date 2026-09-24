#include "simplot_context.h"

namespace godot {
ImGuiContext *SimPlotContextManager::s_imgui_ctx = nullptr;
ImPlotContext *SimPlotContextManager::s_implot_ctx = nullptr;
ImPlot3DContext *SimPlotContextManager::s_implot3d_ctx = nullptr;
}

