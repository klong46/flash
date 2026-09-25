-- ============================================================
--  FLASH v2  —  Love2D Lightning Strategy Game
--  8×8 board · Queen orbs · 8-dir shooting · Move + Attack
-- ============================================================

-- ── Constants ────────────────────────────────────────────────
local GRID_W = 8
local GRID_H = 8

local EMPTY    = 0
local BLUE_ORB = 1
local BLUE_GUN = 2
local RED_ORB  = 3
local RED_GUN  = 4

local STATE_SELECT    = "SELECT"
local STATE_AIM       = "AIM"
local STATE_ANIMATING = "ANIMATING"
local STATE_GAME_OVER = "GAME_OVER"

local CELL_SIZE      = 68
local BOARD_OFFSET_X = 80
local BOARD_OFFSET_Y = 80

-- Right action panel start x (just past the board)
local PANEL_X = BOARD_OFFSET_X + GRID_W * CELL_SIZE + 24  -- = 648

-- All 8 normalised directions: E SE S SW W NW N NE
local DIR8 = {
    { 1, 0}, { 1, 1}, { 0, 1}, {-1, 1},
    {-1, 0}, {-1,-1}, { 0,-1}, { 1,-1},
}

-- ── Starting Layout ──────────────────────────────────────────
-- Matches user palette JSON:
--   Blue: Gunslinger col 4, Orbs cols 5-8  (row 1 / top)
--   Red : Orbs cols 1-4, Gunslinger col 5  (row 8 / bottom)
local INITIAL_GRID = {
    {BLUE_GUN, 0, 0, 0},
    {BLUE_ORB, BLUE_ORB, BLUE_ORB, BLUE_ORB, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, RED_ORB, RED_ORB, RED_ORB, RED_ORB,},
    {0, 0, 0, 0, 0, 0, 0, RED_GUN},
}

-- ── Game State ───────────────────────────────────────────────
local fonts = {}
local game  = {}

function reset_game()
    game.grid = {}
    for y = 1, GRID_H do
        game.grid[y] = {}
        for x = 1, GRID_W do
            game.grid[y][x] = INITIAL_GRID[y][x]
        end
    end
    game.turn         = "red"
    game.state        = STATE_SELECT
    game.selected_x   = nil
    game.selected_y   = nil
    game.valid_moves  = {}

    -- Per-turn action tracking
    game.has_moved    = false
    game.has_attacked = false

    -- Aim mode
    game.aim_gun_x = nil
    game.aim_gun_y = nil

    -- Animation
    game.anim_steps      = {}
    game.anim_index      = 1
    game.anim_timer      = 0
    game.anim_speed      = 0.09
    game.anim_attacker   = nil   -- whose turn triggered the current animation
    game.active_segments = {}
    game.lit_orbs        = {}
    game.destroyed_orbs  = {}

    -- CPU
    game.cpu_pending_move = nil  -- move to execute after attack animation
    game.game_mode    = game.game_mode    or "pvc"
    game.player_color = game.player_color or "red"
    game.cpu_timer    = 0
    game.cpu_delay    = 0.55

    game.winner     = nil
    game.win_reason = ""
end

-- ── Love2D Lifecycle ─────────────────────────────────────────
function love.load()
    math.randomseed(os.time())
    love.window.setTitle("FLASH — Lightning Strategy Game")
    fonts.title  = love.graphics.newFont(22)
    fonts.status = love.graphics.newFont(15)
    fonts.button = love.graphics.newFont(13)
    fonts.small  = love.graphics.newFont(11)
    fonts.large  = love.graphics.newFont(28)
    reset_game()
end

function love.update(dt)
    -- ── Animation tick ────────────────────────────────────
    if game.state == STATE_ANIMATING then
        game.anim_timer = game.anim_timer + dt
        if game.anim_timer >= game.anim_speed then
            game.anim_timer = 0

            if game.anim_index <= #game.anim_steps then
                -- Advance one animation step
                local step = game.anim_steps[game.anim_index]
                for _, seg in ipairs(step.segments) do
                    table.insert(game.active_segments, seg)
                end
                for _, o in ipairs(step.new_lit_orbs) do
                    game.lit_orbs[o.x .. "," .. o.y] = true
                end
                for _, o in ipairs(step.new_destroyed_orbs) do
                    game.destroyed_orbs[o.x .. "," .. o.y] = true
                end
                if step.hit_gunslinger then
                    local victim    = step.hit_gunslinger
                    game.winner     = (victim == "red") and "blue" or "red"
                    game.win_reason = (victim == "red" and "Red" or "Blue") .. " Gunslinger destroyed!"
                end
                game.anim_index = game.anim_index + 1
            else
                -- Animation finished — apply orb destruction to the grid
                for k in pairs(game.destroyed_orbs) do
                    local px, py = k:match("(%d+),(%d+)")
                    game.grid[tonumber(py)][tonumber(px)] = EMPTY
                end
                game.active_segments = {}
                game.lit_orbs        = {}
                game.destroyed_orbs  = {}

                if game.winner then
                    game.state = STATE_GAME_OVER

                elseif game.cpu_pending_move then
                    -- CPU queued a move to execute right after its attack
                    local m = game.cpu_pending_move
                    game.cpu_pending_move = nil
                    local piece = game.grid[m.from_y][m.from_x]
                    game.grid[m.from_y][m.from_x] = EMPTY
                    game.grid[m.to_y][m.to_x]     = piece
                    game.has_moved = true
                    end_turn()

                elseif game.anim_attacker == get_cpu_color() or game.has_moved then
                    -- CPU's turn always ends after its animation, or human used both actions
                    end_turn()

                else
                    -- Human attacked but hasn't moved yet — stay on their turn
                    game.state = STATE_SELECT
                end
            end
        end

    -- ── CPU thinking delay ────────────────────────────────
    elseif game.state == STATE_SELECT and is_cpu_turn() then
        game.cpu_timer = game.cpu_timer + dt
        if game.cpu_timer >= game.cpu_delay then
            game.cpu_timer = 0
            execute_cpu_turn()
        end
    end
