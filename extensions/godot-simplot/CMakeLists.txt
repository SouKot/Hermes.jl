cmake_minimum_required(VERSION 3.20)
project(godot_simplot VERSION 1.0.0 LANGUAGES CXX C)

set(CMAKE_CXX_STANDARD 17)
set(CMAKE_CXX_STANDARD_REQUIRED ON)
set(CMAKE_POSITION_INDEPENDENT_CODE ON)

set(GODOTCPP_DIR "${CMAKE_CURRENT_SOURCE_DIR}/godot-cpp")
set(GODOTCPP_LIB "${GODOTCPP_DIR}/build/bin/libgodot-cpp.linux.template_debug.x86_64.a")
set(THIRDPARTY_DIR "${CMAKE_CURRENT_SOURCE_DIR}/thirdparty")

set(SIMPLOT_SOURCES
    src/register_types.cpp
    src/simplot_context.cpp
    src/simplot_bridge.cpp
    src/simplot_view.cpp
    ${THIRDPARTY_DIR}/imgui/imgui.cpp
    ${THIRDPARTY_DIR}/imgui/imgui_draw.cpp
    ${THIRDPARTY_DIR}/imgui/imgui_tables.cpp
    ${THIRDPARTY_DIR}/imgui/imgui_widgets.cpp
    ${THIRDPARTY_DIR}/imgui/imgui_demo.cpp
    ${THIRDPARTY_DIR}/implot/implot.cpp
    ${THIRDPARTY_DIR}/implot/implot_items.cpp
    ${THIRDPARTY_DIR}/implot/implot_demo.cpp
    ${THIRDPARTY_DIR}/implot3d/implot3d.cpp
    ${THIRDPARTY_DIR}/implot3d/implot3d_items.cpp
    ${THIRDPARTY_DIR}/implot3d/implot3d_meshes.cpp
    ${THIRDPARTY_DIR}/implot3d/implot3d_demo.cpp
)

add_library(godot_simplot SHARED ${SIMPLOT_SOURCES})

target_include_directories(godot_simplot PRIVATE
    include
    ${GODOTCPP_DIR}/include
    ${GODOTCPP_DIR}/gdextension
    ${GODOTCPP_DIR}/build/gen/include
    ${THIRDPARTY_DIR}/imgui
    ${THIRDPARTY_DIR}/implot
    ${THIRDPARTY_DIR}/implot3d
)

target_link_libraries(godot_simplot PRIVATE "${GODOTCPP_LIB}")

# Output library
set_target_properties(godot_simplot PROPERTIES
    PREFIX "lib"
    OUTPUT_NAME "godot_simplot.linux.template_debug.x86_64"
    LIBRARY_OUTPUT_DIRECTORY "${CMAKE_CURRENT_SOURCE_DIR}/bin"
)

# Copy into godot/bin/ so Godot loads it directly
add_custom_command(TARGET godot_simplot POST_BUILD
    COMMAND ${CMAKE_COMMAND} -E make_directory "${CMAKE_CURRENT_SOURCE_DIR}/../../godot/bin"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:godot_simplot>" "${CMAKE_CURRENT_SOURCE_DIR}/../../godot/bin/"
    COMMAND ${CMAKE_COMMAND} -E copy "$<TARGET_FILE:godot_simplot>" "${CMAKE_CURRENT_SOURCE_DIR}/../../godot/bin/libgodot_simplot.so"
)

message(STATUS "Configured godot_simplot GDExtension target linking statically with ImGui + ImPlot + ImPlot3D")
