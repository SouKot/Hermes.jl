using Test
using GodotBridge
import JSON

@testset "Julia <-> Godot Cross-Boundary SceneSpec Round-Trip" begin

    godot_bin = get(ENV, "GODOT_BIN", "/home/sourabh/.local/bin/godot")
    if !isfile(godot_bin)
        godot_bin = Sys.which("godot")
    end
    @test godot_bin !== nothing && isfile(godot_bin)

    fixtures_dir = normpath(joinpath(@__DIR__, "../../../godot/fixtures/scenespec"))
    godot_dir = normpath(joinpath(@__DIR__, "../../../godot"))

    fixture_files = [
        "minimal_des.json",
        "minimal_abm.json",
        "minimal_hybrid.json",
        "two_level_spatial.json",
        "invalid_connections.json",
        "missing_library.json",
        "future_fields.json"
    ]

    tmp_in = "/tmp/scenespec_in.mp"
    tmp_out = "/tmp/scenespec_out.mp"

    for f in fixture_files
        path = joinpath(fixtures_dir, f)
        json_str = read(path, String)
        orig_spec = decode_scenespec_json(json_str)

        # 1. Julia encodes to MessagePack
        julia_bytes = encode_scenespec_msgpack(orig_spec)
        write(tmp_in, julia_bytes)

        # 2. Godot reads tmp_in, decodes, re-encodes, writes tmp_out
        cmd = `$(godot_bin) --headless --path $(godot_dir) --script res://tests/scenespec_cross_roundtrip.gd -- $(tmp_in) $(tmp_out)`
        run(cmd)

        @test isfile(tmp_out)
        godot_bytes = read(tmp_out)
        @test !isempty(godot_bytes)

        # 3. Julia decodes Godot's output
        bounced_spec = decode_scenespec_msgpack(godot_bytes)

        # 4. Assert strict semantic equality
        eq, reason = scenespec_semantic_equal(orig_spec, bounced_spec)
        @test eq
        if !eq
            println("Cross-boundary mismatch for $f: $reason")
        else
            println("  ✓ Cross-boundary round-trip passed: $f")
        end

        # Cleanup tmp files
        rm(tmp_in; force=true)
        rm(tmp_out; force=true)
    end
end

