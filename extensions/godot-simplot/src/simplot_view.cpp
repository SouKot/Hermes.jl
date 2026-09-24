#include "simplot_view.h"
#include "simplot_context.h"

#include <imgui.h>
#include <implot.h>
#include <implot3d.h>
#include <cmath>

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/classes/display_server.hpp>
#include <godot_cpp/classes/rendering_server.hpp>

namespace godot {

Ref<ImageTexture> SimPlotView::s_font_texture;

SimPlotView::SimPlotView() :
    plot_title("Real-Time Telemetry"),
    x_label("Time (s)"),
    y_label("Value"),
    is_3d_mode(false),
    show_implot_demo(false),
    show_implot3d_demo(false),
    has_x_limits(false),
    x_min(0.0),
    x_max(60.0),
    has_y_limits(false),
    y_min(0.0),
    y_max(10.0),
    auto_fit_y(true),
    subplot_rows(1),
    subplot_cols(1)
{
    set_process(true);
    set_mouse_filter(MOUSE_FILTER_STOP);
}

SimPlotView::~SimPlotView() {
    clear_all();
}

void SimPlotView::cleanup_static_resources() {
    s_font_texture.unref();
}

void SimPlotView::_bind_methods() {
    ClassDB::bind_method(D_METHOD("set_plot_title", "title"), &SimPlotView::set_plot_title);
    ClassDB::bind_method(D_METHOD("get_plot_title"), &SimPlotView::get_plot_title);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "plot_title"), "set_plot_title", "get_plot_title");

    ClassDB::bind_method(D_METHOD("set_x_label", "label"), &SimPlotView::set_x_label);
    ClassDB::bind_method(D_METHOD("get_x_label"), &SimPlotView::get_x_label);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "x_label"), "set_x_label", "get_x_label");

    ClassDB::bind_method(D_METHOD("set_y_label", "label"), &SimPlotView::set_y_label);
    ClassDB::bind_method(D_METHOD("get_y_label"), &SimPlotView::get_y_label);
    ADD_PROPERTY(PropertyInfo(Variant::STRING, "y_label"), "set_y_label", "get_y_label");

    ClassDB::bind_method(D_METHOD("set_3d_mode", "enabled"), &SimPlotView::set_3d_mode);
    ClassDB::bind_method(D_METHOD("get_3d_mode"), &SimPlotView::get_3d_mode);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "is_3d_mode"), "set_3d_mode", "get_3d_mode");

    ClassDB::bind_method(D_METHOD("set_show_implot_demo", "show"), &SimPlotView::set_show_implot_demo);
    ClassDB::bind_method(D_METHOD("get_show_implot_demo"), &SimPlotView::get_show_implot_demo);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_implot_demo"), "set_show_implot_demo", "get_show_implot_demo");

    ClassDB::bind_method(D_METHOD("set_show_implot3d_demo", "show"), &SimPlotView::set_show_implot3d_demo);
    ClassDB::bind_method(D_METHOD("get_show_implot3d_demo"), &SimPlotView::get_show_implot3d_demo);
    ADD_PROPERTY(PropertyInfo(Variant::BOOL, "show_implot3d_demo"), "set_show_implot3d_demo", "get_show_implot3d_demo");

    ClassDB::bind_method(D_METHOD("set_x_limits", "min_val", "max_val"), &SimPlotView::set_x_limits);
    ClassDB::bind_method(D_METHOD("set_y_limits", "min_val", "max_val"), &SimPlotView::set_y_limits);
    ClassDB::bind_method(D_METHOD("set_auto_fit", "enable"), &SimPlotView::set_auto_fit);

    ClassDB::bind_method(D_METHOD("set_series_2d", "name", "xs", "ys"), &SimPlotView::set_series_2d);
    ClassDB::bind_method(D_METHOD("set_bars", "name", "values", "bar_width"), &SimPlotView::set_bars, DEFVAL(0.67));
    ClassDB::bind_method(D_METHOD("set_histogram", "name", "values", "bins"), &SimPlotView::set_histogram, DEFVAL(20));
    ClassDB::bind_method(D_METHOD("set_series_3d", "name", "xs", "ys", "zs"), &SimPlotView::set_series_3d);
    ClassDB::bind_method(D_METHOD("push_point", "name", "x", "y", "max_capacity"), &SimPlotView::push_point, DEFVAL(2000));

    // Native Subplots bindings
    ClassDB::bind_method(D_METHOD("set_subplots_grid", "rows", "cols"), &SimPlotView::set_subplots_grid);
    ClassDB::bind_method(D_METHOD("get_subplot_rows"), &SimPlotView::get_subplot_rows);
    ClassDB::bind_method(D_METHOD("get_subplot_cols"), &SimPlotView::get_subplot_cols);
    ClassDB::bind_method(D_METHOD("get_subplot_count"), &SimPlotView::get_subplot_count);
    ClassDB::bind_method(D_METHOD("configure_subplot", "index", "title", "y_label", "autoscale", "y_min", "y_max", "plot_type"), &SimPlotView::configure_subplot, DEFVAL("time_series"));
    ClassDB::bind_method(D_METHOD("set_subplot_series_2d", "index", "name", "xs", "ys"), &SimPlotView::set_subplot_series_2d);
    ClassDB::bind_method(D_METHOD("set_subplot_bars", "index", "name", "values", "bar_width"), &SimPlotView::set_subplot_bars, DEFVAL(0.67));
    ClassDB::bind_method(D_METHOD("set_subplot_histogram", "index", "name", "values", "bins"), &SimPlotView::set_subplot_histogram, DEFVAL(20));
    ClassDB::bind_method(D_METHOD("clear_subplots"), &SimPlotView::clear_subplots);

    ClassDB::bind_method(D_METHOD("clear_all"), &SimPlotView::clear_all);
}

