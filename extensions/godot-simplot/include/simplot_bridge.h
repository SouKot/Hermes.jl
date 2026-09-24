#ifndef SIMPLOT_BRIDGE_H
#define SIMPLOT_BRIDGE_H

#include <godot_cpp/classes/ref_counted.hpp>
#include <godot_cpp/core/class_db.hpp>
#include <godot_cpp/variant/string.hpp>
#include <godot_cpp/variant/vector2.hpp>
#include <godot_cpp/variant/vector3.hpp>
#include <godot_cpp/variant/packed_float32_array.hpp>
#include <godot_cpp/variant/packed_vector2_array.hpp>
#include <godot_cpp/variant/dictionary.hpp>

#include <vector>
#include <unordered_map>
#include <string>

namespace godot {

/**
 * Ring buffer for high-throughput streaming waveforms without allocations.
 */
struct RingBuffer {
    std::vector<float> xs;
    std::vector<float> ys;
    size_t capacity;
    size_t head;
    size_t count;

    RingBuffer(size_t cap = 2000) : capacity(cap), head(0), count(0) {
        xs.resize(cap);
        ys.resize(cap);
    }

    void push(float x, float y) {
        xs[head] = x;
        ys[head] = y;
        head = (head + 1) % capacity;
        if (count < capacity) count++;
    }

    void clear() {
        head = 0;
        count = 0;
    }
};

/**
 * SimPlot: High-performance C++ GDExtension bridge connecting Godot 4
 * to Dear ImGui, ImPlot, and ImPlot3D.
 * 
 * Provides zero-copy data passing via Godot's PackedFloat32Array contiguous pointers.
 */
class SimPlot : public RefCounted {
    GDCLASS(SimPlot, RefCounted);

private:
    bool is_plotting_active;
    bool is_plotting_3d_active;
    bool headless_frame_opened;
    std::unordered_map<std::string, RingBuffer> rolling_series;

protected:
    static void _bind_methods();

public:
    SimPlot();
    ~SimPlot();

    // 2D ImPlot API
    bool begin_plot(const String &title, const Vector2 &size, int flags = 0);
    void end_plot();
    void setup_axes(const String &x_label, const String &y_label, int x_flags = 0, int y_flags = 0);
    void setup_axis_limits(int axis, double min_val, double max_val);
    void setup_axes_limits(double x_min, double x_max, double y_min, double y_max);
    void plot_line(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys);
    void plot_bars(const String &label, const PackedFloat32Array &values, double bar_width = 0.67);
    void plot_histogram(const String &label, const PackedFloat32Array &values, int bins = 20);
    void plot_scatter(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys);

    // 3D ImPlot3D API
    bool begin_plot3d(const String &title, const Vector2 &size, int flags = 0);
    void end_plot3d();
    void plot_line3d(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs);
    void plot_scatter3d(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys, const PackedFloat32Array &zs);

    // Rolling Ring Buffer API (for real-time streaming without Godot memory churn)
    void push_telemetry(const String &series_id, float t, float val, int max_capacity = 2000);
    void plot_rolling_series(const String &series_id, const String &label);
    void clear_series(const String &series_id);
    void clear_all_series();
    int get_series_point_count(const String &series_id) const;
};

} // namespace godot

#endif // SIMPLOT_BRIDGE_H

