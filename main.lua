-- Flash - Love2D Game
-- Implementation of Flash 2-player strategy board game

local GRID_W = 7
local GRID_H = 7

-- Palette / Piece constants
local EMPTY = 0
local BLUE_ORB = 1
local BLUE_GUN = 2
local RED_ORB = 3
local RED_GUN = 4

-- Game states
local STATE_SELECT = "SELECT"
local STATE_ANIMATING = "ANIMATING"
local STATE_GAME_OVER = "GAME_OVER"

local game = {
    grid = {},
    turn = "red", -- "red" or "blue"
    state = STATE_SELECT,
    selected_x = nil,
    selected_y = nil,
    valid_moves = {},
    attack_directions = {},
    
    -- Animation state
    anim_steps = {},
    anim_index = 1,
    anim_timer = 0,
    anim_speed = 0.09,
    
    -- Active lightning visuals
    active_segments = {},
    lit_orbs = {},
    destroyed_orbs = {},
    
    -- Game outcome
    winner = nil,
    win_reason = ""
}

local initial_grid = {
    {0, 0, 1, 2, 1, 0, 0},
    {0, 0, 0, 1, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 0, 0, 0, 0},
    {0, 0, 0, 3, 0, 0, 0},
    {0, 0, 3, 4, 3, 0, 0}
}

-- UI layout vars
local CELL_SIZE = 72
local BOARD_OFFSET_X = 200
local BOARD_OFFSET_Y = 100

-- Fonts
local fonts = {}

function love.load()
    love.window.setTitle("FLASH - Lightning Strategy Game")
    fonts.title = love.graphics.newFont(26)
    fonts.status = love.graphics.newFont(18)
    fonts.button = love.graphics.newFont(16)
    fonts.large = love.graphics.newFont(28)
    reset_game()
end

function reset_game()
    game.grid = {}
    for y = 1, GRID_H do
        game.grid[y] = {}
        for x = 1, GRID_W do
            game.grid[y][x] = initial_grid[y][x]
        end
    end
    game.turn = "red"
    game.state = STATE_SELECT
    game.selected_x = nil
    game.selected_y = nil
    game.valid_moves = {}
    game.attack_directions = {}
    game.anim_steps = {}
    game.anim_index = 1
    game.anim_timer = 0
    game.active_segments = {}
    game.lit_orbs = {}
    game.destroyed_orbs = {}
    game.winner = nil
    game.win_reason = ""
end

function is_player_piece(piece, player)
    if player == "red" then
        return piece == RED_GUN or piece == RED_ORB
    else
        return piece == BLUE_GUN or piece == BLUE_ORB
    end
end

function is_gunslinger(piece)
    return piece == RED_GUN or piece == BLUE_GUN
end

function is_orb(piece)
    return piece == RED_ORB or piece == BLUE_ORB
end

function in_bounds(x, y)
    return x >= 1 and x <= GRID_W and y >= 1 and y <= GRID_H
end

-- Calculate valid movement destinations
function calculate_valid_moves(x, y)
    local moves = {}
    local piece = game.grid[y][x]
    if piece == EMPTY then return moves end

    if is_gunslinger(piece) then
        -- Gunslinger moves 1 cell in 8 directions
        for dx = -1, 1 do
            for dy = -1, 1 do
                if not (dx == 0 and dy == 0) then
                    local nx, ny = x + dx, y + dy
                    if in_bounds(nx, ny) and game.grid[ny][nx] == EMPTY then
                        table.insert(moves, {x = nx, y = ny})
                    end
                end
            end
        end
    elseif is_orb(piece) then
        -- Orb moves orthogonally any number of empty squares
        local dirs = {{1, 0}, {-1, 0}, {0, 1}, {0, -1}}
        for _, d in ipairs(dirs) do
            local step = 1
            while true do
                local nx, ny = x + d[1] * step, y + d[2] * step
                if in_bounds(nx, ny) and game.grid[ny][nx] == EMPTY then
                    table.insert(moves, {x = nx, y = ny})
                    step = step + 1
                else
                    break
                end
            end
        end
    end
    return moves
