--[[
    npchlc_traffic - Initialization File
    File: init.lua
]]

-- Size of each quadrant in population grid. Adjust to balance performance and density.
SQUARE_SIZE = 100 -- in map units

-- Global variables for path data (nodes/connections)
-- These tables must be populated by a script that loads traffic map data.
-- Example: load(fileRead("paths.dat"))()
node_x, node_y, node_z, node_conn = {}, {}, {}, {}
conn_n1, conn_n2, conn_nb, conn_maxspeed = {}, {}, {}, {}
conn_lanes = {left = {}, right = {}}
z_offset = {} -- Vertical offset for specific vehicle models

-- Quadrant data (generated from path data)
square_id = {}
square_conns, square_cpos1, square_cpos2 = {}, {}, {}
square_cdens, square_ttden = {}, {}
ped_lane = {} 

-- Initialization message
outputServerLog("[npchlc_traffic] Carregando sistema de tráfego...")

-- Start main traffic generator
-- The addEventHandler ensures script starts only after resource is fully loaded.
addEventHandler("onResourceStart", resourceRoot,
    function()
        -- Checks if npc_hlc resource is running, as it is a critical dependency.
        if getResourceState(getResourceFromName("npc_hlc")) ~= "running" then
            outputServerLog("[npchlc_traffic] ATENÇÃO: Recurso 'npc_hlc' não encontrado ou não está rodando. O tráfego não funcionará corretamente.")
        else
            outputServerLog("[npchlc_traffic] Recurso 'npc_hlc' detectado.")
        end

        -- Checks server_coldata resource (optional)
        if getResourceState(getResourceFromName("server_coldata")) ~= "running" then
            outputServerLog("[npchlc_traffic] AVISO: Recurso 'server_coldata' não encontrado. A verificação de colisão no spawn está desativada.")
        else
            outputServerLog("[npchlc_traffic] Recurso 'server_coldata' detectado. Verificação de colisão no spawn ativada.")
        end
        
        -- Initializes traffic generator
        initTrafficGenerator()
        outputServerLog("[npchlc_traffic] Sistema de tráfego iniciado com sucesso.")
    end
)