end

function love.keypressed(key)
    if key == "r" then
        reset_game()
    elseif key == "escape" then
        if game.state == STATE_AIM then
            cancel_aim()
        else
            deselect()
        end
    elseif key == "a" then
        -- Shortcut: enter aim mode
        if game.state == STATE_SELECT and not is_cpu_turn() and not game.has_attacked then
            start_aim_mode()
        end
    elseif key == "return" or key == "kpenter" then
        -- Shortcut: end turn
        if game.state == STATE_SELECT and not is_cpu_turn() then
            end_turn()
        end
    end
end

function love.mousepressed(x, y, button)
    -- Game over: any click resets
    if game.state == STATE_GAME_OVER then
        reset_game()
        return
    end

    -- Block input during animation
    if game.state == STATE_ANIMATING then return end

    -- Block player input during CPU turn
    if is_cpu_turn() then return end

    -- ── AIM MODE: fire or cancel ──────────────────────────
    if game.state == STATE_AIM then
        if button == 1 then
            local gpx = BOARD_OFFSET_X + (game.aim_gun_x - 0.5) * CELL_SIZE
            local gpy = BOARD_OFFSET_Y + (game.aim_gun_y - 0.5) * CELL_SIZE
            local adx, ady = snap_direction(x - gpx, y - gpy)
            trigger_attack(adx, ady)
        elseif button == 2 then
            cancel_aim()
        end
        return
    end

    -- ── SELECT MODE ───────────────────────────────────────
    if game.state ~= STATE_SELECT then return end

    -- Top-bar buttons ─────────────────────────────────────
    -- Mode toggle [650..770 × 10..40]
    if x >= 650 and x <= 770 and y >= 10 and y <= 40 then
        game.game_mode = (game.game_mode == "pvp") and "pvc" or "pvp"
        reset_game()
        return
    end
    -- Player colour toggle [775..895 × 10..40] (pvc only)
    if game.game_mode == "pvc" and x >= 775 and x <= 895 and y >= 10 and y <= 40 then
        game.player_color = (game.player_color == "red") and "blue" or "red"
        reset_game()
        return
    end

    -- Right panel buttons ─────────────────────────────────
    -- ATTACK button [PANEL_X .. PANEL_X+180 × 148..188]
    if not game.has_attacked
        and x >= PANEL_X and x <= PANEL_X + 180
        and y >= 148 and y <= 188
    then
        start_aim_mode()
        return
    end
    -- END TURN button [PANEL_X .. PANEL_X+180 × 205..245]
    if x >= PANEL_X and x <= PANEL_X + 180 and y >= 205 and y <= 245 then
        end_turn()
        return
    end

    -- Board click ─────────────────────────────────────────
    local col = math.floor((x - BOARD_OFFSET_X) / CELL_SIZE) + 1
    local row = math.floor((y - BOARD_OFFSET_Y) / CELL_SIZE) + 1
    if in_bounds(col, row) then
        select_cell(col, row)
    end
end

-- ── Piece Helpers ─────────────────────────────────────────────
function is_player_piece(piece, player)
    if player == "red" then
        return piece == RED_GUN or piece == RED_ORB
    else
        return piece == BLUE_GUN or piece == BLUE_ORB
    end
end

function is_gunslinger(piece) return piece == RED_GUN  or piece == BLUE_GUN end
function is_orb(piece)        return piece == RED_ORB  or piece == BLUE_ORB end
function in_bounds(x, y)      return x >= 1 and x <= GRID_W and y >= 1 and y <= GRID_H end

function get_cpu_color()
    if game.game_mode ~= "pvc" then return nil end
    return (game.player_color == "red") and "blue" or "red"
end

function is_cpu_turn()
    return game.game_mode == "pvc"
       and game.turn == get_cpu_color()
       and game.state == STATE_SELECT
end

-- Returns {x,y} of the named player's gunslinger, or nil
function get_gunslinger_pos(player, g)
    local grid = g or game.grid
    local gp   = (player == "red") and RED_GUN or BLUE_GUN
    for y = 1, GRID_H do
        for x = 1, GRID_W do
            if grid[y][x] == gp then return {x = x, y = y} end
        end
    end
    return nil
end