void SimPlotView::ensure_contexts() {
    SimPlotContextManager::ensure_contexts();
    if (!s_font_texture.is_valid()) {
        update_font_texture();
    }
}

void SimPlotView::update_font_texture() {
    ImGuiIO &io = ImGui::GetIO();
    unsigned char *pixels = nullptr;
    int width = 0, height = 0;
    io.Fonts->GetTexDataAsRGBA32(&pixels, &width, &height);

    if (pixels != nullptr && width > 0 && height > 0) {
        PackedByteArray img_data;
        img_data.resize(width * height * 4);
        memcpy(img_data.ptrw(), pixels, width * height * 4);

        Ref<Image> font_img = Image::create_from_data(width, height, false, Image::FORMAT_RGBA8, img_data);
        s_font_texture = ImageTexture::create_from_image(font_img);
        io.Fonts->SetTexID((ImTextureID)(intptr_t)1);
    }
}

void SimPlotView::_notification(int p_what) {
    if (p_what == NOTIFICATION_ENTER_TREE) {
        ensure_contexts();
    } else if (p_what == NOTIFICATION_DRAW) {
        RenderingServer *rs = RenderingServer::get_singleton();
        if (rs == nullptr) return;

        DisplayServer *ds = DisplayServer::get_singleton();
        if (ds != nullptr && ds->get_name() == "headless") return;

        ImDrawData *draw_data = ImGui::GetDrawData();
        if (draw_data == nullptr || draw_data->CmdListsCount == 0) return;

        RID item_rid = get_canvas_item();

        for (int i = 0; i < draw_data->CmdListsCount; ++i) {
            ImDrawList *cmd_list = draw_data->CmdLists[i];
            int n_vert = cmd_list->VtxBuffer.Size;

            draw_vertices.resize(n_vert);
            draw_colors.resize(n_vert);
            draw_uvs.resize(n_vert);

            for (int v_idx = 0; v_idx < n_vert; ++v_idx) {
                const ImDrawVert &v = cmd_list->VtxBuffer[v_idx];
                draw_vertices[v_idx] = Vector2(v.pos.x, v.pos.y);

                uint32_t col = v.col;
                float r = (col & 0xFF) / 255.0f;
                col >>= 8;
                float g = (col & 0xFF) / 255.0f;
                col >>= 8;
                float b = (col & 0xFF) / 255.0f;
                col >>= 8;
                float a = (col & 0xFF) / 255.0f;

                draw_colors[v_idx] = Color(r, g, b, a);
                draw_uvs[v_idx] = Vector2(v.uv.x, v.uv.y);
            }

            for (int c_idx = 0; c_idx < cmd_list->CmdBuffer.Size; ++c_idx) {
                const ImDrawCmd &cmd = cmd_list->CmdBuffer[c_idx];
                if (cmd.ElemCount == 0) continue;

                PackedInt32Array slice_indices;
                slice_indices.resize(cmd.ElemCount);
                for (uint32_t j = 0; j < cmd.ElemCount; ++j) {
                    slice_indices[j] = cmd_list->IdxBuffer[cmd.IdxOffset + j];
                }

                PackedVector2Array slice_verts = draw_vertices;
                PackedColorArray slice_cols = draw_colors;
                PackedVector2Array slice_uv = draw_uvs;

                if (cmd.VtxOffset > 0) {
                    slice_verts = draw_vertices.slice(cmd.VtxOffset);
                    slice_cols = draw_colors.slice(cmd.VtxOffset);
                    slice_uv = draw_uvs.slice(cmd.VtxOffset);
                }

                RID tex_rid = s_font_texture.is_valid() ? s_font_texture->get_rid() : RID();
                rs->canvas_item_add_triangle_array(item_rid, slice_indices, slice_verts, slice_cols, slice_uv, {}, {}, tex_rid);
            }
        }
    }
}