end

function calculate_attack_directions(x, y)
    local piece = game.grid[y][x]
    if is_gunslinger(piece) then
        return {
            {name = "UP", dx = 0, dy = -1},
            {name = "DOWN", dx = 0, dy = 1},
            {name = "LEFT", dx = -1, dy = 0},
            {name = "RIGHT", dx = 1, dy = 0}
        }
    end
    return {}
end

function select_cell(x, y)
    if game.state ~= STATE_SELECT then return end

    local piece = game.grid[y][x]
    if is_player_piece(piece, game.turn) then
        game.selected_x = x
        game.selected_y = y
        game.valid_moves = calculate_valid_moves(x, y)
        game.attack_directions = calculate_attack_directions(x, y)
        return
    end

    -- If a piece was already selected, check if user clicked a valid move
    if game.selected_x and game.selected_y then
        for _, m in ipairs(game.valid_moves) do
            if m.x == x and m.y == y then
                -- Perform move action
                local piece_to_move = game.grid[game.selected_y][game.selected_x]
                game.grid[game.selected_y][game.selected_x] = EMPTY
                game.grid[y][x] = piece_to_move
                
                deselect()
                switch_turn()
                return
            end
        end
    end

    deselect()
end

function deselect()
    game.selected_x = nil
    game.selected_y = nil
    game.valid_moves = {}
    game.attack_directions = {}
end

function switch_turn()
    game.turn = (game.turn == "red") and "blue" or "red"
end

--------------------------------------------------------------------------------
-- LIGHTNING SIMULATION LOGIC
--------------------------------------------------------------------------------
function trigger_attack(dir_dx, dir_dy)
    if not (game.selected_x and game.selected_y) then return end
    
    local gx, gy = game.selected_x, game.selected_y
    deselect()

    -- Generate full lightning animation timeline
    local steps = simulate_lightning(gx, gy, dir_dx, dir_dy)
    game.anim_steps = steps
    game.anim_index = 1
    game.anim_timer = 0
    game.active_segments = {}
    game.lit_orbs = {}
    game.destroyed_orbs = {}
    game.state = STATE_ANIMATING
end

function get_adjacent_orbs(grid, x, y, destroyed_set)
    local adj = {}
    local dirs = {{0, -1}, {0, 1}, {-1, 0}, {1, 0}}
    for _, d in ipairs(dirs) do
        local nx, ny = x + d[1], y + d[2]
        if in_bounds(nx, ny) then
            local key = nx .. "," .. ny
            if is_orb(grid[ny][nx]) and not destroyed_set[key] then
                table.insert(adj, {x = nx, y = ny, dx = d[1], dy = d[2]})
            end
        end
    end
    return adj
end

