# ── ORCA Math & 2D LP Solver ──────────────────────────────────────────────────

using StaticArrays
using LinearAlgebra

const RVO_EPSILON = 1f-5

struct Line{F<:AbstractFloat}
    point::SVector{2,F}
    dir::SVector{2,F}
end

@inline det(a::SVector{2,F}, b::SVector{2,F}) where {F} = a[1]*b[2] - a[2]*b[1]

# 1D Linear Program to find the optimal point on a line segment
@inline function linear_program_1(lines, line_no::Int, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool)::Tuple{Bool, SVector{2,F}} where {F}
    dot_product = dot(lines[line_no].point, lines[line_no].dir)
    discriminant = dot_product^2 + radius^2 - sum(abs2, lines[line_no].point)
    
    if discriminant < zero(F)
        return false, opt_velocity
    end
    
    sqrt_disc = sqrt(discriminant)
    t_left = -dot_product - sqrt_disc
    t_right = -dot_product + sqrt_disc
    
    for i in 1:(line_no-1)
        denominator = det(lines[line_no].dir, lines[i].dir)
        numerator = det(lines[i].dir, lines[line_no].point - lines[i].point)
        
        if abs(denominator) <= RVO_EPSILON
            if numerator < zero(F)
                return false, opt_velocity
            end
            continue
        end
        
        t = numerator / denominator
        if denominator >= zero(F)
            t_right = min(t_right, t)
        else
            t_left = max(t_left, t)
        end
        
        if t_left > t_right
            return false, opt_velocity
        end
    end
    
    if direction_opt
        if dot(opt_velocity, lines[line_no].dir) > zero(F)
            return true, lines[line_no].point + t_right * lines[line_no].dir
        else
            return true, lines[line_no].point + t_left * lines[line_no].dir
        end
    else
        t = dot(lines[line_no].dir, opt_velocity - lines[line_no].point)
        if t < t_left
            return true, lines[line_no].point + t_left * lines[line_no].dir
        elseif t > t_right
            return true, lines[line_no].point + t_right * lines[line_no].dir
        else
            return true, lines[line_no].point + t * lines[line_no].dir
        end
    end
end

# 2D Linear Program to find optimal velocity given half-plane constraints
@inline function linear_program_2(lines, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool, result::SVector{2,F})::Tuple{Int, SVector{2,F}} where {F}
    if direction_opt
        result = opt_velocity * radius
    elseif sum(abs2, opt_velocity) > radius^2
        result = normalize(opt_velocity) * radius
    else
        result = opt_velocity
    end
    
    for i in 1:length(lines)
        # BUG-ORCA-02 FIX: Removed redundant outer check. det(dir, point-result) > det(dir, 0)
        # is equivalent to > 0 since det(a,0)=0 always. Only one check needed.
        if det(lines[i].dir, lines[i].point - result) > zero(F)
            # Result does not satisfy constraint i. Compute new optimal result.
            temp_result = result
            success, result = linear_program_1(lines, i, radius, opt_velocity, direction_opt)
            if !success
                return i, temp_result
            end
        end
    end
    return 0, result
end

# 3D LP Fallback for overconstrained scenarios
@inline function linear_program_3(lines, num_obst_lines::Int, begin_line::Int, radius::F, result::SVector{2,F})::SVector{2,F} where {F}
    distance = zero(F)
    
    for i in begin_line:length(lines)
        if det(lines[i].dir, lines[i].point - result) > distance
            # Create a static tuple of lines to avoid any allocations
            # Since max neighbors is small (e.g. 10), we can just build a tuple.
            # But Tuple building dynamically is hard in Julia. We can use a static array of size max_neighbors!
            # Since this is a fallback and we want zero allocations, we use MVector on stack, but for GPU it's safer to use an SVector and rebuild it.
            # Actually, `Tuple` with a fixed length `MAX_LINES` is best.
            # Let's use an MVector but we MUST initialize it correctly.
            proj_lines = typeof(lines)(undef, length(lines))
            
            for j in 1:num_obst_lines
                proj_lines[j] = lines[j]
            end
            
            num_proj_lines = num_obst_lines
            for j in (num_obst_lines+1):(i-1)
                determinant = det(lines[i].dir, lines[j].dir)
                if abs(determinant) <= RVO_EPSILON
                    if dot(lines[i].dir, lines[j].dir) > zero(F)
                        continue
                    else
                        point = (lines[i].point + lines[j].point) * F(0.5)
                    end
                else
                    point = lines[i].point + (det(lines[j].dir, lines[i].point - lines[j].point) / determinant) * lines[i].dir
                end
                
                dir = normalize(lines[j].dir - lines[i].dir)
                num_proj_lines += 1
                proj_lines[num_proj_lines] = Line(point, dir)
            end
            
            temp_result = result
            # Call LP2 with the projected lines
            # Wait, LP2 doesn't take num_proj_lines. We can pass a view, but view allocates.
            # Instead, let's make an LP2 that takes a length.
            
            # For GPU compatibility, let's just use SVector for the subset:
            subset_lines = SVector{num_proj_lines, Line{F}}(Tuple(proj_lines[1:num_proj_lines]))
            
            # The direction_opt is true, opt_velocity is lines[i].dir, radius is radius
            fail_line, temp_res = linear_program_2(subset_lines, radius, SVector(-lines[i].dir[2], lines[i].dir[1]), true, temp_result)
            
            if fail_line == 0
                result = temp_res
                distance = det(lines[i].dir, lines[i].point - result)
            end
        end
    end
    return result
