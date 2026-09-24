#include "simplot_bridge.h"

#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/utility_functions.hpp>

// If ImPlot and ImPlot3D headers are present in thirdparty/
#if __has_include("implot.h")
#define HAVE_IMPLOT 1
#include "implot.h"
#endif

#if __has_include("implot3d.h")
#define HAVE_IMPLOT3D 1
#include "implot3d.h"
#endif

#include "simplot_context.h"

namespace godot {

SimPlot::SimPlot() : is_plotting_active(false), is_plotting_3d_active(false), headless_frame_opened(false) {
    SimPlotContextManager::ensure_contexts();
}

SimPlot::~SimPlot() {
    rolling_series.clear();
}

void SimPlot::_bind_methods() {
    // 2D Plotting methods
    ClassDB::bind_method(D_METHOD("begin_plot", "title", "size", "flags"), &SimPlot::begin_plot, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("end_plot"), &SimPlot::end_plot);
    ClassDB::bind_method(D_METHOD("setup_axes", "x_label", "y_label", "x_flags", "y_flags"), &SimPlot::setup_axes, DEFVAL(0), DEFVAL(0));
    ClassDB::bind_method(D_METHOD("setup_axis_limits", "axis", "min_val", "max_val"), &SimPlot::setup_axis_limits);
    ClassDB::bind_method(D_METHOD("setup_axes_limits", "x_min", "x_max", "y_min", "y_max"), &SimPlot::setup_axes_limits);
    ClassDB::bind_method(D_METHOD("plot_line", "label", "xs", "ys"), &SimPlot::plot_line);
    ClassDB::bind_method(D_METHOD("plot_bars", "label", "values", "bar_width"), &SimPlot::plot_bars, DEFVAL(0.67));
    ClassDB::bind_method(D_METHOD("plot_histogram", "label", "values", "bins"), &SimPlot::plot_histogram, DEFVAL(20));
    ClassDB::bind_method(D_METHOD("plot_scatter", "label", "xs", "ys"), &SimPlot::plot_scatter);

    // 3D Plotting methods
    ClassDB::bind_method(D_METHOD("begin_plot3d", "title", "size", "flags"), &SimPlot::begin_plot3d, DEFVAL(0));
    ClassDB::bind_method(D_METHOD("end_plot3d"), &SimPlot::end_plot3d);
    ClassDB::bind_method(D_METHOD("plot_line3d", "label", "xs", "ys", "zs"), &SimPlot::plot_line3d);
    ClassDB::bind_method(D_METHOD("plot_scatter3d", "label", "xs", "ys", "zs"), &SimPlot::plot_scatter3d);

    // High-performance rolling ring buffer methods
    ClassDB::bind_method(D_METHOD("push_telemetry", "series_id", "t", "val", "max_capacity"), &SimPlot::push_telemetry, DEFVAL(2000));
    ClassDB::bind_method(D_METHOD("plot_rolling_series", "series_id", "label"), &SimPlot::plot_rolling_series);
    ClassDB::bind_method(D_METHOD("clear_series", "series_id"), &SimPlot::clear_series);
    ClassDB::bind_method(D_METHOD("clear_all_series"), &SimPlot::clear_all_series);
    ClassDB::bind_method(D_METHOD("get_series_point_count", "series_id"), &SimPlot::get_series_point_count);
}

bool SimPlot::begin_plot(const String &title, const Vector2 &size, int flags) {
    SimPlotContextManager::ensure_contexts();
    if (!SimPlotContextManager::is_within_frame()) {
        SimPlotContextManager::begin_headless_frame();
        headless_frame_opened = true;
    } else {
        headless_frame_opened = false;
    }

#if HAVE_IMPLOT
    is_plotting_active = ImPlot::BeginPlot(title.utf8().get_data(), ImVec2(size.x, size.y), flags);
    return is_plotting_active;
#else
    is_plotting_active = true;
    return true;
#endif
}

void SimPlot::end_plot() {
#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::EndPlot();
    }
#endif
    if (headless_frame_opened) {
        SimPlotContextManager::end_headless_frame();
        headless_frame_opened = false;
    }
    is_plotting_active = false;
}

void SimPlot::setup_axes(const String &x_label, const String &y_label, int x_flags, int y_flags) {
#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::SetupAxes(x_label.utf8().get_data(), y_label.utf8().get_data(), x_flags, y_flags);
    }
#endif
}

void SimPlot::setup_axis_limits(int axis, double min_val, double max_val) {
#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::SetupAxisLimits(axis, min_val, max_val, ImPlotCond_Always);
    }
#endif
}

void SimPlot::setup_axes_limits(double x_min, double x_max, double y_min, double y_max) {
#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::SetupAxesLimits(x_min, x_max, y_min, y_max, ImPlotCond_Always);
    }
#endif
}

void SimPlot::plot_line(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys) {
    int count = xs.size();
    if (count <= 0 || ys.size() != count) return;

    // Zero-copy direct memory pointer access from Godot's PackedFloat32Array
    const float *x_ptr = xs.ptr();
    const float *y_ptr = ys.ptr();

#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::PlotLine(label.utf8().get_data(), x_ptr, y_ptr, count);
    }
