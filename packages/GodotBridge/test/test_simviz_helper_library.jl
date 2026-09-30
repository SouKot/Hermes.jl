# packages/GodotBridge/test/test_simviz_helper_library.jl
#
# Comprehensive verification suite for Milestone M-1:
# SimViz Helper Library & User Scripting Vocabulary (Categories 1–13)

using Test
using SimCore
using SimCore.SimViz
using SimDES
using GodotBridge

@testset "M-1: SimViz Helper Library & User Scripting Vocabulary" begin

    @testset "1. EntityHandle Unboxed O(1) Addressing, self(), item() & Selectors" begin
        @test isbits(EntityHandle(Int32(1), UInt8(1)))
        @test sizeof(EntityHandle) <= 8
        @test !isvalid(INVALID_HANDLE)

        spec = GodotBridge.create_default_scene()
        spec["elements"][2]["properties"]["group"] = "staging_buffers"
        spec["elements"][3]["properties"]["groups"] = ["workstations", "critical_line"]
        spec["elements"][3]["properties"]["container"] = "Cell_Alpha"

        comp = GodotBridge.compile_scenespec(spec)
        @test comp.success
        w = comp.world

        # Verify PortDirectory registration
        h_q   = w.port_directory.name_to_handle["q_staging"]
        h_srv = w.port_directory.name_to_handle["srv_assembly"]
        h_cnv = w.port_directory.name_to_handle["conv_outfeed"]
        h_cel = w.port_directory.name_to_handle["Cell_Alpha"]

        @test isvalid(h_q) && h_q.kind == UInt8(1)
        @test isvalid(h_srv) && h_srv.kind == UInt8(1)
        @test isvalid(h_cnv) && h_cnv.kind == UInt8(1)
        @test isvalid(h_cel) && h_cel.kind == UInt8(3)

        # Create a hook context as if srv_assembly's on_entry hook fired for item 42
        eid = UInt64(42)
        SimCore.add_des_agent!(w, eid, SimCore.DESAgent(1.0, comp.execution_ir.element_to_zone["srv_assembly"], 5, 1.0))
        SimCore.set_entity_attribute!(w, eid, "entity_type", "pallet")
        SimCore.set_entity_attribute!(w, eid, "name", "Pallet_42")

        ctx = HookContext(
            w, eid, comp.execution_ir.element_to_zone["srv_assembly"], "srv_assembly", 2.5;
            element_to_zone = comp.execution_ir.element_to_zone,
            zone_to_element = comp.execution_ir.zone_to_element,
            fel = comp.fel,
            configs = comp.zone_configs
        )

        SimCore.with_hook_context(ctx) do _
            # Zero-arg and explicit ctx forms
            @test self() == h_srv
            @test self(ctx) == h_srv
            @test self_handle() == h_srv
            @test item() == EntityHandle(Int32(42), UInt8(2))
            @test item(ctx) == EntityHandle(Int32(42), UInt8(2))
            @test item_handle() == EntityHandle(Int32(42), UInt8(2))

            @test entity("q_staging") == h_q
            @test entity(:conv_outfeed) == h_cnv
            @test entity_name() == "srv_assembly"
            @test entity_name(item()) == "Pallet_42"
            @test entity_kind() == :server
            @test entity_kind(h_cnv) == :conveyor
            @test entity_kind(item()) == :pallet
            @test entity_kind(h_cel) == :subgraph

            # Composable selectors
            @test h_cnv in entities_of_kind(:conveyor)
            @test h_srv in entities_of_kind(:server)
            @test item() in entities_of_kind(:item)
            @test entities_where(:conveyor, c -> speed(c) > 1.0) == [h_cnv]
            @test h_q in entities_in_group(:staging_buffers)
            @test h_srv in entities_in_group(:workstations)
            @test length(all_entities()) >= 5

            # Batch mutation on Vector{EntityHandle}
            set_speed!(entities_of_kind(:conveyor), 3.2)
            @test speed(h_cnv) ≈ 3.2
        end
    end

    @testset "2. Strictly Directional Port Topology & Particular Connected-Entity Selectors" begin
        w = SimCore.SimWorld()
        fel = SimDES.FutureEventList()
        # Router_1 connected via :out_flow to Server_A (slot 1), Server_B (slot 2), Server_C (slot 3)
        cfgs = Dict{Int, SimDES.ZoneConfig}(
            1 => SimDES.ZoneConfig(id=1, num_servers=1, capacity=10),
            2 => SimDES.ZoneConfig(id=2, num_servers=2, capacity=10),
            3 => SimDES.ZoneConfig(id=3, num_servers=2, capacity=20),
            4 => SimDES.ZoneConfig(id=4, num_servers=4, capacity=15),
        )
        for (_, c) in cfgs
            SimDES.build_world!(w, c)
        end
        h_r = SimCore.register_entity_handle!(w, "Router_1", :server; zone_id=1)
        h_a = SimCore.register_entity_handle!(w, "Server_A", :server; zone_id=2)
        h_b = SimCore.register_entity_handle!(w, "Server_B", :server; zone_id=3)
        h_c = SimCore.register_entity_handle!(w, "Server_C", :server; zone_id=4)

        SimCore.register_port_wire!(w, h_r, :out_flow, h_a, :in_flow; wire_id="w1")
        SimCore.register_port_wire!(w, h_r, :out_flow, h_b, :in_flow; wire_id="w2")
        SimCore.register_port_wire!(w, h_r, :out_flow, h_c, :in_flow; wire_id="w3")
        SimCore.register_port_wire!(w, h_r, :out_signal, h_b, :in_signal; wire_id="ws1")

        # Set different queue lengths and attributes on Server_A, Server_B, Server_C
        w.zone_states[2].queue_length = 6
        w.zone_states[3].queue_length = 1
        w.zone_states[4].queue_length = 4

        ctx = HookContext(w, 0, 1, "Router_1", 10.0; fel=fel, configs=cfgs)
        SimCore.with_hook_context(ctx) do _
            set_attr!(h_a, :specialty, :standard)
            set_attr!(h_b, :specialty, :hazmat)
            set_attr!(h_c, :specialty, :hazmat)

            @test :out_flow in output_ports()
            @test :in_flow in input_ports(h_a)
            @test port_direction(:out_flow) == :out
            @test port_direction(h_a, :in_flow) == :in
            @test is_connected(:out_flow)
            @test connection_count(:out_flow) == 3

            # Slot-indexed particular connected entity
            @test connected_entity(:out_flow, 1) == h_a
            @test connected_entity(:out_flow, 2) == h_b
            @test connected_entity(:out_flow, 3) == h_c
            @test connected_entity(:out_flow, 99) == INVALID_HANDLE
            @test downstream_entities() == [h_a, h_b, h_c]
            @test upstream_entities(h_b) == [h_r]

            # Predicate & argmin/argmax particular connected entity
            @test connected_entity_where(:out_flow, e -> get_attr(e, :specialty) == :hazmat) == h_b
            @test connected_entities_where(:out_flow, e -> get_attr(e, :specialty) == :hazmat) == [h_b, h_c]
            @test connected_entity_argmin(:out_flow, e -> queue_length(e)) == h_b
            @test connected_entity_argmax(:out_flow, e -> num_servers(e)) == h_c

            # Signal propagation across port wire
            send_signal!(:out_signal, 42.5)
            @test read_signal(h_b, :in_signal) == 42.5
        end
    end

    @testset "3. Symmetric Containment Hierarchy (Upward & Downward)" begin
        w = SimCore.SimWorld()
        fel = SimDES.FutureEventList()
        cfgs = Dict{Int, SimDES.ZoneConfig}(
            1 => SimDES.ZoneConfig(id=1, num_servers=1, capacity=10),
            2 => SimDES.ZoneConfig(id=2, num_servers=2, capacity=10),
        )
        for (_, c) in cfgs
            SimDES.build_world!(w, c)
        end

        h_plant = SimCore.register_entity_handle!(w, "Plant_North", :subgraph; is_container=true)
        h_cell  = SimCore.register_entity_handle!(w, "Welding_Cell_A", :subgraph; is_container=true)
        h_srv1  = SimCore.register_entity_handle!(w, "Welder_1", :server; zone_id=1)
        h_srv2  = SimCore.register_entity_handle!(w, "Welder_2", :server; zone_id=2)

        # Establish Plant_North -> Welding_Cell_A -> [Welder_1, Welder_2]
        w.containment_parent[h_cell] = h_plant
        w.containment_children[h_plant] = [h_cell]
        w.containment_parent[h_srv1] = h_cell
        w.containment_parent[h_srv2] = h_cell
        w.containment_children[h_cell] = [h_srv1, h_srv2]

        # Place flowing item 101 in Welder_1 (queue) and item 102 in Welder_1 (in service)
        SimCore.add_des_agent!(w, UInt64(101), SimCore.DESAgent(1.0, 1, 2, Inf))
        SimCore.add_des_agent!(w, UInt64(102), SimCore.DESAgent(0.5, 1, 9, 0.5))
        push!(w.zone_states[1].queue, UInt64(101))
        w.zone_states[1].queue_length = 1
        w.zone_states[1].busy_servers = 1

        ctx = HookContext(w, 101, 1, "Welder_1", 3.0; fel=fel, configs=cfgs)
        SimCore.with_hook_context(ctx) do _
            # A. Upward ("Who Contains Me?")
            @test has_container()
            @test container_entity() == h_cell
            @test container_entity(self()) == h_cell
            @test container_entity(item()) == h_srv1
            @test root_container() == h_plant
            @test root_container(item()) == h_plant
            @test ancestors() == [h_cell, h_plant]
            @test ancestors(item()) == [h_srv1, h_cell, h_plant]

            # B. Downward ("What Do I Contain?")
            # On station Welder_1 (contains items 101 and 102)
            @test contained_count() == 2
            @test contains_entity(item())
            @test first_contained() == EntityHandle(Int32(102), UInt8(2)) # in-service item first
            @test last_contained() == EntityHandle(Int32(101), UInt8(2))  # queued item last
            @test first_contained(filter=:queued) == EntityHandle(Int32(101), UInt8(2))
            @test first_contained(filter=:in_service) == EntityHandle(Int32(102), UInt8(2))
            @test contained_entity_argmax(it -> priority(it)) == EntityHandle(Int32(102), UInt8(2))
            @test contained_entity_argmin(it -> priority(it)) == EntityHandle(Int32(101), UInt8(2))

            # On subgraph Welding_Cell_A (contains Welder_1 and Welder_2)
            @test contained_entities(h_cell) == [h_srv1, h_srv2]
            @test contained_entity(h_cell, 2) == h_srv2
            @test contained_entity_where(h_cell, s -> is_busy(s)) == h_srv1

            # C. Dynamic Palletizing (put_inside! / take_out!)
            pallet = create_entity!(:pallet)
            box1   = create_entity!(:box; weight=4.0)
            box2   = create_entity!(:box; weight=8.5)
            put_inside!(pallet, box1)
            put_inside!(pallet, box2)
            @test contained_count(pallet) == 2
            @test container_entity(box1) == pallet
            @test contained_entity_argmax(pallet, b -> get_attr(b, :weight, 0.0)) == box2
            popped = take_out!(pallet, box1)
            @test popped == box1
            @test contained_count(pallet) == 1
        end
    end

    @testset "4. Multi-Queue Intake & Pull Selection (5 Queues -> 1 Server)" begin
        # Build a SceneSpec with 5 queues feeding 1 server
        elements = Any[
            Dict("id" => "srv_merge", "kind" => "server",
                 "properties" => Dict("servers" => 1, "service_time" => Dict("type" => "constant", "value" => 2.0), "intake_mode" => "custom"),
                 "transform" => Dict("position" => [5.0, 0.0, 0.8]))
        ]
        connections = Any[]
        for i in 1:5
            qid = "q_in_$i"
            push!(elements, Dict(
                "id" => qid,
                "kind" => "queue",
                "properties" => Dict("capacity" => 20, "discipline" => "FIFO"),
                "transform" => Dict("position" => [0.0, Float64(i * 2), 0.8])
            ))
            push!(connections, Dict(
                "id" => "c_q_$i",
                "source_element" => qid,
                "source_port" => "flow_out",
                "target_element" => "srv_merge",
                "target_port" => "flow_in"
            ))
        end
        spec = Dict(
            "spec_version" => "1.0.0",
            "scene" => Dict("id" => "multi_q_test", "name" => "5-Queue Merge Server"),
            "simulation" => Dict("mode" => "des_only", "time_unit" => "seconds"),
            "elements" => elements,
            "connections" => connections
        )

        comp = GodotBridge.compile_scenespec(spec)
        @test comp.success
        w = comp.world

        # Verify all 5 queues kept distinct ZoneIDs (not fused into srv_merge!)
        srv_zid = comp.execution_ir.element_to_zone["srv_merge"]
        for i in 1:5
            qzid = comp.execution_ir.element_to_zone["q_in_$i"]
            @test qzid != srv_zid
            # Enqueue 1 item into each queue with distinct priority = i * 10
            uid = SimCore.new_entity_id!(w)
            SimCore.add_des_agent!(w, uid, SimCore.DESAgent(1.0, qzid, i * 10, Inf))
            SimCore.set_entity_attribute!(w, uid, "priority", i * 10)
            SimCore.set_entity_attribute!(w, uid, "slot_tag", i)
            push!(w.zone_states[qzid].queue, uid)
            w.zone_states[qzid].queue_length = 1
        end
        # Also add a second item to q_in_3 so q_in_3 is the longest queue (length 2)
        qzid3 = comp.execution_ir.element_to_zone["q_in_3"]
        uid_extra = SimCore.new_entity_id!(w)
        SimCore.add_des_agent!(w, uid_extra, SimCore.DESAgent(1.2, qzid3, 25, Inf))
        push!(w.zone_states[qzid3].queue, uid_extra)
        w.zone_states[qzid3].queue_length = 2

        ctx = HookContext(w, 0, srv_zid, "srv_merge", 2.0;
                          element_to_zone=comp.execution_ir.element_to_zone,
                          zone_to_element=comp.execution_ir.zone_to_element,
                          fel=comp.fel, configs=comp.zone_configs)

        SimCore.with_hook_context(ctx) do _
            heads = port_head_items(:in_flow)
            @test length(heads) == 5
            all_cands = port_all_items(:in_flow)
            @test length(all_cands) == 6

            # 1. Pull highest priority across all 5 queues -> should pull from q_in_5 (priority 50)
            p1 = pull_from_port_argmax!(:in_flow, c -> c.priority)
            @test isvalid(p1)
            @test get_attr(p1, :slot_tag) == 5

            # 2. Pull from longest connected queue -> should pull from q_in_3 (length 2)
            p2 = pull_from_port_longest!(:in_flow)
            @test isvalid(p2)
            @test get_attr(p2, :slot_tag) == 3

            # 3. Pull by slot order -> should pull from q_in_1 (slot 1)
            p3 = pull_from_port_slot_order!(:in_flow)
            @test isvalid(p3)
            @test get_attr(p3, :slot_tag) == 1

            # 4. Pull matching predicate -> should pull from q_in_4 (slot_tag == 4)
            p4 = pull_from_port_where!(:in_flow, c -> get_attr(c.item, :slot_tag, 0) == 4)
            @test isvalid(p4)
            @test get_attr(p4, :slot_tag) == 4
        end
    end

    @testset "5. Low-Level DEVS Event Engine & Sequence-Dependent Setup Times" begin
        spec = GodotBridge.create_default_scene()
        spec["elements"][1]["properties"]["interarrival_time"] = Dict("type" => "constant", "value" => 1.0)
        spec["elements"][3]["properties"]["service_time"] = Dict("type" => "constant", "value" => 1.0)
        spec["elements"][3]["properties"]["hooks"] = Dict(
            "on_entry" => """
                n = inc_attr!(self(), :arrived_count, 1)
                set_attr!(item(), :family, isodd(n) ? :A : :B)
                if n == 1
                    schedule_event!(2.0, :custom_Check; payload = 99)
                end
            """,
            "on_service_start" => """
                if last_processed_attr(:family, :A) != get_attr(item(), :family, :A)
                    add_setup_time!(0.5)
                    increment_counter!(:setup_changeovers, 1)
                end
            """,
            "on_event" => """
                if event_tag() == :custom_Check
                    set_gauge!(:last_event_payload, event_payload())
                end
            """
        )

        comp = GodotBridge.compile_scenespec(spec)
        @test comp.success
        inst = GodotBridge.SimulationInstance(
            "test_devs", comp.world, comp.fel, comp.zone_configs, comp.source_map, comp.execution_ir;
            seed = 7, clock_speed = Inf
        )
        GodotBridge.step_until!(inst, 6.0; fast_forward = true)

        @test get(comp.world.user_telemetry.gauges, :last_event_payload, 0.0) == 99.0
        @test get(comp.world.user_telemetry.counters, :setup_changeovers, 0) >= 1
    end

    @testset "6. Conveyor Kinematics (:free_flow, :accumulating, :indexing)" begin
        # Test accumulating conveyor spacing and indexing conveyor step pulses
        spec = GodotBridge.create_default_scene()
        spec["elements"][4]["properties"] = Dict{String, Any}(
            "length" => 6.0,
            "speed" => 1.5,
            "capacity" => 4,
            "conveyor_mode" => "indexing",
            "accumulation_pitch" => 2.0,
            "index_interval" => 0.5
        )

        comp = GodotBridge.compile_scenespec(spec)
        @test comp.success
        cnv_zid = comp.execution_ir.element_to_zone["conv_outfeed"]
        @test comp.zone_configs[cnv_zid].conveyor_mode == :indexing
        @test comp.zone_configs[cnv_zid].conveyor_pitch == 2.0

        # Manually arrive an item onto the indexing conveyor at t = 0.0
        uid = SimCore.new_entity_id!(comp.world)
        SimDES.schedule!(comp.fel, SimCore.EntityArrival(uid, cnv_zid, 0.0, 0, false), 0.0)
        inst = GodotBridge.SimulationInstance(
            "test_indexing", comp.world, comp.fel, comp.zone_configs, comp.source_map, comp.execution_ir;
            seed = 11, clock_speed = Inf
        )
        # At t = 0.6s (after 1 pulse at t = 0.5s), distance should be 2.0m (progress = 2.0 / 6.0)
        GodotBridge.step_until!(inst, 0.6; fast_forward = true)
        @test haskey(comp.world.entity_kinematics, uid)
        @test SimCore.kinematics_distance(comp.world.entity_kinematics[uid], 0.6) ≈ 2.0
        @test SimCore.kinematics_progress(comp.world.entity_kinematics[uid], 0.6) ≈ (2.0 / 6.0)

        # At t = 1.6s (after 3 pulses at 0.5, 1.0, 1.5s -> 6.0m), item has completed the 6.0m conveyor!
        GodotBridge.step_until!(inst, 1.6; fast_forward = true)
        @test !haskey(comp.world.entity_kinematics, uid)
    end

    @testset "7. Helper Catalog Completeness (>= 95 Documented Primitives)" begin
        @test length(SimCore.SimViz.HELPER_CATALOG) >= 95
        categories = Set(m.category for m in SimCore.SimViz.HELPER_CATALOG)
        @test :identity in categories
        @test :ports in categories
        @test :containment in categories
        @test :intake in categories
        @test :attributes in categories
        @test :state in categories
        @test :control in categories
        @test :server in categories
        @test :routing in categories
        @test :events in categories
        @test :kinematics in categories
        @test :creation in categories
        @test :visuals in categories
        @test :random in categories
        @test :telemetry in categories

        md_doc = SimCore.SimViz.helper_docs_markdown()
        @test occursin("connected_entity", md_doc)
        @test occursin("container_entity", md_doc)
        @test occursin("pull_from_port_argmax!", md_doc)
        doc_meta = Base.Docs.meta(SimCore)[Base.Docs.Binding(SimCore, :connected_entity)]
        doc_str = join([join(d.text, "\n") for d in values(doc_meta.docs)], "\n")
        @test occursin("connected_entity", doc_str)
        @test occursin("Hook Context", doc_str)
    end
end