-- ── Movement Calculation ─────────────────────────────────────
function calculate_valid_moves(x, y, custom_grid)
    local g     = custom_grid or game.grid
    local moves = {}
    local piece = g[y][x]
    if piece == EMPTY then return moves end

    if is_gunslinger(piece) then
        -- King movement: one step in any of 8 directions
        for dx = -1, 1 do
            for dy = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    local nx, ny = x + dx, y + dy
                    if in_bounds(nx, ny) and g[ny][nx] == EMPTY then
                        table.insert(moves, {x = nx, y = ny})
                    end
                end
            end
        end

    elseif is_orb(piece) then
        -- Queen movement: slide any distance in all 8 directions until blocked
        for dx = -1, 1 do
            for dy = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    local step = 1
                    while true do
                        local nx = x + dx * step
                        local ny = y + dy * step
                        if in_bounds(nx, ny) and g[ny][nx] == EMPTY then
                            table.insert(moves, {x = nx, y = ny})
                            step = step + 1
                        else
                            break
                        end
                    end
                end
            end
        end
    end
    return moves
end

-- Snap a raw (dx, dy) offset to the nearest of 8 grid directions
function snap_direction(dx, dy)
    if dx == 0 and dy == 0 then return 0, -1 end
    local angle  = math.atan2(dy, dx)
    local sector = math.floor(angle / (math.pi / 4) + 0.5) % 8
    return DIR8[sector + 1][1], DIR8[sector + 1][2]
end