#endif
}

void SimPlot::plot_bars(const String &label, const PackedFloat32Array &values, double bar_width) {
    int count = values.size();
    if (count <= 0) return;
    const float *val_ptr = values.ptr();

#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::PlotBars(label.utf8().get_data(), val_ptr, count, bar_width);
    }
#endif
}

void SimPlot::plot_histogram(const String &label, const PackedFloat32Array &values, int bins) {
    int count = values.size();
    if (count <= 0) return;
    const float *val_ptr = values.ptr();

#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::PlotHistogram(label.utf8().get_data(), val_ptr, count, bins);
    }
#endif
}

void SimPlot::plot_scatter(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys) {
    int count = xs.size();
    if (count <= 0 || ys.size() != count) return;
    const float *x_ptr = xs.ptr();
    const float *y_ptr = ys.ptr();

#if HAVE_IMPLOT
    if (is_plotting_active) {
        ImPlot::PlotScatter(label.utf8().get_data(), x_ptr, y_ptr, count);
    }
#endif
}

bool SimPlot::begin_plot3d(const String &title, const Vector2 &size, int flags) {
    SimPlotContextManager::ensure_contexts();
    if (!SimPlotContextManager::is_within_frame()) {
        SimPlotContextManager::begin_headless_frame();
        headless_frame_opened = true;
    } else {
        headless_frame_opened = false;
    }

#if HAVE_IMPLOT3D
    is_plotting_3d_active = ImPlot3D::BeginPlot(title.utf8().get_data(), ImVec2(size.x, size.y), flags);
    return is_plotting_3d_active;
#else
    is_plotting_3d_active = true;
    return true;
#endif
}

void SimPlot::end_plot3d() {
#if HAVE_IMPLOT3D
    if (is_plotting_3d_active) {
        ImPlot3D::EndPlot();
    }
#endif
    if (headless_frame_opened) {
        SimPlotContextManager::end_headless_frame();
        headless_frame_opened = false;
    }
    is_plotting_3d_active = false;
}

void SimPlot::plot_line3d(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs) {
    int count = xs.size();
    if (count <= 0 || ys.size() != count || zs.size() != count) return;
    const float *x_ptr = xs.ptr();
    const float *y_ptr = ys.ptr();
    const float *z_ptr = zs.ptr();

#if HAVE_IMPLOT3D
    if (is_plotting_3d_active) {
        ImPlot3D::PlotLine(label.utf8().get_data(), x_ptr, y_ptr, z_ptr, count);
    }
#endif
}

void SimPlot::plot_scatter3d(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs) {
    int count = xs.size();
    if (count <= 0 || ys.size() != count || zs.size() != count) return;
    const float *x_ptr = xs.ptr();
    const float *y_ptr = ys.ptr();
    const float *z_ptr = zs.ptr();

#if HAVE_IMPLOT3D
    if (is_plotting_3d_active) {
        ImPlot3D::PlotScatter(label.utf8().get_data(), x_ptr, y_ptr, z_ptr, count);
    }
#endif
}

void SimPlot::push_telemetry(const String &series_id, float t, float val, int max_capacity) {
    std::string key = series_id.utf8().get_data();
    auto it = rolling_series.find(key);
    if (it == rolling_series.end()) {
        rolling_series.emplace(key, RingBuffer(static_cast<size_t>(max_capacity)));
    }
    rolling_series[key].push(t, val);
}

void SimPlot::plot_rolling_series(const String &series_id, const String &label) {
    std::string key = series_id.utf8().get_data();
    auto it = rolling_series.find(key);
    if (it == rolling_series.end() || it->second.count == 0) return;

    const auto &rb = it->second;
#if HAVE_IMPLOT
    if (is_plotting_active) {
        if (rb.count < rb.capacity) {
            ImPlot::PlotLine(label.utf8().get_data(), rb.xs.data(), rb.ys.data(), static_cast<int>(rb.count));
        } else {
            struct RingData {
                const RingBuffer *buf;
            } ring_data = { &rb };

            auto getter = [](int idx, void *user_data) -> ImPlotPoint {
                const RingBuffer *b = static_cast<RingData*>(user_data)->buf;
                size_t actual_idx = (b->head + idx) % b->capacity;
                return ImPlotPoint(b->xs[actual_idx], b->ys[actual_idx]);
            };

            ImPlot::PlotLineG(label.utf8().get_data(), getter, &ring_data, static_cast<int>(rb.count));
        }
    }
#endif
}

void SimPlot::clear_series(const String &series_id) {
    std::string key = series_id.utf8().get_data();
    auto it = rolling_series.find(key);
    if (it != rolling_series.end()) {
        it->second.clear();
    }
}

void SimPlot::clear_all_series() {
    rolling_series.clear();
}

int SimPlot::get_series_point_count(const String &series_id) const {
    std::string key = series_id.utf8().get_data();
    auto it = rolling_series.find(key);
    if (it != rolling_series.end()) {
        return static_cast<int>(it->second.count);
    }
    return 0;
}

} // namespace godot