void SimPlotView::_gui_input(const Ref<InputEvent> &p_event) {
    if (SimPlotContextManager::s_imgui_ctx == nullptr) return;
    ImGui::SetCurrentContext(SimPlotContextManager::s_imgui_ctx);
    ImGuiIO &io = ImGui::GetIO();

    Ref<InputEventMouseMotion> mm = p_event;
    if (mm.is_valid()) {
        Vector2 pos = mm->get_position();
        io.AddMousePosEvent(pos.x, pos.y);
    } else {
        Ref<InputEventMouseButton> mb = p_event;
        if (mb.is_valid()) {
            int btn = -1;
            MouseButton b_idx = mb->get_button_index();
            if (b_idx == MouseButton::MOUSE_BUTTON_LEFT) btn = 0;
            else if (b_idx == MouseButton::MOUSE_BUTTON_RIGHT) btn = 1;
            else if (b_idx == MouseButton::MOUSE_BUTTON_MIDDLE) btn = 2;

            if (btn >= 0) {
                io.AddMouseButtonEvent(btn, mb->is_pressed());
            }
            if (b_idx == MouseButton::MOUSE_BUTTON_WHEEL_UP) {
                io.AddMouseWheelEvent(0.0f, 1.0f);
            } else if (b_idx == MouseButton::MOUSE_BUTTON_WHEEL_DOWN) {
                io.AddMouseWheelEvent(0.0f, -1.0f);
            }
        }
    }
}

void SimPlotView::_process(double delta) {
    Vector2 sz = get_size();
    if (sz.x <= 10.0f || sz.y <= 10.0f) return;

    ensure_contexts();
    ImGui::SetCurrentContext(SimPlotContextManager::s_imgui_ctx);
    ImPlot::SetCurrentContext(SimPlotContextManager::s_implot_ctx);
    ImPlot3D::SetCurrentContext(SimPlotContextManager::s_implot3d_ctx);

    ImGuiIO &io = ImGui::GetIO();
    io.DisplaySize = ImVec2(sz.x, sz.y);
    io.DeltaTime = delta > 0.0 ? (float)delta : 1.0f / 60.0f;

    ImGui::NewFrame();

    render_implot_contents();

    ImGui::Render();
    queue_redraw();
}