-- ── Selection & Movement ─────────────────────────────────────
function select_cell(x, y)
    if game.state ~= STATE_SELECT then return end
    local piece = game.grid[y][x]

    -- Clicking own piece selects it
    -- (valid_moves are only shown if move action hasn't been used)
    if is_player_piece(piece, game.turn) then
        game.selected_x  = x
        game.selected_y  = y
        game.valid_moves = (not game.has_moved)
                           and calculate_valid_moves(x, y)
                           or  {}
        return
    end

    -- Clicking a valid destination executes the move
    if game.selected_x and not game.has_moved then
        for _, m in ipairs(game.valid_moves) do
            if m.x == x and m.y == y then
                local p = game.grid[game.selected_y][game.selected_x]
                game.grid[game.selected_y][game.selected_x] = EMPTY
                game.grid[y][x] = p
                game.has_moved  = true
                deselect()
                -- Auto-end turn if attack already spent too
                if game.has_attacked then end_turn() end
                return
            end
        end
    end

    deselect()
end

function deselect()
    game.selected_x  = nil
    game.selected_y  = nil
    game.valid_moves = {}
end

function end_turn()
    game.has_moved    = false
    game.has_attacked = false
    game.aim_gun_x    = nil
    game.aim_gun_y    = nil
    game.turn         = (game.turn == "red") and "blue" or "red"
    game.cpu_timer    = 0
    game.state        = STATE_SELECT
    deselect()
end

-- ── Aim Mode ─────────────────────────────────────────────────
function start_aim_mode()
    if game.has_attacked then return end
    local gun = get_gunslinger_pos(game.turn)
    if not gun then return end
    deselect()
    game.aim_gun_x = gun.x
    game.aim_gun_y = gun.y
    game.state     = STATE_AIM
end

function cancel_aim()
    game.aim_gun_x = nil
    game.aim_gun_y = nil
    game.state     = STATE_SELECT
end

-- ── Lightning Simulation ─────────────────────────────────────
-- Orb adjacency for chain conduction (cardinal only)
function get_adjacent_orbs(grid, x, y, destroyed_set)
    local adj  = {}
    local dirs = {{0,-1},{0,1},{-1,0},{1,0}}
    for _, d in ipairs(dirs) do
        local nx, ny = x + d[1], y + d[2]
        if in_bounds(nx, ny) then
            local key = nx .. "," .. ny
            if is_orb(grid[ny][nx]) and not destroyed_set[key] then
                table.insert(adj, {x=nx, y=ny, dx=d[1], dy=d[2]})
            end
        end
    end
    return adj
end

function simulate_lightning(gx, gy, sdx, sdy, custom_grid)
    local src = custom_grid or game.grid
    -- Work on a copy so simulation doesn't mutate the real grid
    local gc  = {}
    for y = 1, GRID_H do
        gc[y] = {}
        for x = 1, GRID_W do gc[y][x] = src[y][x] end
    end

    local steps     = {}
    local visited   = {}   -- orbs that have been lit this turn
    local destroyed = {}   -- orbs already destroyed
    local gun_hit   = nil

    local heads = {
        {x = gx + sdx, y = gy + sdy, dx = sdx, dy = sdy, px = gx, py = gy}
    }

    while #heads > 0 and not gun_hit do
        local step = {
            segments          = {},
            new_lit_orbs      = {},
            new_destroyed_orbs= {},
            hit_gunslinger    = nil,
        }
        local next_heads = {}
        local by_cell    = {}

        -- Group heads arriving at the same cell this step
        for _, h in ipairs(heads) do
            table.insert(step.segments, {x1=h.px, y1=h.py, x2=h.x, y2=h.y})
            if in_bounds(h.x, h.y) then
                local k = h.x .. "," .. h.y
                if not by_cell[k] then by_cell[k] = {} end
                table.insert(by_cell[k], h)
            end
        end

        for key, hs in pairs(by_cell) do
            local h     = hs[1]
            local x, y = h.x, h.y
            local piece = gc[y][x]

            if is_gunslinger(piece) then
                -- Lightning hits a gunslinger → game over
                step.hit_gunslinger = (piece == RED_GUN) and "red" or "blue"
                gun_hit = step.hit_gunslinger

            elseif is_orb(piece) then
                if #hs >= 2 or visited[key] then
                    -- Struck from multiple directions simultaneously, or lit again → destroy
                    destroyed[key] = true
                    visited[key]   = true
                    table.insert(step.new_destroyed_orbs, {x=x, y=y})
                else
                    visited[key] = true
                    table.insert(step.new_lit_orbs, {x=x, y=y})

                    local all_adj = get_adjacent_orbs(gc, x, y, destroyed)
                    if #all_adj == 0 then
                        -- Lone orb → destroy, ray stops
                        destroyed[key] = true
                        table.insert(step.new_destroyed_orbs, {x=x, y=y})
                    else
                        local unvisited = {}
                        for _, a in ipairs(all_adj) do
                            if not visited[a.x .. "," .. a.y] then
                                table.insert(unvisited, a)
                            end
                        end
                        if #unvisited > 0 then
                            -- Chain to all unvisited neighbours
                            for _, a in ipairs(unvisited) do
                                table.insert(next_heads,
                                    {x=a.x, y=a.y, dx=a.dx, dy=a.dy, px=x, py=y})
                            end
                        else
                            -- All neighbours already visited → exit chain in incoming direction
                            table.insert(next_heads,
                                {x=x+h.dx, y=y+h.dy, dx=h.dx, dy=h.dy, px=x, py=y})
                        end
                    end
                end

            else
                -- Empty cell: each head continues in its own direction
                for _, head in ipairs(hs) do
                    table.insert(next_heads,
                        {x=x+head.dx, y=y+head.dy, dx=head.dx, dy=head.dy, px=x, py=y})
                end
            end
        end

        table.insert(steps, step)
        heads = next_heads
    end

    return steps
end

function trigger_attack(dir_dx, dir_dy)
    local gun = get_gunslinger_pos(game.turn)
    if not gun then return end

    game.has_attacked  = true
    game.anim_attacker = game.turn   -- remember who fired for post-anim logic
    game.aim_gun_x     = nil
    game.aim_gun_y     = nil
    deselect()

    local steps = simulate_lightning(gun.x, gun.y, dir_dx, dir_dy)
    game.anim_steps      = steps
    game.anim_index      = 1
    game.anim_timer      = 0
    game.active_segments = {}
    game.lit_orbs        = {}
    game.destroyed_orbs  = {}
    game.state = STATE_ANIMATING
end

-- ── AI / CPU Engine ──────────────────────────────────────────
function find_pieces(grid, player)
    local gun  = nil
    local orbs = {}
    local gp   = (player == "red") and RED_GUN or BLUE_GUN
    local op   = (player == "red") and RED_ORB  or BLUE_ORB
    for y = 1, GRID_H do
        for x = 1, GRID_W do
            if grid[y][x] == gp then
                gun = {x=x, y=y}
            elseif grid[y][x] == op then
                table.insert(orbs, {x=x, y=y})
            end
        end
    end
    return gun, orbs
end

function copy_grid(src)
    local g = {}
    for y = 1, GRID_H do
        g[y] = {}
        for x = 1, GRID_W do g[y][x] = src[y][x] end
    end
    return g
end

function is_player_threatened(grid, target)
    local opp     = (target == "red") and "blue" or "red"
    local opp_gun = get_gunslinger_pos(opp, grid)
    if not opp_gun then return false end
    for _, d in ipairs(DIR8) do
        local steps = simulate_lightning(opp_gun.x, opp_gun.y, d[1], d[2], grid)
        for _, s in ipairs(steps) do
            if s.hit_gunslinger == target then return true end
        end
    end
    return false
end

-- Returns an ordered list of actions for the CPU to take this turn.
-- Each action: {type="move", from_x,from_y,to_x,to_y}  or
--              {type="attack", dx, dy}
function cpu_make_decision()
    local cpu = get_cpu_color()
    local opp = (cpu == "red") and "blue" or "red"
    local cpu_gun, cpu_orbs = find_pieces(game.grid, cpu)
    if not cpu_gun then return {} end

    -- 1. Immediate lethal attack from current gun position
    for _, d in ipairs(DIR8) do
        local steps = simulate_lightning(cpu_gun.x, cpu_gun.y, d[1], d[2])
        for _, s in ipairs(steps) do
            if s.hit_gunslinger == opp then
                return {{type="attack", dx=d[1], dy=d[2]}}
            end
        end
    end

    -- 2. Move gun first, then attack for a win
    local gun_moves = calculate_valid_moves(cpu_gun.x, cpu_gun.y)
    for _, m in ipairs(gun_moves) do
        local sim = copy_grid(game.grid)
        local gp  = sim[cpu_gun.y][cpu_gun.x]
        sim[cpu_gun.y][cpu_gun.x] = EMPTY
        sim[m.y][m.x] = gp
        for _, d in ipairs(DIR8) do
            local steps = simulate_lightning(m.x, m.y, d[1], d[2], sim)
            for _, s in ipairs(steps) do
                if s.hit_gunslinger == opp then
                    return {
                        {type="move", from_x=cpu_gun.x, from_y=cpu_gun.y, to_x=m.x, to_y=m.y},
                        {type="attack", dx=d[1], dy=d[2]},
                    }
                end
            end
        end
    end

    -- 3. Evaluate best attack for orb destruction (no self-harm)
    local best_attack    = nil
    local best_atk_score = 0
    for _, d in ipairs(DIR8) do
        local steps = simulate_lightning(cpu_gun.x, cpu_gun.y, d[1], d[2])
        local kills_self           = false
        local dest_opp, dest_own   = 0, 0
        for _, s in ipairs(steps) do
            if s.hit_gunslinger == cpu then kills_self = true end
            for _, o in ipairs(s.new_destroyed_orbs) do
                local p = game.grid[o.y][o.x]
                if is_player_piece(p, opp) then dest_opp = dest_opp + 1
                elseif is_player_piece(p, cpu) then dest_own = dest_own + 1 end
            end
        end
        if not kills_self then
            local sc = dest_opp * 300 - dest_own * 600
            if sc > best_atk_score then
                best_atk_score = sc
                best_attack = {type="attack", dx=d[1], dy=d[2]}
            end
        end
    end

    -- 4. Evaluate best positional move (gun or orb)
    local best_move      = nil
    local best_mv_score  = -math.huge
    local threatened     = is_player_threatened(game.grid, cpu)

    -- Gun positional moves
    for _, m in ipairs(gun_moves) do
        local sim = copy_grid(game.grid)
        local gp  = sim[cpu_gun.y][cpu_gun.x]
        sim[cpu_gun.y][cpu_gun.x] = EMPTY
        sim[m.y][m.x] = gp
        if not is_player_threatened(sim, cpu) then
            local sc = threatened and 5000 or 0
            -- Threat-creation: does this gun position threaten the enemy?
            for _, d in ipairs(DIR8) do
                local steps = simulate_lightning(m.x, m.y, d[1], d[2], sim)
                for _, s in ipairs(steps) do
                    if s.hit_gunslinger == opp then sc = sc + 2500 end
                end
            end
            local dist = math.abs(m.x - 4.5) + math.abs(m.y - 4.5)
            sc = sc + (7 - dist) * 8 + math.random() * 5
            if sc > best_mv_score then
                best_mv_score = sc
                best_move = {type="move", from_x=cpu_gun.x, from_y=cpu_gun.y, to_x=m.x, to_y=m.y}
            end
        end
    end

    -- Orb positional moves
    for _, orb in ipairs(cpu_orbs) do
        local orb_moves = calculate_valid_moves(orb.x, orb.y)
        for _, m in ipairs(orb_moves) do
            local sim = copy_grid(game.grid)
            local op  = sim[orb.y][orb.x]
            sim[orb.y][orb.x] = EMPTY
            sim[m.y][m.x]     = op
            if not is_player_threatened(sim, cpu) then
                local sc = threatened and 5000 or 0
                -- Does this orb position enable a kill?
                for _, d in ipairs(DIR8) do
                    local steps = simulate_lightning(cpu_gun.x, cpu_gun.y, d[1], d[2], sim)
                    for _, s in ipairs(steps) do
                        if s.hit_gunslinger == opp then sc = sc + 3000 end
                    end
                end
                -- Formation bonus: adjacent orb chains
                local adj = get_adjacent_orbs(sim, m.x, m.y, {})
                if     #adj == 1 then sc = sc + 150
                elseif #adj >= 2 then sc = sc + 280 end
                -- Centre control
                local dist = math.abs(m.x - 4.5) + math.abs(m.y - 4.5)
                sc = sc + (7 - dist) * 12 + math.random() * 5
                if sc > best_mv_score then
                    best_mv_score = sc
                    best_move = {type="move", from_x=orb.x, from_y=orb.y, to_x=m.x, to_y=m.y}
                end
            end
        end
    end

    -- Build final action list
    local actions = {}
    if best_move   then table.insert(actions, best_move)   end
    if best_attack then table.insert(actions, best_attack) end
    -- Fallback: at least fire somewhere to avoid a pure pass
    if #actions == 0 then
        table.insert(actions, {type="attack", dx=DIR8[1][1], dy=DIR8[1][2]})
    end
    return actions
end

function execute_cpu_turn()
    local actions = cpu_make_decision()
    if #actions == 0 then end_turn(); return end

    local a1 = actions[1]
    local a2 = actions[2]

    if a1.type == "attack" then
        -- Attack first; no move pending (CPU planned no second action)
        game.cpu_pending_move = nil
        trigger_attack(a1.dx, a1.dy)
        -- Post-anim: anim_attacker == cpu → end_turn() will be called automatically

    elseif a1.type == "move" then
        -- Execute move immediately (no animation needed for movement)
        local piece = game.grid[a1.from_y][a1.from_x]
        game.grid[a1.from_y][a1.from_x] = EMPTY
        game.grid[a1.to_y][a1.to_x]     = piece
        game.has_moved = true

        if a2 and a2.type == "attack" then
            -- Attack after move: trigger animation, end_turn after anim (has_moved=true)
            trigger_attack(a2.dx, a2.dy)
        else
            end_turn()
        end
    end
end

-- ── Drawing Helpers ───────────────────────────────────────────
-- Convert grid cell (1-indexed) to pixel centre
function cell_to_px(x, y)
    return BOARD_OFFSET_X + (x - 0.5) * CELL_SIZE,
           BOARD_OFFSET_Y + (y - 0.5) * CELL_SIZE
end

function draw_orb(cx, cy, color, is_lit, is_destroyed)
    if is_destroyed then
        love.graphics.setColor(1, 0.5, 0.1, 0.8)
        love.graphics.circle("fill", cx, cy, 26)
        love.graphics.setColor(1, 1, 0.2)
        love.graphics.setLineWidth(2)
        love.graphics.circle("line", cx, cy, 28)
        love.graphics.setLineWidth(1)
        return
    end
    if is_lit then
        love.graphics.setColor(1, 1, 0.3, 0.9)
        love.graphics.circle("fill", cx, cy, 24)
    end
    -- Octagon shape
    local r    = 18
    local poly = {}
    for i = 0, 7 do
        local ang = i * (math.pi / 4)
        table.insert(poly, cx + r * math.cos(ang))
        table.insert(poly, cy + r * math.sin(ang))
    end
    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.polygon("fill", poly)
    love.graphics.setColor(1, 1, 1, 0.8)
    love.graphics.setLineWidth(2)
    love.graphics.polygon("line", poly)
    love.graphics.setLineWidth(1)
end

function draw_gunslinger(cx, cy, color)
    local outer_r = 22
    local inner_r = 10
    local pts = {}
    for i = 0, 9 do
        local r   = (i % 2 == 0) and outer_r or inner_r
        local ang = i * (math.pi / 5) - math.pi / 2
        table.insert(pts, cx + r * math.cos(ang))
        table.insert(pts, cy + r * math.sin(ang))
    end
    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.polygon("fill", pts)
    love.graphics.setColor(1, 1, 1)
    love.graphics.setLineWidth(2)
    love.graphics.polygon("line", pts)
    love.graphics.setLineWidth(1)
end

-- Draw the live aim arrow: a snapped directional ray from the Gunslinger to the board edge
function draw_aim_arrow()
    if not (game.aim_gun_x and game.aim_gun_y) then return end

    local mx, my = love.mouse.getPosition()
    local gpx, gpy = cell_to_px(game.aim_gun_x, game.aim_gun_y)
    local adx, ady = snap_direction(mx - gpx, my - gpy)

    -- Walk to board edge in aimed direction
    local steps = 0
    for i = 1, math.max(GRID_W, GRID_H) do
        if in_bounds(game.aim_gun_x + adx * i, game.aim_gun_y + ady * i) then
            steps = i
        else
            break
        end
    end
    steps = math.max(steps, 1)

    local ex, ey = cell_to_px(game.aim_gun_x + adx * steps,
                               game.aim_gun_y + ady * steps)

    -- Glow halo behind the arrow
    love.graphics.setColor(1, 0.9, 0.1, 0.25)
    love.graphics.setLineWidth(14)
    love.graphics.line(gpx, gpy, ex, ey)

    -- Arrow shaft
    love.graphics.setColor(1, 0.95, 0.2, 0.9)
    love.graphics.setLineWidth(3)
    love.graphics.line(gpx, gpy, ex, ey)
    love.graphics.setLineWidth(1)

    -- Arrowhead (filled triangle at tip)
    local len = math.sqrt(adx * adx + ady * ady)
    if len > 0 then
        local ndx =  adx / len
        local ndy =  ady / len
        local px  = -ndy   -- perpendicular
        local py  =  ndx
        local tip = 18
        local hw  = 8
        love.graphics.setColor(1, 1, 0.1)
        love.graphics.polygon("fill",
            ex,                              ey,
            ex - ndx*tip + px*hw,  ey - ndy*tip + py*hw,
            ex - ndx*tip - px*hw,  ey - ndy*tip - py*hw
        )
    end
end

-- ── Main Draw ─────────────────────────────────────────────────
function love.draw()
    love.graphics.clear(0.08, 0.09, 0.12)
    local mx, my = love.mouse.getPosition()

    -- ── Header bar ──────────────────────────────────────────
    love.graphics.setFont(fonts.title)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("FLASH", BOARD_OFFSET_X, 14)

    love.graphics.setFont(fonts.status)
    local sx = BOARD_OFFSET_X + 90
    if game.state == STATE_GAME_OVER then
        local col = (game.winner == "red") and {0.9,0.2,0.2} or {0.2,0.5,1.0}
        love.graphics.setColor(col[1], col[2], col[3])
        local who = (game.winner == "red") and "RED" or "BLUE"
        love.graphics.print(who .. " WINS!  " .. game.win_reason, sx, 18)
    elseif is_cpu_turn() then
        love.graphics.setColor(0.9, 0.7, 0.1)
        love.graphics.print("CPU IS THINKING...", sx, 18)
    elseif game.state == STATE_AIM then
        love.graphics.setColor(1, 1, 0.2)
        love.graphics.print("AIM MODE — Click to fire  ·  Right-click or [ESC] to cancel", sx, 18)
    else
        if game.turn == "red" then
            love.graphics.setColor(0.95, 0.25, 0.25)
            local lbl = (game.game_mode == "pvc" and game.player_color == "red")
                        and "YOUR TURN (RED)" or "Turn: RED"
            love.graphics.print(lbl, sx, 18)
        else
            love.graphics.setColor(0.3, 0.6, 1.0)
            local lbl = (game.game_mode == "pvc" and game.player_color == "blue")
                        and "YOUR TURN (BLUE)" or "Turn: BLUE"
            love.graphics.print(lbl, sx, 18)
        end
    end

    -- Top-right: Mode button [650..770 × 10..40]
    local hm = mx >= 650 and mx <= 770 and my >= 10 and my <= 40
    love.graphics.setColor(hm and {0.3,0.4,0.55} or {0.18,0.22,0.30})
    love.graphics.rectangle("fill", 650, 10, 120, 30, 4, 4)
    love.graphics.setFont(fonts.button)
    love.graphics.setColor(1, 1, 1)
    love.graphics.printf(game.game_mode == "pvp" and "MODE: 2P" or "VS CPU", 650, 18, 120, "center")

    -- Top-right: Colour button [775..895 × 10..40] (pvc only)
    if game.game_mode == "pvc" then
        local hc = mx >= 775 and mx <= 895 and my >= 10 and my <= 40
        if game.player_color == "red" then
            love.graphics.setColor(hc and {0.8,0.25,0.25} or {0.6,0.18,0.18})
        else
            love.graphics.setColor(hc and {0.25,0.50,0.90} or {0.18,0.35,0.70})
        end
        love.graphics.rectangle("fill", 775, 10, 120, 30, 4, 4)
        love.graphics.setColor(1, 1, 1)
        love.graphics.printf(game.player_color == "red" and "YOU: RED" or "YOU: BLUE",
                             775, 18, 120, "center")
    end

    -- ── Board background ────────────────────────────────────
    love.graphics.setColor(0.13, 0.16, 0.21)
    love.graphics.rectangle("fill",
        BOARD_OFFSET_X, BOARD_OFFSET_Y,
        GRID_W * CELL_SIZE, GRID_H * CELL_SIZE, 6, 6)

    -- ── Grid cells ──────────────────────────────────────────
    for r = 1, GRID_H do
        for c = 1, GRID_W do
            local cx = BOARD_OFFSET_X + (c - 1) * CELL_SIZE
            local cy = BOARD_OFFSET_Y + (r - 1) * CELL_SIZE

            -- Checkerboard fill
            love.graphics.setColor((r + c) % 2 == 0 and {0.20,0.23,0.30} or {0.16,0.19,0.25})
            love.graphics.rectangle("fill", cx+2, cy+2, CELL_SIZE-4, CELL_SIZE-4, 4, 4)

            -- Coordinate label (faint)
            love.graphics.setFont(fonts.small)
            love.graphics.setColor(1, 1, 1, 0.18)
            love.graphics.print(c .. "," .. r, cx+4, cy+4)

            -- Selected-piece highlight
            if game.selected_x == c and game.selected_y == r then
                love.graphics.setColor(1, 0.9, 0.2, 0.3)
                love.graphics.rectangle("fill", cx+2, cy+2, CELL_SIZE-4, CELL_SIZE-4, 4, 4)
                love.graphics.setColor(1, 0.9, 0.2)
                love.graphics.setLineWidth(3)
                love.graphics.rectangle("line", cx+2, cy+2, CELL_SIZE-4, CELL_SIZE-4, 4, 4)
                love.graphics.setLineWidth(1)
            end

            -- Valid move dots
            for _, m in ipairs(game.valid_moves) do
                if m.x == c and m.y == r then
                    love.graphics.setColor(0.2, 0.9, 0.4, 0.30)
                    love.graphics.rectangle("fill", cx+4, cy+4, CELL_SIZE-8, CELL_SIZE-8, 4, 4)
                    love.graphics.setColor(0.3, 1.0, 0.5)
                    love.graphics.circle("fill", cx + CELL_SIZE/2, cy + CELL_SIZE/2, 7)
                end
            end
        end
    end

    -- ── Pieces ──────────────────────────────────────────────
    for r = 1, GRID_H do
        for c = 1, GRID_W do
            local piece   = game.grid[r][c]
            local px, py  = cell_to_px(c, r)
            local orb_key = c .. "," .. r
            if piece == BLUE_ORB then
                draw_orb(px, py, {0.10,0.40,1.00}, game.lit_orbs[orb_key], game.destroyed_orbs[orb_key])
            elseif piece == RED_ORB then
                draw_orb(px, py, {0.95,0.15,0.20}, game.lit_orbs[orb_key], game.destroyed_orbs[orb_key])
            elseif piece == BLUE_GUN then
                draw_gunslinger(px, py, {0.20,0.50,1.00})
            elseif piece == RED_GUN then
                draw_gunslinger(px, py, {1.00,0.25,0.25})
            end
        end
    end

    -- ── Lightning segments (during animation) ───────────────
    if #game.active_segments > 0 then
        -- Outer glow
        love.graphics.setColor(1, 1, 0.4, 0.9)
        love.graphics.setLineWidth(6)
        for _, seg in ipairs(game.active_segments) do
            local x1, y1 = cell_to_px(seg.x1, seg.y1)
            local x2, y2 = cell_to_px(seg.x2, seg.y2)
            love.graphics.line(x1, y1, x2, y2)
        end
        -- Inner white core
        love.graphics.setColor(1, 1, 1, 0.95)
        love.graphics.setLineWidth(2)
        for _, seg in ipairs(game.active_segments) do
            local x1, y1 = cell_to_px(seg.x1, seg.y1)
            local x2, y2 = cell_to_px(seg.x2, seg.y2)
            love.graphics.line(x1, y1, x2, y2)
        end
        love.graphics.setLineWidth(1)
    end

    -- ── Aim arrow (aim mode only) ────────────────────────────
    if game.state == STATE_AIM then
        draw_aim_arrow()
    end

    -- ── Right action panel ───────────────────────────────────
    if game.state ~= STATE_GAME_OVER and not is_cpu_turn() then
        love.graphics.setFont(fonts.button)
        love.graphics.setColor(0.75, 0.75, 0.75)
        love.graphics.print("ACTIONS", PANEL_X, 88)

        -- Action status chips
        love.graphics.setFont(fonts.small)
        local mc = game.has_moved    and {0.2,0.9,0.4} or {0.55,0.55,0.55}
        love.graphics.setColor(mc[1], mc[2], mc[3])
        love.graphics.print("MOVE   " .. (game.has_moved    and "✓" or "○"), PANEL_X, 112)
        local ac = game.has_attacked and {0.2,0.9,0.4} or {0.55,0.55,0.55}
        love.graphics.setColor(ac[1], ac[2], ac[3])
        love.graphics.print("ATTACK " .. (game.has_attacked and "✓" or "○"), PANEL_X, 128)

        -- ATTACK button (visible in SELECT state only)
        if game.state == STATE_SELECT and not game.has_attacked then
            local ha = mx >= PANEL_X and mx <= PANEL_X+180 and my >= 148 and my <= 188
            love.graphics.setColor(ha and {0.95,0.75,0.1} or {0.60,0.42,0.05})
            love.graphics.rectangle("fill", PANEL_X, 148, 180, 40, 6, 6)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(fonts.button)
            love.graphics.printf("⚡ ATTACK  [A]", PANEL_X, 161, 180, "center")
        elseif game.state == STATE_AIM then
            love.graphics.setColor(1, 1, 0.2, 0.85)
            love.graphics.setFont(fonts.small)
            love.graphics.printf("Aiming...\nRight-click or [ESC]\nto cancel", PANEL_X, 152, 180, "center")
        end

        -- END TURN button (visible in SELECT state only)
        if game.state == STATE_SELECT then
            local he = mx >= PANEL_X and mx <= PANEL_X+180 and my >= 205 and my <= 245
            love.graphics.setColor(he and {0.40,0.50,0.60} or {0.24,0.30,0.38})
            love.graphics.rectangle("fill", PANEL_X, 205, 180, 40, 6, 6)
            love.graphics.setColor(1, 1, 1)
            love.graphics.setFont(fonts.button)
            love.graphics.printf("END TURN  [Enter]", PANEL_X, 218, 180, "center")
        end

        -- Controls hint
        love.graphics.setFont(fonts.small)
        love.graphics.setColor(0.45, 0.45, 0.45)
        love.graphics.print("[R] Reset\n[A] Aim attack\n[ESC] Cancel / Deselect\n[Enter] End turn",
                            PANEL_X, 262)
    end

    -- ── Game-over overlay ────────────────────────────────────
    if game.state == STATE_GAME_OVER then
        -- Dim background
        love.graphics.setColor(0, 0, 0, 0.65)
        love.graphics.rectangle("fill", 0, 0, 900, 720)

        -- Card
        love.graphics.setColor(0.13, 0.16, 0.24)
        love.graphics.rectangle("fill", 220, 250, 460, 220, 12, 12)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", 220, 250, 460, 220, 12, 12)
        love.graphics.setLineWidth(1)

        love.graphics.setFont(fonts.large)
        if game.game_mode == "pvc" then
            if game.winner == game.player_color then
                love.graphics.setColor(0.2, 0.9, 0.4)
                love.graphics.printf("YOU WIN!", 220, 285, 460, "center")
            else
                love.graphics.setColor(1, 0.3, 0.3)
                love.graphics.printf("CPU WINS!", 220, 285, 460, "center")
            end
        else
            if game.winner == "red" then
                love.graphics.setColor(1, 0.3, 0.3)
                love.graphics.printf("RED WINS!", 220, 285, 460, "center")
            else
                love.graphics.setColor(0.3, 0.6, 1.0)
                love.graphics.printf("BLUE WINS!", 220, 285, 460, "center")
            end
        end

        love.graphics.setFont(fonts.status)
        love.graphics.setColor(0.8, 0.8, 0.8)
        love.graphics.printf(game.win_reason, 220, 335, 460, "center")

        love.graphics.setFont(fonts.button)
        love.graphics.setColor(0.55, 0.55, 0.55)
        love.graphics.printf("Click anywhere to play again", 220, 390, 460, "center")
    end
end
