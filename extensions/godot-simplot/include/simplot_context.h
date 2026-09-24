#ifndef SIMPLOT_CONTEXT_H
#define SIMPLOT_CONTEXT_H

#include <imgui.h>
#include <imgui_internal.h>
#include <implot.h>
#include <implot3d.h>
#include <cstdint>

namespace godot {

class SimPlotContextManager {
public:
    static ImGuiContext *s_imgui_ctx;
    static ImPlotContext *s_implot_ctx;
    static ImPlot3DContext *s_implot3d_ctx;

    static void ensure_contexts() {
        if (s_imgui_ctx == nullptr) {
            IMGUI_CHECKVERSION();
            s_imgui_ctx = ImGui::CreateContext();
            s_implot_ctx = ImPlot::CreateContext();
            s_implot3d_ctx = ImPlot3D::CreateContext();

            ImGui::SetCurrentContext(s_imgui_ctx);
            ImPlot::SetCurrentContext(s_implot_ctx);
            ImPlot3D::SetCurrentContext(s_implot3d_ctx);

            ImGuiIO &io = ImGui::GetIO();
            io.DisplaySize = ImVec2(1920, 1080);
            io.DeltaTime = 1.0f / 60.0f;
            io.IniFilename = nullptr;
            io.BackendFlags |= ImGuiBackendFlags_RendererHasVtxOffset;

            // Build font atlas
            unsigned char *pixels = nullptr;
            int width = 0, height = 0;
            io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);
            io.Fonts->SetTexID((ImTextureID)(intptr_t)1);

            ImGui::StyleColorsDark();
            ImPlot::StyleColorsDark();
        } else {
            ImGui::SetCurrentContext(s_imgui_ctx);
            ImPlot::SetCurrentContext(s_implot_ctx);
            ImPlot3D::SetCurrentContext(s_implot3d_ctx);
        }
    }

    static bool is_within_frame() {
        if (s_imgui_ctx == nullptr) return false;
        return s_imgui_ctx->WithinFrameScope;
    }

    static void begin_headless_frame() {
        ensure_contexts();
        if (!is_within_frame()) {
            ImGuiIO &io = ImGui::GetIO();
            if (io.DisplaySize.x <= 0 || io.DisplaySize.y <= 0) {
                io.DisplaySize = ImVec2(1920, 1080);
            }
            if (io.DeltaTime <= 0) {
                io.DeltaTime = 1.0f / 60.0f;
            }
            ImGui::NewFrame();
        }
    }

    static void end_headless_frame() {
        if (is_within_frame()) {
            ImGui::EndFrame();
        }
    }

    static void cleanup() {
        if (s_implot3d_ctx != nullptr) {
            ImPlot3D::DestroyContext(s_implot3d_ctx);
            s_implot3d_ctx = nullptr;
        }
        if (s_implot_ctx != nullptr) {
            ImPlot::DestroyContext(s_implot_ctx);
            s_implot_ctx = nullptr;
        }
        if (s_imgui_ctx != nullptr) {
            ImGui::DestroyContext(s_imgui_ctx);
            s_imgui_ctx = nullptr;
        }
    }
};

} // namespace godot

#endif // SIMPLOT_CONTEXT_H