function simulate_lightning(gx, gy, start_dx, start_dy)
    local steps = {}
    local grid_copy = {}
    for y = 1, GRID_H do
        grid_copy[y] = {}
        for x = 1, GRID_W do
            grid_copy[y][x] = game.grid[y][x]
        end
    end

    local visited_orbs = {}
    local destroyed_orbs = {}
    local gunslinger_hit = nil -- player color that got hit

    -- Initial active heads (rays)
    -- Head: {x, y, dx, dy, prev_x, prev_y}
    local active_heads = {
        {x = gx + start_dx, y = gy + start_dy, dx = start_dx, dy = start_dy, prev_x = gx, prev_y = gy}
    }

    while #active_heads > 0 and not gunslinger_hit do
        local current_step = {
            segments = {},
            new_lit_orbs = {},
            new_destroyed_orbs = {},
            hit_gunslinger = nil
        }
        
        local next_heads = {}

        for _, head in ipairs(active_heads) do
            local x, y = head.x, head.y
            local dx, dy = head.dx, head.dy
            local px, py = head.prev_x, head.prev_y

            -- Add segment for visual drawing
            table.insert(current_step.segments, {x1 = px, y1 = py, x2 = x, y2 = y})

            if not in_bounds(x, y) then
                -- Hit wall, stops
            else
                local piece = grid_copy[y][x]
                if is_gunslinger(piece) then
                    -- Hit gunslinger!
                    current_step.hit_gunslinger = (piece == RED_GUN) and "red" or "blue"
                    gunslinger_hit = current_step.hit_gunslinger
                elseif is_orb(piece) then
                    local orb_key = x .. "," .. y
                    if visited_orbs[orb_key] then
                        -- Already lit in this turn -> destroyed!
                        destroyed_orbs[orb_key] = true
                        table.insert(current_step.new_destroyed_orbs, {x = x, y = y})
                        -- Ray stops
                    else
                        -- Mark orb as lit
                        visited_orbs[orb_key] = true
                        table.insert(current_step.new_lit_orbs, {x = x, y = y})

                        -- Check surrounding adjacent orbs
                        local all_adj = get_adjacent_orbs(grid_copy, x, y, destroyed_orbs)
                        
                        if #all_adj == 0 then
                            -- Lone orb! Destroyed immediately
                            destroyed_orbs[orb_key] = true
                            table.insert(current_step.new_destroyed_orbs, {x = x, y = y})
                            -- Ray stops
                        else
                            -- Find unvisited adjacent orbs
                            local unvisited_adj = {}
                            for _, a in ipairs(all_adj) do
                                local k = a.x .. "," .. a.y
                                if not visited_orbs[k] then
                                    table.insert(unvisited_adj, a)
                                end
                            end

                            if #unvisited_adj > 0 then
                                -- Flow into unvisited adjacent orbs
                                for _, a in ipairs(unvisited_adj) do
                                    table.insert(next_heads, {
                                        x = a.x,
                                        y = a.y,
                                        dx = a.dx,
                                        dy = a.dy,
                                        prev_x = x,
                                        prev_y = y
                                    })
                                end
                            else
                                -- End of orb path -> exit orb continuing in current direction!
                                table.insert(next_heads, {
                                    x = x + dx,
                                    y = y + dy,
                                    dx = dx,
                                    dy = dy,
                                    prev_x = x,
                                    prev_y = y
                                })
                            end
                        end
                    end
                else
                    -- Empty cell -> continue straight in same direction
                    table.insert(next_heads, {
                        x = x + dx,
                        y = y + dy,
                        dx = dx,
                        dy = dy,
                        prev_x = x,
                        prev_y = y
                    })
                end
            end
        end

        table.insert(steps, current_step)
        active_heads = next_heads
    end

    return steps
end

--------------------------------------------------------------------------------
-- LOVE2D UPDATE & DRAW
--------------------------------------------------------------------------------
function love.update(dt)
    if game.state == STATE_ANIMATING then
        game.anim_timer = game.anim_timer + dt
        if game.anim_timer >= game.anim_speed then
            game.anim_timer = 0
            if game.anim_index <= #game.anim_steps then
                local step = game.anim_steps[game.anim_index]
                
                -- Accumulate segments
                for _, seg in ipairs(step.segments) do
                    table.insert(game.active_segments, seg)
                end
                -- Accumulate lit orbs
                for _, o in ipairs(step.new_lit_orbs) do
                    game.lit_orbs[o.x .. "," .. o.y] = true
                end
                -- Accumulate destroyed orbs
                for _, o in ipairs(step.new_destroyed_orbs) do
                    game.destroyed_orbs[o.x .. "," .. o.y] = true
                end

                if step.hit_gunslinger then
                    -- Process win condition
                    local victim = step.hit_gunslinger
                    if victim == "red" then
                        game.winner = "blue"
                        game.win_reason = "Red Gunslinger was destroyed!"
                    else
                        game.winner = "red"
                        game.win_reason = "Blue Gunslinger was destroyed!"
                    end
                end

                game.anim_index = game.anim_index + 1
            else
                -- End of animation
                -- Apply destroyed orbs to game grid
                for k, _ in pairs(game.destroyed_orbs) do
                    local coords = {}
                    for c in string.gmatch(k, "%d+") do
                        table.insert(coords, tonumber(c))
                    end
                    game.grid[coords[2]][coords[1]] = EMPTY
                end

                if game.winner then
                    game.state = STATE_GAME_OVER
                else
                    game.state = STATE_SELECT
                    switch_turn()
                end
            end
        end
    end
