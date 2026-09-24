# `godot-simplot`: C++ GDExtension Bridge for ImPlot & ImPlot3D in Godot 4

## 1. Overview & Architecture

`godot-simplot` is a high-performance C++ GDExtension library designed for **Antigravity SimViz**. It exposes the capabilities of **Dear ImGui**, **ImPlot** (2D), and **ImPlot3D** (3D) directly to GDScript.

### Why a Shared Library (`.so` / `.dll`) and NOT a Standalone Executable (`.exe`)?

When integrating C++ with Godot, there is a fundamental difference between a **GDExtension Shared Library** and a **Standalone Executable**:

| Feature | GDExtension Shared Library (`.so` / `.dll`) | Standalone Executable (`.exe`) |
| :--- | :--- | :--- |
| **Process Address Space** | **In-Process**: Loaded directly into Godot's virtual memory via `dlopen()` / `LoadLibrary()`. | **Out-of-Process**: Runs in a separate OS process with its own memory space. |
| **Memory Access** | **Zero-Copy**: C++ accesses Godot's `PackedFloat32Array.ptr()` memory buffer directly without any copy. | **Requires IPC**: Requires pipes, sockets, or shared memory, which adds latency and CPU overhead. |
| **Viewport & Window** | **Integrated**: Renders directly inside Godot's existing OS window, SubViewport, or CanvasItem render pass. | **Disjoint**: Opens a second OS window or requires complex window-parenting / OS-level texture sharing. |
| **Framerate & Sync** | Runs synchronously at the exact display refresh rate (60, 120, 144 Hz) in Godot's render thread. | Must sync clocks across processes; risks frame tearing and judder. |

**Conclusion**: GDExtension compiles your C++ code into a shared library (`.so`), which Godot dynamically loads at engine startup. This provides direct, native C++ performance with full GDScript reflection.

---

## 2. Directory Structure

```text
extensions/godot-simplot/
├── include/
│   ├── simplot_bridge.h       # C++ header declaring SimPlot class and zero-copy methods
│   └── register_types.h       # GDExtension lifecycle & ClassDB registration
├── src/
│   ├── simplot_bridge.cpp     # C++ implementation interfacing PackedFloat32Array with ImPlot
│   └── register_types.cpp     # GDExtension initialization entry point
├── thirdparty/
│   ├── imgui/                 # Dear ImGui core headers
│   ├── implot/                # ImPlot 2D plotting library
│   └── implot3d/              # ImPlot3D 3D spatial plotting library
├── CMakeLists.txt             # Modern CMake build configuration
├── SConstruct                 # SCons build script (standard Godot build tool)
├── simplot.gdextension        # GDExtension configuration manifest
└── README.md                  # Architectural reference and guide
```

---

## 3. Zero-Copy GDScript to C++ Data Flow

In GDScript, simulation series are stored in a contiguous `PackedFloat32Array`:

```gdscript
# GDScript
var xs := PackedFloat32Array([0.0, 1.0, 2.0, 3.0])
var ys := PackedFloat32Array([10.5, 12.0, 15.2, 14.1])

var plotter := SimPlot.new()
plotter.begin_plot("Queue Depths", Vector2(600, 300))
plotter.plot_line("Queue 1", xs, ys)
plotter.end_plot()
```

In the C++ bridge (`simplot_bridge.cpp`):

```cpp
void SimPlot::plot_line(const String &label, const PackedFloat32Array &xs, const PackedFloat32Array &ys) {
    // Zero copy: direct pointer retrieval from Godot's internal buffer
    const float *x_ptr = xs.ptr();
    const float *y_ptr = ys.ptr();
    int count = xs.size();

    // Handed directly to ImPlot
    ImPlot::PlotLine(label.utf8().get_data(), x_ptr, y_ptr, count);
}
```

Because `xs.ptr()` points directly to the underlying heap array managed by Godot, **no copies or allocations occur**, allowing hundreds of thousands of points to stream at 144 FPS with negligible CPU impact.

---

## 4. How to Build `godot-simplot`

### Prerequisites
- C++17 compiler (`g++` or `clang++` on Linux; MSVC on Windows)
- `cmake` or `scons`
- Official `godot-cpp` bindings:
  ```bash
  cd extensions/godot-simplot
  git clone --recurse-submodules https://github.com/godotengine/godot-cpp
  ```

### Build with CMake
```bash
mkdir -p build && cd build
cmake .. -DCMAKE_BUILD_TYPE=Release
cmake --build . -j$(nproc)
```

The compiled dynamic library (`libgodot_simplot.so`) will be placed into `bin/` and loaded automatically by Godot via `simplot.gdextension`.

---

## 5. Antigravity SimViz Two-Tier Plotting Strategy

1. **Tier 1 (Built-In Native Godot Canvas `AuthoringSimplotDock`)**:
   - Implemented in `godot/scripts/authoring_simplot_dock.gd`.
   - Uses Godot's hardware-accelerated 2D canvas drawing (`draw_polyline`, `draw_rect`).
   - Requires **zero external compilation** and works on any machine immediately.
   - Provides Queues, Utilization, Throughput, and Cycle Time waveforms with hover crosshairs and freeze controls.

2. **Tier 2 (High-Frequency Engineering Waveforms via `godot-simplot`)**:
   - Uses `godot-simplot` C++ GDExtension with ImPlot/ImPlot3D.
   - Built for ultra-dense time series ($100,000+$ points, complex subplots, heatmaps, and 3D trajectory plots).