void SimPlotView::render_implot_contents() {
    Vector2 sz = get_size();
    ImGui::SetNextWindowPos(ImVec2(0, 0));
    ImGui::SetNextWindowSize(ImVec2(sz.x, sz.y));

    ImGuiWindowFlags flags = ImGuiWindowFlags_NoTitleBar |
                             ImGuiWindowFlags_NoResize |
                             ImGuiWindowFlags_NoMove |
                             ImGuiWindowFlags_NoCollapse |
                             ImGuiWindowFlags_NoBackground;

    if (ImGui::Begin("##SimPlotHost", nullptr, flags)) {
        if (show_implot_demo) {
            ImPlot::ShowDemoWindow();
        }
        if (show_implot3d_demo) {
            ImPlot3D::ShowDemoWindow();
        }

        if (is_3d_mode) {
            if (ImPlot3D::BeginPlot(plot_title.utf8().get_data(), ImVec2(-1, -1))) {
                for (const auto &pair : series_3d) {
                    const Series3DData &sd = pair.second;
                    int count = sd.xs.size();
                    if (count >= 2) {
                        ImPlot3D::PlotLine(pair.first.c_str(), sd.xs.ptr(), sd.ys.ptr(), sd.zs.ptr(), count);
                    }
                }
                ImPlot3D::EndPlot();
            }
        } else if (!subplots.empty()) {
            // NATIVE IMPLOT SUBPLOTS (Rendered together on the same canvas)
            int rows = std::max(1, subplot_rows);
            int cols = std::max(1, subplot_cols);
            ImPlotSubplotFlags sp_flags = ImPlotSubplotFlags_None; // Independent axes per subplot type

            if (ImPlot::BeginSubplots("##UnifiedSubplots", rows, cols, ImVec2(-1, -1), sp_flags)) {
                for (int r = 0; r < rows; ++r) {
                    for (int c = 0; c < cols; ++c) {
                        int idx = r * cols + c;
                        if (idx < (int)subplots.size()) {
                            const SubplotData &sp = subplots[idx];
                            String p_title = sp.title.is_empty() ? ("Subplot " + String::num_int64(idx + 1)) : sp.title;
                            if (ImPlot::BeginPlot(p_title.utf8().get_data())) {
                                if (sp.plot_type == "digital_gauge") {
                                    ImPlot::SetupAxes("", "", ImPlotAxisFlags_NoDecorations, ImPlotAxisFlags_NoDecorations);
                                    ImPlot::SetupAxisLimits(ImAxis_X1, 0.0, 1.0, ImPlotCond_Always);
                                    ImPlot::SetupAxisLimits(ImAxis_Y1, 0.0, 1.0, ImPlotCond_Always);

                                    float latest_v = 0.0f;
                                    std::string s_name = "";
                                    for (const auto &pair : sp.series_2d) {
                                        if (pair.second.ys.size() > 0) {
                                            latest_v = pair.second.ys[pair.second.ys.size() - 1];
                                            s_name = pair.first;
                                            break;
                                        }
                                    }

                                    ImDrawList* draw_list = ImPlot::GetPlotDrawList();
                                    ImVec2 plot_pos = ImPlot::GetPlotPos();
                                    ImVec2 plot_size = ImPlot::GetPlotSize();

                                    ImVec2 center = ImVec2(plot_pos.x + plot_size.x * 0.5f, plot_pos.y + plot_size.y * 0.56f);
                                    float radius = std::min(plot_size.x * 0.38f, plot_size.y * 0.40f);
                                    if (radius < 24.0f) radius = 24.0f;
                                    float thickness = std::max(6.0f, std::min(14.0f, radius * 0.16f));

                                    float g_min = sp.y_min;
                                    float g_max = sp.y_max;
                                    if (g_max <= g_min) g_max = g_min + 100.0f;
                                    float pct = std::min(1.0f, std::max(0.0f, (latest_v - g_min) / (g_max - g_min)));

                                    const float a_start = 2.618f; // 150 deg (bottom-left)
                                    const float a_span = 4.1888f; // 240 deg sweep
                                    const float a_end = a_start + a_span; // 390 deg (bottom-right)
                                    float a_cur = a_start + pct * a_span;

                                    ImU32 col_track = IM_COL32(26, 36, 50, 255);
                                    ImU32 col_prog;
                                    if (pct < 0.75f) {
                                        col_prog = IM_COL32(46, 204, 113, 255); // Green (Normal)
                                    } else if (pct < 0.90f) {
                                        col_prog = IM_COL32(243, 156, 18, 255); // Amber (Warning)
                                    } else {
                                        col_prog = IM_COL32(231, 76, 60, 255);  // Red (Critical)
                                    }

                                    // 1. Background Track Arc
                                    draw_list->PathClear();
                                    draw_list->PathArcTo(center, radius, a_start, a_end, 48);
                                    draw_list->PathStroke(col_track, 0, thickness);

                                    // 2. Active Progress Arc
                                    if (pct > 0.002f) {
                                        draw_list->PathClear();
                                        draw_list->PathArcTo(center, radius, a_start, a_cur, 48);
                                        draw_list->PathStroke(col_prog, 0, thickness);
                                    }

                                    // 3. Radial Ticks at 0%, 25%, 50%, 75%, 100%
                                    for (int t = 0; t <= 4; ++t) {
                                        float t_pct = t * 0.25f;
                                        float t_ang = a_start + t_pct * a_span;
                                        float r_in = radius - thickness * 0.9f;
                                        float r_out = radius + thickness * 0.9f;
                                        ImVec2 p_in = ImVec2(center.x + std::cos(t_ang) * r_in, center.y + std::sin(t_ang) * r_in);
                                        ImVec2 p_out = ImVec2(center.x + std::cos(t_ang) * r_out, center.y + std::sin(t_ang) * r_out);
                                        draw_list->AddLine(p_in, p_out, IM_COL32(80, 100, 130, 180), 1.5f);
                                    }

                                    // 4. Indicator Needle Beacon
                                    ImVec2 tip = ImVec2(center.x + std::cos(a_cur) * radius, center.y + std::sin(a_cur) * radius);
                                    draw_list->AddCircleFilled(tip, thickness * 0.65f, IM_COL32(255, 255, 255, 255));
                                    draw_list->AddCircle(tip, thickness * 0.75f, col_prog, 16, 2.0f);

                                    // 5. Central Digital Readout
                                    char val_buf[64];
                                    if (std::abs(latest_v) < 10.0f) {
                                        snprintf(val_buf, sizeof(val_buf), "%.2f", latest_v);
                                    } else {
                                        snprintf(val_buf, sizeof(val_buf), "%.1f", latest_v);
                                    }
                                    ImVec2 val_sz = ImGui::CalcTextSize(val_buf);
                                    draw_list->AddText(ImVec2(center.x - val_sz.x * 0.5f, center.y - val_sz.y * 0.65f), col_prog, val_buf);

                                    String unit_str = sp.y_label.is_empty() ? "Value" : sp.y_label;
                                    ImVec2 unit_sz = ImGui::CalcTextSize(unit_str.utf8().get_data());
                                    draw_list->AddText(ImVec2(center.x - unit_sz.x * 0.5f, center.y + val_sz.y * 0.45f), IM_COL32(140, 160, 185, 255), unit_str.utf8().get_data());

                                    // 6. Min and Max Range Callouts
                                    char min_buf[32];
                                    char max_buf[32];
                                    snprintf(min_buf, sizeof(min_buf), "%.0f", g_min);
                                    snprintf(max_buf, sizeof(max_buf), "%.0f", g_max);
                                    ImVec2 min_sz = ImGui::CalcTextSize(min_buf);
                                    ImVec2 max_sz = ImGui::CalcTextSize(max_buf);
                                    float r_lbl = radius + thickness + 10.0f;
                                    ImVec2 min_pos = ImVec2(center.x + std::cos(a_start) * r_lbl - min_sz.x * 0.5f, center.y + std::sin(a_start) * r_lbl - min_sz.y * 0.5f);
                                    ImVec2 max_pos = ImVec2(center.x + std::cos(a_end) * r_lbl - max_sz.x * 0.5f, center.y + std::sin(a_end) * r_lbl - max_sz.y * 0.5f);
                                    draw_list->AddText(min_pos, IM_COL32(110, 130, 155, 220), min_buf);
                                    draw_list->AddText(max_pos, IM_COL32(110, 130, 155, 220), max_buf);

                                    // 7. Bound Signal Name at top if present
                                    if (!s_name.empty()) {
                                        ImVec2 s_sz = ImGui::CalcTextSize(s_name.c_str());
                                        draw_list->AddText(ImVec2(center.x - s_sz.x * 0.5f, plot_pos.y + 6.0f), IM_COL32(0, 210, 255, 220), s_name.c_str());
                                    }
                                } else if (sp.plot_type == "histogram") {
                                    ImPlot::SetupAxes("Value", "Count", ImPlotAxisFlags_AutoFit, ImPlotAxisFlags_AutoFit);
                                } else if (sp.plot_type == "xy_scatter") {
                                    if (sp.autoscale) {
                                        ImPlot::SetupAxes("X Variable", sp.y_label.utf8().get_data(), ImPlotAxisFlags_AutoFit, ImPlotAxisFlags_AutoFit);
                                    } else {
                                        ImPlot::SetupAxes("X Variable", sp.y_label.utf8().get_data());
                                        ImPlot::SetupAxisLimits(ImAxis_Y1, sp.y_min, sp.y_max, ImPlotCond_Always);
                                    }
                                } else {
                                    if (sp.autoscale) {
                                        ImPlot::SetupAxes(x_label.utf8().get_data(), sp.y_label.utf8().get_data(), ImPlotAxisFlags_None, ImPlotAxisFlags_AutoFit);
                                    } else {
                                        ImPlot::SetupAxes(x_label.utf8().get_data(), sp.y_label.utf8().get_data());
                                        ImPlot::SetupAxisLimits(ImAxis_Y1, sp.y_min, sp.y_max, ImPlotCond_Always);
                                    }
                                    if (has_x_limits) {
                                        ImPlot::SetupAxisLimits(ImAxis_X1, x_min, x_max, ImPlotCond_Always);
                                    }
                                }

                                if (sp.plot_type != "digital_gauge") {
                                    for (const auto &pair : sp.series_2d) {
                                        const Series2DData &sd = pair.second;
                                        int count = sd.xs.size();
                                        if (count > 0) {
                                            ImPlot::PlotLine(pair.first.c_str(), sd.xs.ptr(), sd.ys.ptr(), count);
                                        }
                                    }
                                }

                                for (const auto &pair : sp.series_bars) {
                                    const BarData &bd = pair.second;
                                    int count = bd.values.size();
                                    if (count > 0) {
                                        ImPlot::PlotBars(pair.first.c_str(), bd.values.ptr(), count, bd.bar_width);
                                    }
                                }

                                for (const auto &pair : sp.series_hist) {
                                    const HistData &hd = pair.second;
                                    int count = hd.values.size();
                                    if (count > 0) {
                                        ImPlot::PlotHistogram(pair.first.c_str(), hd.values.ptr(), count, hd.bins);
                                    }
                                }

                                ImPlot::EndPlot();
                            }
                        } else {
                            if (ImPlot::BeginPlot("##EmptySlot")) {
                                ImPlot::EndPlot();
                            }
                        }
                    }
                }
                ImPlot::EndSubplots();
            }
        } else {
            if (ImPlot::BeginPlot(plot_title.utf8().get_data(), ImVec2(-1, -1))) {
                if (auto_fit_y) {
                    ImPlot::SetupAxes(x_label.utf8().get_data(), y_label.utf8().get_data(), ImPlotAxisFlags_None, ImPlotAxisFlags_AutoFit);
                } else if (has_y_limits) {
                    ImPlot::SetupAxes(x_label.utf8().get_data(), y_label.utf8().get_data());
                    ImPlot::SetupAxisLimits(ImAxis_Y1, y_min, y_max, ImPlotCond_Always);
                } else {
                    ImPlot::SetupAxes(x_label.utf8().get_data(), y_label.utf8().get_data());
                }

                if (has_x_limits) {
                    ImPlot::SetupAxisLimits(ImAxis_X1, x_min, x_max, ImPlotCond_Always);
                }

                for (const auto &pair : series_2d) {
                    const Series2DData &sd = pair.second;
                    int count = sd.xs.size();
                    if (count > 0) {
                        ImPlot::PlotLine(pair.first.c_str(), sd.xs.ptr(), sd.ys.ptr(), count);
                    }
                }

                for (const auto &pair : series_bars) {
                    const BarData &bd = pair.second;
                    int count = bd.values.size();
                    if (count > 0) {
                        ImPlot::PlotBars(pair.first.c_str(), bd.values.ptr(), count, bd.bar_width);
                    }
                }

                for (const auto &pair : series_hist) {
                    const HistData &hd = pair.second;
                    int count = hd.values.size();
                    if (count > 0) {
                        ImPlot::PlotHistogram(pair.first.c_str(), hd.values.ptr(), count, hd.bins);
                    }
                }

                ImPlot::EndPlot();
            }
        }
        ImGui::End();
    }
}