end

function love.mousepressed(x, y, button, isTouch)
    if button ~= 1 then return end

    if game.state == STATE_GAME_OVER then
        -- Check click play again button
        if x >= 350 and x <= 550 and y >= 390 and y <= 440 then
            reset_game()
        end
        return
    end

    if game.state ~= STATE_SELECT then return end

    -- Check click on board cells
    local col = math.floor((x - BOARD_OFFSET_X) / CELL_SIZE) + 1
    local row = math.floor((y - BOARD_OFFSET_Y) / CELL_SIZE) + 1

    if in_bounds(col, row) then
        select_cell(col, row)
        return
    end

    -- Check click on attack buttons (if gunslinger is selected)
    if game.selected_x and game.selected_y and #game.attack_directions > 0 then
        local btn_x = BOARD_OFFSET_X + GRID_W * CELL_SIZE + 40
        local start_y = 200
        for i, ad in ipairs(game.attack_directions) do
            local by = start_y + (i - 1) * 55
            if x >= btn_x and x <= btn_x + 140 and y >= by and y <= by + 45 then
                trigger_attack(ad.dx, ad.dy)
                return
            end
        end
    end
end

function love.draw()
    love.graphics.clear(0.08, 0.09, 0.12)

    -- Draw Header & Turn info
    love.graphics.setFont(fonts.title)
    love.graphics.setColor(1, 1, 1)
    love.graphics.print("FLASH", 50, 30)

    love.graphics.setFont(fonts.status)
    if game.state == STATE_GAME_OVER then
        if game.winner == "red" then
            love.graphics.setColor(0.9, 0.2, 0.2)
            love.graphics.print("RED WINS! " .. game.win_reason, 200, 35)
        else
            love.graphics.setColor(0.2, 0.4, 1.0)
            love.graphics.print("BLUE WINS! " .. game.win_reason, 200, 35)
        end
    else
        if game.turn == "red" then
            love.graphics.setColor(0.9, 0.2, 0.2)
            love.graphics.print("Turn: RED PLAYER", 200, 35)
        else
            love.graphics.setColor(0.2, 0.4, 1.0)
            love.graphics.print("Turn: BLUE PLAYER", 200, 35)
        end
    end

    -- Draw Board Background
    love.graphics.setColor(0.15, 0.18, 0.24)
    love.graphics.rectangle("fill", BOARD_OFFSET_X, BOARD_OFFSET_Y, GRID_W * CELL_SIZE, GRID_H * CELL_SIZE, 8, 8)

    -- Draw Grid Cells
    for r = 1, GRID_H do
        for c = 1, GRID_W do
            local cx = BOARD_OFFSET_X + (c - 1) * CELL_SIZE
            local cy = BOARD_OFFSET_Y + (r - 1) * CELL_SIZE

            -- Cell background
            if (r + c) % 2 == 0 then
                love.graphics.setColor(0.2, 0.23, 0.3)
            else
                love.graphics.setColor(0.16, 0.19, 0.25)
            end
            love.graphics.rectangle("fill", cx + 2, cy + 2, CELL_SIZE - 4, CELL_SIZE - 4, 4, 4)

            -- Selected cell highlight
            if game.selected_x == c and game.selected_y == r then
                love.graphics.setColor(1, 0.9, 0.2, 0.4)
                love.graphics.rectangle("fill", cx + 2, cy + 2, CELL_SIZE - 4, CELL_SIZE - 4, 4, 4)
                love.graphics.setColor(1, 0.9, 0.2)
                love.graphics.setLineWidth(3)
                love.graphics.rectangle("line", cx + 2, cy + 2, CELL_SIZE - 4, CELL_SIZE - 4, 4, 4)
                love.graphics.setLineWidth(1)
            end

            -- Valid move highlight
            for _, m in ipairs(game.valid_moves) do
                if m.x == c and m.y == r then
                    love.graphics.setColor(0.2, 0.9, 0.4, 0.35)
                    love.graphics.rectangle("fill", cx + 4, cy + 4, CELL_SIZE - 8, CELL_SIZE - 8, 4, 4)
                    love.graphics.setColor(0.3, 1.0, 0.5)
                    love.graphics.circle("fill", cx + CELL_SIZE / 2, cy + CELL_SIZE / 2, 8)
                end
            end
        end
    end

    -- Draw Pieces
    for r = 1, GRID_H do
        for c = 1, GRID_W do
            local piece = game.grid[r][c]
            local cx = BOARD_OFFSET_X + (c - 1) * CELL_SIZE + CELL_SIZE / 2
            local cy = BOARD_OFFSET_Y + (r - 1) * CELL_SIZE + CELL_SIZE / 2
            local orb_key = c .. "," .. r

            if piece == BLUE_ORB then
                draw_orb(cx, cy, {0.1, 0.4, 1.0}, game.lit_orbs[orb_key], game.destroyed_orbs[orb_key])
            elseif piece == RED_ORB then
                draw_orb(cx, cy, {0.95, 0.15, 0.2}, game.lit_orbs[orb_key], game.destroyed_orbs[orb_key])
            elseif piece == BLUE_GUN then
                draw_gunslinger(cx, cy, {0.2, 0.5, 1.0})
            elseif piece == RED_GUN then
                draw_gunslinger(cx, cy, {1.0, 0.25, 0.25})
            end
        end
    end

    -- Draw Lightning Segments during animation
    if #game.active_segments > 0 then
        love.graphics.setColor(1, 1, 0.4)
        love.graphics.setLineWidth(5)
        for _, seg in ipairs(game.active_segments) do
            local x1 = BOARD_OFFSET_X + (seg.x1 - 0.5) * CELL_SIZE
            local y1 = BOARD_OFFSET_Y + (seg.y1 - 0.5) * CELL_SIZE
            local x2 = BOARD_OFFSET_X + (seg.x2 - 0.5) * CELL_SIZE
            local y2 = BOARD_OFFSET_Y + (seg.y2 - 0.5) * CELL_SIZE
            love.graphics.line(x1, y1, x2, y2)
        end

        -- Core bright white center for lightning
        love.graphics.setColor(1, 1, 1)
        love.graphics.setLineWidth(2)
        for _, seg in ipairs(game.active_segments) do
            local x1 = BOARD_OFFSET_X + (seg.x1 - 0.5) * CELL_SIZE
            local y1 = BOARD_OFFSET_Y + (seg.y1 - 0.5) * CELL_SIZE
            local x2 = BOARD_OFFSET_X + (seg.x2 - 0.5) * CELL_SIZE
            local y2 = BOARD_OFFSET_Y + (seg.y2 - 0.5) * CELL_SIZE
            love.graphics.line(x1, y1, x2, y2)
        end
        love.graphics.setLineWidth(1)
    end

    -- Draw Gunslinger Action Panel (Attack Buttons)
    if game.state == STATE_SELECT and game.selected_x and game.selected_y then
        local piece = game.grid[game.selected_y][game.selected_x]
        if is_gunslinger(piece) and #game.attack_directions > 0 then
            local panel_x = BOARD_OFFSET_X + GRID_W * CELL_SIZE + 40
            love.graphics.setFont(fonts.button)
            love.graphics.setColor(1, 1, 1)
            love.graphics.print("ATTACK ACTIONS:", panel_x, 160)

            local start_y = 200
            for i, ad in ipairs(game.attack_directions) do
                local by = start_y + (i - 1) * 55
                local mx, my = love.mouse.getPosition()
                local hover = (mx >= panel_x and mx <= panel_x + 140 and my >= by and my <= by + 45)

                if hover then
                    love.graphics.setColor(0.9, 0.7, 0.1)
                else
                    love.graphics.setColor(0.7, 0.4, 0.1)
                end
                love.graphics.rectangle("fill", panel_x, by, 140, 45, 6, 6)
                love.graphics.setColor(1, 1, 1)
                love.graphics.printf("SHOOT " .. ad.name, panel_x, by + 12, 140, "center")
            end
        end
    end

    -- Game Over Screen / Play Again Button
    if game.state == STATE_GAME_OVER then
        love.graphics.setColor(0, 0, 0, 0.6)
        love.graphics.rectangle("fill", 0, 0, 900, 700)

        love.graphics.setColor(0.15, 0.18, 0.25)
        love.graphics.rectangle("fill", 250, 220, 400, 260, 12, 12)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setLineWidth(2)
        love.graphics.rectangle("line", 250, 220, 400, 260, 12, 12)
        love.graphics.setLineWidth(1)

        love.graphics.setFont(fonts.large)
        if game.winner == "red" then
            love.graphics.setColor(1, 0.3, 0.3)
            love.graphics.printf("RED WINS!", 250, 260, 400, "center")
        else
            love.graphics.setColor(0.3, 0.6, 1)
            love.graphics.printf("BLUE WINS!", 250, 260, 400, "center")
        end

        love.graphics.setFont(fonts.button)
        love.graphics.setColor(0.8, 0.8, 0.8)
        love.graphics.printf(game.win_reason, 270, 320, 360, "center")

        -- Play Again button
        local mx, my = love.mouse.getPosition()
        local hover = (mx >= 350 and mx <= 550 and my >= 390 and my <= 440)
        if hover then
            love.graphics.setColor(0.2, 0.8, 0.4)
        else
            love.graphics.setColor(0.15, 0.6, 0.3)
        end
        love.graphics.rectangle("fill", 350, 390, 200, 50, 8, 8)
        love.graphics.setColor(1, 1, 1)
        love.graphics.setFont(fonts.status)
        love.graphics.printf("PLAY AGAIN", 350, 403, 200, "center")
    end
