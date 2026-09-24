#ifndef SIMPLOT_VIEW_H
#define SIMPLOT_VIEW_H

#include <godot_cpp/classes/control.hpp>
#include <godot_cpp/classes/input_event.hpp>
#include <godot_cpp/classes/input_event_mouse_button.hpp>
#include <godot_cpp/classes/input_event_mouse_motion.hpp>
#include <godot_cpp/classes/rendering_server.hpp>
#include <godot_cpp/classes/image.hpp>
#include <godot_cpp/classes/image_texture.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/packed_color_array.hpp>
#include <godot_cpp/variant/packed_int32_array.hpp>
#include <godot_cpp/variant/rid.hpp>

#include <string>
#include <unordered_map>
#include <vector>

struct ImGuiContext;
struct ImPlotContext;
struct ImPlot3DContext;

namespace godot {

struct Series2DData {
    PackedFloat32Array xs;
    PackedFloat32Array ys;
};

struct Series3DData {
    PackedFloat32Array xs;
    PackedFloat32Array ys;
    PackedFloat32Array zs;
};

struct BarData {
    PackedFloat32Array values;
    double bar_width;
};

struct HistData {
    PackedFloat32Array values;
    int bins;
};

struct SubplotData {
    String title;
    String y_label = "Value";
    bool autoscale = true;
    double y_min = 0.0;
    double y_max = 50.0;
    String plot_type = "time_series";
    std::unordered_map<std::string, Series2DData> series_2d;
    std::unordered_map<std::string, BarData> series_bars;
    std::unordered_map<std::string, HistData> series_hist;
};

/**
 * SimPlotView: Control node hosting Dear ImGui + ImPlot + ImPlot3D rendering.
 * Statically compiled, zero DLL boundary issues, zero headless crashes.
 */
class SimPlotView : public Control {
    GDCLASS(SimPlotView, Control);

private:
    static Ref<ImageTexture> s_font_texture;

    String plot_title;
    String x_label;
    String y_label;
    bool is_3d_mode;
    bool show_implot_demo;
    bool show_implot3d_demo;

    bool has_x_limits;
    double x_min;
    double x_max;

    bool has_y_limits;
    double y_min;
    double y_max;

    bool auto_fit_y;

    std::unordered_map<std::string, Series2DData> series_2d;
    std::unordered_map<std::string, Series3DData> series_3d;
    std::unordered_map<std::string, BarData> series_bars;
    std::unordered_map<std::string, HistData> series_hist;

    // Subplots Grid Support
    int subplot_rows;
    int subplot_cols;
    std::vector<SubplotData> subplots;

    // Canvas Item buffers for rendering
    PackedVector2Array draw_vertices;
    PackedColorArray draw_colors;
    PackedVector2Array draw_uvs;
    PackedInt32Array draw_indices;

    void ensure_contexts();
    void update_font_texture();
    void render_implot_contents();

protected:
    static void _bind_methods();

public:
    SimPlotView();
    ~SimPlotView();

    static void cleanup_static_resources();

    void _notification(int p_what);
    void _gui_input(const Ref<InputEvent> &p_event);
    void _process(double delta);

    // GDScript Exposed API
    void set_plot_title(const String &title);
    String get_plot_title() const;

    void set_x_label(const String &label);
    String get_x_label() const;

    void set_y_label(const String &label);
    String get_y_label() const;

    void set_3d_mode(bool p_3d);
    bool get_3d_mode() const;

    void set_show_implot_demo(bool show);
    bool get_show_implot_demo() const;

    void set_show_implot3d_demo(bool show);
    bool get_show_implot3d_demo() const;

    void set_series_2d(const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys);
    void set_bars(const String &name, const PackedFloat32Array &values, double bar_width = 0.67);
    void set_histogram(const String &name, const PackedFloat32Array &values, int bins = 20);
    void set_series_3d(const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs);
    void set_x_limits(double min_val, double max_val);
    void set_y_limits(double min_val, double max_val);
    void set_auto_fit(bool enable);
    void push_point(const String &name, float x, float y, int max_capacity = 2000);

    // Native Subplots API
    void set_subplots_grid(int rows, int cols);
    int get_subplot_rows() const { return subplot_rows; }
    int get_subplot_cols() const { return subplot_cols; }
    int get_subplot_count() const { return (int)subplots.size(); }

    void configure_subplot(int index, const String &title, const String &y_label, bool autoscale, double y_min, double y_max, const String &plot_type = "time_series");
    void set_subplot_series_2d(int index, const String &name, const PackedFloat32Array &xs, const PackedFloat32Array &ys);
    void set_subplot_bars(int index, const String &name, const PackedFloat32Array &values, double bar_width = 0.67);
    void set_subplot_histogram(int index, const String &name, const PackedFloat32Array &values, int bins = 20);
    void clear_subplots();

    void clear_all();
};

} // namespace godot

#endif // SIMPLOT_VIEW_H