void SimPlotView::set_x_limits(double min_val, double max_val) {
    has_x_limits = true;
    x_min = min_val;
    x_max = max_val;
}

void SimPlotView::set_y_limits(double min_val, double max_val) {
    has_y_limits = true;
    auto_fit_y = false;
    y_min = min_val;
    y_max = max_val;
}

void SimPlotView::set_auto_fit(bool enable) {
    auto_fit_y = enable;
    if (enable) {
        has_y_limits = false;
    }
}

void SimPlotView::set_plot_title(const String &title) { plot_title = title; }
String SimPlotView::get_plot_title() const { return plot_title; }

void SimPlotView::set_x_label(const String &label) { x_label = label; }
String SimPlotView::get_x_label() const { return x_label; }

void SimPlotView::set_y_label(const String &label) { y_label = label; }
String SimPlotView::get_y_label() const { return y_label; }

void SimPlotView::set_3d_mode(bool p_3d) { is_3d_mode = p_3d; }
bool SimPlotView::get_3d_mode() const { return is_3d_mode; }

void SimPlotView::set_show_implot_demo(bool show) { show_implot_demo = show; }
bool SimPlotView::get_show_implot_demo() const { return show_implot_demo; }

void SimPlotView::set_show_implot3d_demo(bool show) { show_implot3d_demo = show; }
bool SimPlotView::get_show_implot3d_demo() const { return show_implot3d_demo; }