end

@inline function linear_program_2_len(lines, num_lines::Int, radius::F, opt_velocity::SVector{2,F}, direction_opt::Bool, result::SVector{2,F})::Tuple{Int, SVector{2,F}} where {F}
    if direction_opt
        result = opt_velocity * radius
    elseif sum(abs2, opt_velocity) > radius^2
        result = normalize(opt_velocity) * radius
    else
        result = opt_velocity
    end
    
    for i in 1:num_lines
        if det(lines[i].dir, lines[i].point - result) > zero(F)
            temp_result = result
            success, result = linear_program_1(lines, i, radius, opt_velocity, direction_opt)
            if !success
                return i, temp_result
            end
        end
    end
    return 0, result
end

# Rewritten LP3 without views or dynamic SVectors
@inline function linear_program_3_static(lines, num_lines::Int, num_obst_lines::Int, begin_line::Int, radius::F, result::SVector{2,F})::SVector{2,F} where {F}
    distance = zero(F)
    
    for i in begin_line:num_lines
        if det(lines[i].dir, lines[i].point - result) > distance
            proj_lines = typeof(lines)(undef)
            for j in 1:num_obst_lines
                proj_lines[j] = lines[j]
            end
            
            num_proj_lines = num_obst_lines
            for j in (num_obst_lines+1):(i-1)
                determinant = det(lines[i].dir, lines[j].dir)
                if abs(determinant) <= RVO_EPSILON
                    if dot(lines[i].dir, lines[j].dir) > zero(F)
                        continue
                    else
                        point = (lines[i].point + lines[j].point) * F(0.5)
                    end
                else
                    point = lines[i].point + (det(lines[j].dir, lines[i].point - lines[j].point) / determinant) * lines[i].dir
                end
                
                dir = normalize(lines[j].dir - lines[i].dir)
                num_proj_lines += 1
                if num_proj_lines <= 25
                    proj_lines[num_proj_lines] = Line(point, dir)
                end
            end
            
            temp_result = result
            fail_line, temp_res = linear_program_2_len(proj_lines, num_proj_lines, radius, SVector(-lines[i].dir[2], lines[i].dir[1]), true, temp_result)
            
            if fail_line == 0
                result = temp_res
                distance = det(lines[i].dir, lines[i].point - result)
            end
        end
    end
    return result
end

# Compute the Velocity Obstacle Half-Plane for an agent-agent interaction
@inline function compute_orca_line(
    pos_i, vel_i, r_i,
    pos_j, vel_j, r_j,
    time_horizon, dt
)
    F = typeof(r_i)
    relative_pos = pos_j - pos_i
    relative_vel = vel_i - vel_j
    dist_sq = sum(abs2, relative_pos)
    combined_radius = r_i + r_j
    combined_radius_sq = combined_radius^2
    
    # If there is a collision right now
    if dist_sq <= combined_radius_sq
        w = relative_vel - relative_pos / dt
        w_len_sq = sum(abs2, w)
        if w_len_sq <= RVO_EPSILON
            w = SVector{2,F}(1.0f0, 0.0f0)
            w_len_sq = F(1.0)
        end
        w_len = sqrt(w_len_sq)
        unit_w = w / w_len
        dir = SVector(unit_w[2], -unit_w[1])
        u = (combined_radius / dt - w_len) * unit_w
        return Line(vel_i + u * F(0.5), dir)
    end
    
    # No immediate collision. Compute VO truncated by time_horizon.
    w = relative_vel - relative_pos / time_horizon
    w_len_sq = sum(abs2, w)
    dot_product = dot(w, relative_pos)
    
    # Project on cut-off circle
    if dot_product < zero(F) && dot_product^2 > combined_radius_sq * w_len_sq
        if w_len_sq <= RVO_EPSILON
            w = SVector{2,F}(1.0f0, 0.0f0)
            w_len_sq = F(1.0)
        end
        w_len = sqrt(w_len_sq)
        unit_w = w / w_len
        dir = SVector(unit_w[2], -unit_w[1])
        u = (combined_radius / time_horizon - w_len) * unit_w
        return Line(vel_i + u * F(0.5), dir)
    end
    
    # Project on legs of VO cone
    leg = sqrt(dist_sq - combined_radius_sq)
    if det(relative_pos, w) > zero(F)
        dir = SVector(relative_pos[1]*leg - relative_pos[2]*combined_radius, relative_pos[1]*combined_radius + relative_pos[2]*leg) / dist_sq
    else
        dir = -SVector(relative_pos[1]*leg + relative_pos[2]*combined_radius, -relative_pos[1]*combined_radius + relative_pos[2]*leg) / dist_sq
    end
    
    dot_w_dir = dot(relative_vel, dir)
    u = dot_w_dir * dir - relative_vel
    return Line(vel_i + u * F(0.5), dir)
end