end

--------------------------------------------------------------------------------
-- PIECE DRAWING HELPERS (Polygons with basic colors as requested)
--------------------------------------------------------------------------------
function draw_orb(cx, cy, color, is_lit, is_destroyed)
    if is_destroyed then
        -- Draw explosion indicator
        love.graphics.setColor(1, 0.5, 0.1, 0.8)
        love.graphics.circle("fill", cx, cy, 26)
        love.graphics.setColor(1, 1, 0.2)
        love.graphics.circle("line", cx, cy, 28)
        return
    end

    if is_lit then
        love.graphics.setColor(1, 1, 0.3, 0.9)
        love.graphics.circle("fill", cx, cy, 24)
    end

    -- Polygon representation: Octagon orb
    local r = 18
    local poly = {}
    for i = 0, 7 do
        local angle = i * (math.pi / 4)
        table.insert(poly, cx + r * math.cos(angle))
        table.insert(poly, cy + r * math.sin(angle))
    end

    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.polygon("fill", poly)

    love.graphics.setColor(1, 1, 1, 0.8)
    love.graphics.setLineWidth(2)
    love.graphics.polygon("line", poly)
    love.graphics.setLineWidth(1)
end

function draw_gunslinger(cx, cy, color)
    -- Polygon representation: 5-pointed star gunslinger shape
    local outer_r = 22
    local inner_r = 10
    local points = {}
    for i = 0, 9 do
        local r = (i % 2 == 0) and outer_r or inner_r
        local angle = i * (math.pi / 5) - math.pi / 2
        table.insert(points, cx + r * math.cos(angle))
        table.insert(points, cy + r * math.sin(angle))
    end

    love.graphics.setColor(color[1], color[2], color[3])
    love.graphics.polygon("fill", points)

    love.graphics.setColor(1, 1, 1)
    love.graphics.setLineWidth(2)
    love.graphics.polygon("line", points)
    love.graphics.setLineWidth(1)
end