void SimPlotView::set_series_2d(const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys) {
    std::string key = name.utf8().get_data();
    series_2d[key] = { xs, ys };
}

void SimPlotView::set_bars(const String &name, const PackedFloat32Array &values, double bar_width) {
    std::string key = name.utf8().get_data();
    series_bars[key] = { values, bar_width };
}

void SimPlotView::set_histogram(const String &name, const PackedFloat32Array &values, int bins) {
    std::string key = name.utf8().get_data();
    series_hist[key] = { values, bins };
}

void SimPlotView::set_series_3d(const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs) {
    std::string key = name.utf8().get_data();
    series_3d[key] = { xs, ys, zs };
}

void SimPlotView::push_point(const String &name, float x, float y, int max_capacity) {
    std::string key = name.utf8().get_data();
    auto &sd = series_2d[key];
    sd.xs.append(x);
    sd.ys.append(y);
    if (sd.xs.size() > max_capacity) {
        sd.xs = sd.xs.slice(1);
        sd.ys = sd.ys.slice(1);
    }
}

void SimPlotView::set_subplots_grid(int rows, int cols) {
    subplot_rows = std::max(1, rows);
    subplot_cols = std::max(1, cols);
}

void SimPlotView::configure_subplot(int index, const String &title, const String &y_label, bool autoscale, double y_min, double y_max, const String &plot_type) {
    if (index < 0) return;
    if ((size_t)index >= subplots.size()) {
        subplots.resize(index + 1);
    }
    SubplotData &sp = subplots[index];
    sp.title = title;
    sp.y_label = y_label;
    sp.autoscale = autoscale;
    sp.y_min = y_min;
    sp.y_max = y_max;
    sp.plot_type = plot_type;
}

void SimPlotView::set_subplot_series_2d(int index, const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys) {
    if (index < 0) return;
    if ((size_t)index >= subplots.size()) {
        subplots.resize(index + 1);
    }
    Series2DData data;
    data.xs = xs;
    data.ys = ys;
    subplots[index].series_2d[name.utf8().get_data()] = data;
}

void SimPlotView::set_subplot_bars(int index, const String &name, const PackedFloat32Array &values, double bar_width) {
    if (index < 0) return;
    if ((size_t)index >= subplots.size()) {
        subplots.resize(index + 1);
    }
    BarData data;
    data.values = values;
    data.bar_width = bar_width;
    subplots[index].series_bars[name.utf8().get_data()] = data;
}

void SimPlotView::set_subplot_histogram(int index, const String &name, const PackedFloat32Array &values, int bins) {
    if (index < 0) return;
    if ((size_t)index >= subplots.size()) {
        subplots.resize(index + 1);
    }
    HistData data;
    data.values = values;
    data.bins = bins;
    subplots[index].series_hist[name.utf8().get_data()] = data;
}

void SimPlotView::clear_subplots() {
    subplots.clear();
}

void SimPlotView::clear_all() {
    series_2d.clear();
    series_3d.clear();
    series_bars.clear();
    series_hist.clear();
    clear_subplots();
}

} // namespace godot
