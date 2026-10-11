-- ============================================================================
-- Migration: 20261011160000_domino_duo_hardening_and_timeout_block.sql
-- Project: DuoPlay-Online
-- Feature: Dominó Duo — Resolução Autorizada de Bloqueio em Timeouts,
--          Eliminação de Duplicação, Regras Configuráveis (play_immediately,
--          auto_pass, scoring_mode, target_score) e Snapshot Seguro
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Helper Autoritativo: Resolução de Rodada Trancada (Blocked Game / Fecha)
-- Evita qualquer duplicação entre jogadas normais (pass_turn) e timeouts acumulados.
-- Suporta 2, 3 e 4 jogadores (individual e duplas 2v2).
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.resolve_domino_blocked_round(
    p_game_state JSONB
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_config JSONB;
    v_hands JSONB;
    v_turn_order UUID[];
    v_num_players INTEGER;
    v_block_rule TEXT;
    v_team_mode TEXT;
    v_scoring_mode TEXT;
    v_target_score INTEGER;
    v_scores JSONB;
    v_team_scores JSONB;

    v_winner_id UUID := NULL;
    v_winning_team TEXT := NULL;
    v_is_draw BOOLEAN := false;
    v_round_points INTEGER := 0;
    v_is_finished BOOLEAN := false;
    v_finish_reason TEXT := 'blocked';

    v_team_a_sum INTEGER := 0;
    v_team_b_sum INTEGER := 0;
    v_tile_elem JSONB;
    v_other_pid TEXT;
    v_player_sum INTEGER;
    v_player_count INTEGER;
    v_lowest_sum INTEGER := 999999;
    v_lowest_count INTEGER := 999999;
    v_tie_blocked BOOLEAN := false;
    v_new_state JSONB;
BEGIN
    v_config := COALESCE(p_game_state->'config', '{}'::jsonb);
    v_hands := COALESCE(p_game_state->'hands', '{}'::jsonb);
    v_turn_order := ARRAY(SELECT jsonb_array_elements_text(p_game_state->'turnOrder')::uuid);
    v_num_players := array_length(v_turn_order, 1);
    IF v_num_players IS NULL OR v_num_players < 2 THEN
        v_num_players := 2;
    END IF;

    v_block_rule := COALESCE(v_config->>'block_rule', v_config->>'blockRule', 'lowest_pip_count');
    v_team_mode := COALESCE(v_config->>'team_mode', v_config->>'teamMode', 'individual');
    v_scoring_mode := COALESCE(v_config->>'scoring_mode', v_config->>'scoringMode', 'single_round');
    v_target_score := COALESCE((v_config->>'target_score')::integer, (v_config->>'targetScore')::integer, 100);
    v_scores := COALESCE(p_game_state->'scores', '{}'::jsonb);
    v_team_scores := COALESCE(p_game_state->'teamScores', jsonb_build_object('teamA', 0, 'teamB', 0));

    IF v_block_rule = 'draw' THEN
        -- Regra: Empate direto por trancamento
        v_winner_id := NULL;
        v_winning_team := NULL;
        v_is_draw := true;
    ELSIF v_team_mode = 'teams_2v2' AND v_num_players = 4 THEN
        -- Desempate em Duplas 2v2: soma Team A (P1 e P3) vs Team B (P2 e P4)
        v_team_a_sum := 0;
        v_team_b_sum := 0;

        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_hands->v_turn_order[1]::text, '[]'::jsonb)) LOOP
            v_team_a_sum := v_team_a_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
        END LOOP;
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_hands->v_turn_order[3]::text, '[]'::jsonb)) LOOP
            v_team_a_sum := v_team_a_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
        END LOOP;

        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_hands->v_turn_order[2]::text, '[]'::jsonb)) LOOP
            v_team_b_sum := v_team_b_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
        END LOOP;
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(COALESCE(v_hands->v_turn_order[4]::text, '[]'::jsonb)) LOOP
            v_team_b_sum := v_team_b_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
        END LOOP;

        IF v_team_a_sum < v_team_b_sum THEN
            v_winner_id := v_turn_order[1];
            v_winning_team := 'teamA';
            v_is_draw := false;
            v_round_points := v_team_b_sum;
            v_team_scores := v_team_scores || jsonb_build_object('teamA', COALESCE((v_team_scores->>'teamA')::int, 0) + v_round_points);
            v_scores := v_scores || jsonb_build_object(v_winner_id::text, COALESCE((v_scores->>v_winner_id::text)::int, 0) + v_round_points);
        ELSIF v_team_b_sum < v_team_a_sum THEN
            v_winner_id := v_turn_order[2];
            v_winning_team := 'teamB';
            v_is_draw := false;
            v_round_points := v_team_a_sum;
            v_team_scores := v_team_scores || jsonb_build_object('teamB', COALESCE((v_team_scores->>'teamB')::int, 0) + v_round_points);
            v_scores := v_scores || jsonb_build_object(v_winner_id::text, COALESCE((v_scores->>v_winner_id::text)::int, 0) + v_round_points);
        ELSE
            v_winner_id := NULL;
            v_winning_team := NULL;
            v_is_draw := true;
        END IF;

    ELSE
        -- Desempate Individual por menor soma de pontos (lowest_pip_count ou lowest_tile_count)
        FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
            v_player_sum := 0;
            v_player_count := jsonb_array_length(v_hands->v_other_pid);
            FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_other_pid) LOOP
                v_player_sum := v_player_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
            END LOOP;

            IF v_block_rule = 'lowest_tile_count' THEN
                IF v_player_count < v_lowest_count OR (v_player_count = v_lowest_count AND v_player_sum < v_lowest_sum) THEN
                    v_lowest_count := v_player_count;
                    v_lowest_sum := v_player_sum;
                    v_winner_id := v_other_pid::uuid;
                    v_tie_blocked := false;
                ELSIF v_player_count = v_lowest_count AND v_player_sum = v_lowest_sum THEN
                    v_tie_blocked := true;
                END IF;
            ELSE
                -- lowest_pip_count padrão
                IF v_player_sum < v_lowest_sum THEN
                    v_lowest_sum := v_player_sum;
                    v_winner_id := v_other_pid::uuid;
                    v_tie_blocked := false;
                ELSIF v_player_sum = v_lowest_sum THEN
                    v_tie_blocked := true;
                END IF;
            END IF;
        END LOOP;

        IF v_tie_blocked THEN
            v_winner_id := NULL;
            v_is_draw := true;
        ELSE
            v_is_draw := false;
            -- Pontos da rodada: soma das peças de todos os oponentes
            FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
                IF v_other_pid != v_winner_id::text THEN
                    FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_other_pid) LOOP
                        v_round_points := v_round_points + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                    END LOOP;
                END IF;
            END LOOP;
            v_scores := v_scores || jsonb_build_object(v_winner_id::text, COALESCE((v_scores->>v_winner_id::text)::int, 0) + v_round_points);
        END IF;
    END IF;

    -- Avaliação de encerramento da partida
    IF v_scoring_mode = 'single_round' OR v_is_draw THEN
        v_is_finished := true;
    ELSIF v_scoring_mode = 'target_score' THEN
        IF v_winning_team IS NOT NULL THEN
            v_is_finished := (COALESCE((v_team_scores->>v_winning_team)::int, 0) >= v_target_score);
        ELSIF v_winner_id IS NOT NULL THEN
            v_is_finished := (COALESCE((v_scores->>v_winner_id::text)::int, 0) >= v_target_score);
        ELSE
            v_is_finished := false;
        END IF;
    ELSE
        v_is_finished := true;
    END IF;

    v_new_state := p_game_state || jsonb_build_object(
        'consecutivePasses', v_num_players,
        'isBlocked', true,
        'scores', v_scores,
        'teamScores', v_team_scores,
        'isFinished', v_is_finished,
        'winnerId', v_winner_id,
        'winnerTeam', v_winning_team,
        'finishReason', v_finish_reason
    );

    RETURN jsonb_build_object(
        'winner_id', v_winner_id,
        'winning_team', v_winning_team,
        'is_draw', v_is_draw,
        'round_points', v_round_points,
        'scores', v_scores,
        'team_scores', v_team_scores,
        'is_finished', v_is_finished,
        'finish_reason', v_finish_reason,
        'new_state', v_new_state
    );
END;
$$;

REVOKE ALL ON FUNCTION public.resolve_domino_blocked_round(JSONB) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 2. Helper: Início de Nova Rodada no Dominó (Multi-Round para target_score)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_domino_next_round(
    p_game_state JSONB,
    p_round_winner_id UUID DEFAULT NULL
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_config JSONB;
    v_turn_order UUID[];
    v_num_players INTEGER;
    v_max_tile_val INTEGER;
    v_initial_hand_size INTEGER;
    v_raw_tiles JSONB[] := ARRAY[]::JSONB[];
    v_shuffled JSONB[];
    v_hands JSONB := '{}'::jsonb;
    v_hand_tiles JSONB[];
    v_boneyard JSONB[];
    v_player_id UUID;
    v_current_starter UUID;
    i INTEGER;
    j INTEGER;
    k INTEGER;
    v_round_number INTEGER;
BEGIN
    v_config := COALESCE(p_game_state->'config', '{}'::jsonb);
    v_turn_order := ARRAY(SELECT jsonb_array_elements_text(p_game_state->'turnOrder')::uuid);
    v_num_players := array_length(v_turn_order, 1);
    IF v_num_players IS NULL OR v_num_players < 2 THEN
        v_num_players := 2;
    END IF;

    v_max_tile_val := COALESCE((v_config->>'max_tile_value')::INTEGER, (v_config->>'maxTileValue')::INTEGER, 6);
    IF v_max_tile_val < 3 OR v_max_tile_val > 12 THEN
        v_max_tile_val := 6;
    END IF;

    v_initial_hand_size := COALESCE((v_config->>'initial_hand_size')::INTEGER, (v_config->>'initialHandSize')::INTEGER, 7);
    IF (v_initial_hand_size * v_num_players) > (((v_max_tile_val + 1) * (v_max_tile_val + 2)) / 2) THEN
        v_initial_hand_size := (((v_max_tile_val + 1) * (v_max_tile_val + 2)) / 2) / v_num_players;
    END IF;

    -- Gerar conjunto completo de peças
    FOR i IN 0..v_max_tile_val LOOP
        FOR j IN i..v_max_tile_val LOOP
            v_raw_tiles := array_append(v_raw_tiles, jsonb_build_array(i, j));
        END LOOP;
    END LOOP;

    -- Embaralhar
    SELECT array_agg(tile ORDER BY random()) INTO v_shuffled
    FROM unnest(v_raw_tiles) AS tile;

    -- Distribuir novas mãos
    FOREACH v_player_id IN ARRAY v_turn_order LOOP
        v_hand_tiles := ARRAY[]::JSONB[];
        FOR k IN 1..v_initial_hand_size LOOP
            IF array_length(v_shuffled, 1) > 0 THEN
                v_hand_tiles := array_append(v_hand_tiles, v_shuffled[1]);
                v_shuffled := v_shuffled[2:array_length(v_shuffled, 1)];
            END IF;
        END LOOP;
        v_hands := v_hands || jsonb_build_object(v_player_id::text, to_jsonb(v_hand_tiles));
    END LOOP;

    v_boneyard := COALESCE(v_shuffled, ARRAY[]::JSONB[]);

    -- Vencedor da rodada anterior começa a próxima; caso contrário, primeiro da ordem
    v_current_starter := COALESCE(p_round_winner_id, v_turn_order[1]);

    v_round_number := COALESCE((p_game_state->>'roundNumber')::integer, 1) + 1;

    RETURN p_game_state || jsonb_build_object(
        'board', jsonb_build_object('tiles', '[]'::jsonb, 'leftEnd', null, 'rightEnd', null),
        'boneyard', to_jsonb(v_boneyard),
        'hands', v_hands,
        'currentTurnPlayerId', v_current_starter,
        'drawsThisTurn', 0,
        'consecutivePasses', 0,
        'roundNumber', v_round_number,
        'isBlocked', false,
        'isFinished', false,
        'winnerId', null,
        'winnerTeam', null,
        'finishReason', null
    );
END;
$$;

REVOKE ALL ON FUNCTION public.start_domino_next_round(JSONB, UUID) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Inicializador Seguro e Validador Rígido de Configurações
-- (initialize_domino_state_for_players)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.initialize_domino_state_for_players(
    p_player_ids UUID[],
    p_config JSONB DEFAULT '{}'::jsonb
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_max_tile_val INTEGER;
    v_initial_hand_size INTEGER;
    v_start_rule TEXT;
    v_team_mode TEXT;
    v_draw_rule TEXT;
    v_scoring_mode TEXT;
    v_target_score INTEGER;
    v_raw_tiles JSONB[] := ARRAY[]::JSONB[];
    v_shuffled JSONB[];
    v_hands JSONB := '{}'::jsonb;
    v_hand_tiles JSONB[];
    v_boneyard JSONB[];
    v_player_id UUID;
    v_current_starter UUID;
    v_highest_double INTEGER := -1;
    v_highest_pip_sum INTEGER := -1;
    v_tile JSONB;
    v_t1 INTEGER;
    v_t2 INTEGER;
    i INTEGER;
    j INTEGER;
    k INTEGER;
    v_num_players INTEGER;
    v_scores JSONB := '{}'::jsonb;
    v_total_tiles INTEGER;
BEGIN
    v_num_players := array_length(p_player_ids, 1);
    IF v_num_players IS NULL OR v_num_players < 2 OR v_num_players > 4 THEN
        RAISE EXCEPTION 'INVALID_PLAYER_COUNT: Dominó Duo suporta entre 2 e 4 jogadores.' USING ERRCODE = 'P0012';
    END IF;

    -- Parâmetros da configuração
    v_max_tile_val := COALESCE((p_config->>'max_tile_value')::INTEGER, (p_config->>'maxTileValue')::INTEGER, 6);
    IF v_max_tile_val < 3 OR v_max_tile_val > 12 THEN
        RAISE EXCEPTION 'INVALID_MAX_TILE_VALUE: O valor máximo da peça deve estar entre 3 e 12.' USING ERRCODE = 'P0085';
    END IF;

    v_total_tiles := ((v_max_tile_val + 1) * (v_max_tile_val + 2)) / 2;

    v_initial_hand_size := COALESCE((p_config->>'initial_hand_size')::INTEGER, (p_config->>'initialHandSize')::INTEGER, 7);
    IF v_initial_hand_size < 3 THEN
        v_initial_hand_size := 3;
    END IF;
    IF (v_initial_hand_size * v_num_players) > v_total_tiles THEN
        v_initial_hand_size := v_total_tiles / v_num_players;
    END IF;

    v_start_rule := COALESCE(p_config->>'start_rule', p_config->>'startRule', 'highest_double');
    IF v_start_rule NOT IN ('highest_double', 'random', 'highest_tile', 'host') THEN
        v_start_rule := 'highest_double';
    END IF;

    v_team_mode := COALESCE(p_config->>'team_mode', p_config->>'teamMode', 'individual');
    IF v_team_mode = 'teams_2v2' AND v_num_players != 4 THEN
        RAISE EXCEPTION 'INVALID_TEAM_MODE: O modo de duplas 2v2 exige exatamente 4 jogadores.' USING ERRCODE = 'P0084';
    END IF;
    IF v_team_mode NOT IN ('individual', 'teams_2v2') THEN
        v_team_mode := 'individual';
    END IF;

    v_draw_rule := COALESCE(p_config->>'draw_rule', p_config->>'drawRule', 'open');
    IF v_draw_rule NOT IN ('open', 'one_tile', 'custom_limit', 'no_draw', 'block') THEN
        v_draw_rule := 'open';
    END IF;

    v_scoring_mode := COALESCE(p_config->>'scoring_mode', p_config->>'scoringMode', 'single_round');
    IF v_scoring_mode NOT IN ('single_round', 'target_score') THEN
        v_scoring_mode := 'single_round';
    END IF;

    v_target_score := COALESCE((p_config->>'target_score')::INTEGER, (p_config->>'targetScore')::INTEGER, 100);
    IF v_target_score < 10 THEN
        v_target_score := 10;
    END IF;

    -- 1. Gerar matematicamente todas as peças [i, j] com 0 <= i <= j <= max
    FOR i IN 0..v_max_tile_val LOOP
        FOR j IN i..v_max_tile_val LOOP
            v_raw_tiles := array_append(v_raw_tiles, jsonb_build_array(i, j));
        END LOOP;
    END LOOP;

    -- 2. Embaralhar aleatoriamente
    SELECT array_agg(tile ORDER BY random()) INTO v_shuffled
    FROM unnest(v_raw_tiles) AS tile;

    -- 3. Distribuir peças para cada jogador
    FOREACH v_player_id IN ARRAY p_player_ids LOOP
        v_hand_tiles := ARRAY[]::JSONB[];
        FOR k IN 1..v_initial_hand_size LOOP
            IF array_length(v_shuffled, 1) > 0 THEN
                v_hand_tiles := array_append(v_hand_tiles, v_shuffled[1]);
                v_shuffled := v_shuffled[2:array_length(v_shuffled, 1)];
            END IF;
        END LOOP;
        v_hands := v_hands || jsonb_build_object(v_player_id::text, to_jsonb(v_hand_tiles));
        v_scores := v_scores || jsonb_build_object(v_player_id::text, 0);
    END LOOP;

    -- Peças restantes formam o monte secreto
    v_boneyard := COALESCE(v_shuffled, ARRAY[]::JSONB[]);

    -- 4. Determinar jogador inicial
    v_current_starter := p_player_ids[1];

    IF v_start_rule = 'random' THEN
        v_current_starter := p_player_ids[1 + floor(random() * v_num_players)::integer];
    ELSIF v_start_rule = 'highest_double' THEN
        FOREACH v_player_id IN ARRAY p_player_ids LOOP
            FOR v_tile IN SELECT * FROM jsonb_array_elements(v_hands->v_player_id::text) LOOP
                v_t1 := (v_tile->>0)::integer;
                v_t2 := (v_tile->>1)::integer;
                IF v_t1 = v_t2 AND v_t1 > v_highest_double THEN
                    v_highest_double := v_t1;
                    v_current_starter := v_player_id;
                END IF;
            END LOOP;
        END LOOP;

        IF v_highest_double = -1 THEN
            FOREACH v_player_id IN ARRAY p_player_ids LOOP
                FOR v_tile IN SELECT * FROM jsonb_array_elements(v_hands->v_player_id::text) LOOP
                    v_t1 := (v_tile->>0)::integer;
                    v_t2 := (v_tile->>1)::integer;
                    IF (v_t1 + v_t2) > v_highest_pip_sum THEN
                        v_highest_pip_sum := v_t1 + v_t2;
                        v_current_starter := v_player_id;
                    END IF;
                END LOOP;
            END LOOP;
        END IF;
    ELSIF v_start_rule = 'highest_tile' THEN
        FOREACH v_player_id IN ARRAY p_player_ids LOOP
            FOR v_tile IN SELECT * FROM jsonb_array_elements(v_hands->v_player_id::text) LOOP
                v_t1 := (v_tile->>0)::integer;
                v_t2 := (v_tile->>1)::integer;
                IF (v_t1 + v_t2) > v_highest_pip_sum THEN
                    v_highest_pip_sum := v_t1 + v_t2;
                    v_current_starter := v_player_id;
                END IF;
            END LOOP;
        END LOOP;
    ELSIF v_start_rule = 'host' THEN
        v_current_starter := p_player_ids[1];
    END IF;

    RETURN jsonb_build_object(
        'config', p_config || jsonb_build_object(
            'playerCount', v_num_players,
            'maxTileValue', v_max_tile_val,
            'initialHandSize', v_initial_hand_size,
            'startRule', v_start_rule,
            'teamMode', v_team_mode,
            'drawRule', v_draw_rule,
            'scoringMode', v_scoring_mode,
            'targetScore', v_target_score
        ),
        'board', jsonb_build_object(
            'tiles', '[]'::jsonb,
            'leftEnd', null,
            'rightEnd', null
        ),
        'boneyard', to_jsonb(v_boneyard),
        'hands', v_hands,
        'turnOrder', to_jsonb(p_player_ids),
        'currentTurnPlayerId', v_current_starter,
        'drawsThisTurn', 0,
        'consecutivePasses', 0,
        'scores', v_scores,
        'teamScores', jsonb_build_object('teamA', 0, 'teamB', 0),
        'roundNumber', 1,
        'isBlocked', false,
        'isFinished', false,
        'winnerId', null,
        'winnerTeam', null,
        'finishReason', null
    );
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_domino_state_for_players(UUID[], JSONB) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 4. Validador Server-Side de Ações do Dominó (validate_domino_action)
-- Implementa de verdade play_immediately, auto_pass, scoring_mode e target_score
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.validate_domino_action(
    p_match_id UUID,
    p_player_id UUID,
    p_action_type VARCHAR(50),
    p_payload JSONB,
    p_current_state JSONB,
    p_turn_number INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_config JSONB;
    v_board JSONB;
    v_tiles JSONB;
    v_left_end INTEGER;
    v_right_end INTEGER;
    v_boneyard JSONB;
    v_hands JSONB;
    v_player_hand JSONB;
    v_new_player_hand JSONB[];
    v_turn_order UUID[];
    v_current_turn_player_id UUID;
    v_draws_this_turn INTEGER;
    v_consecutive_passes INTEGER;
    v_draw_rule TEXT;
    v_play_immediately BOOLEAN;
    v_auto_pass BOOLEAN;
    v_max_draws INTEGER;
    v_scoring_mode TEXT;
    v_target_score INTEGER;
    v_team_mode TEXT;
    v_block_rule TEXT;

    -- Variáveis de jogada
    v_play_tile JSONB;
    v_t1 INTEGER;
    v_t2 INTEGER;
    v_side TEXT;
    v_has_tile BOOLEAN := false;
    v_tile_elem JSONB;
    v_new_left_end INTEGER;
    v_new_right_end INTEGER;
    v_new_placed_tile JSONB;
    v_new_board_tiles JSONB;
    v_drawn_tile JSONB;
    v_drawn_playable BOOLEAN := false;
    v_boneyard_len INTEGER;
    v_rem_hand_len INTEGER;
    v_next_player_id UUID;
    v_next_idx INTEGER;
    v_num_players INTEGER;

    -- Finalização e pontuação
    v_is_finished BOOLEAN := false;
    v_winner_id UUID := null;
    v_is_draw BOOLEAN := false;
    v_finish_reason TEXT := null;
    v_round_points INTEGER := 0;
    v_other_pid TEXT;
    v_other_hand JSONB;
    v_scores JSONB;
    v_team_scores JSONB;
    v_new_state JSONB;
    v_valid_moves_exist BOOLEAN := false;
    v_winning_team TEXT := null;
    v_blocked_res JSONB;
BEGIN
    v_config := COALESCE(p_current_state->'config', '{}'::jsonb);
    v_board := COALESCE(p_current_state->'board', jsonb_build_object('tiles', '[]'::jsonb, 'leftEnd', null, 'rightEnd', null));
    v_tiles := COALESCE(v_board->'tiles', '[]'::jsonb);
    v_left_end := (v_board->>'leftEnd')::integer;
    v_right_end := (v_board->>'rightEnd')::integer;
    v_boneyard := COALESCE(p_current_state->'boneyard', '[]'::jsonb);
    v_hands := COALESCE(p_current_state->'hands', '{}'::jsonb);
    v_turn_order := ARRAY(SELECT jsonb_array_elements_text(p_current_state->'turnOrder')::uuid);
    v_current_turn_player_id := (p_current_state->>'currentTurnPlayerId')::uuid;
    v_draws_this_turn := COALESCE((p_current_state->>'drawsThisTurn')::integer, 0);
    v_consecutive_passes := COALESCE((p_current_state->>'consecutivePasses')::integer, 0);
    v_scores := COALESCE(p_current_state->'scores', '{}'::jsonb);
    v_team_scores := COALESCE(p_current_state->'teamScores', jsonb_build_object('teamA', 0, 'teamB', 0));

    v_draw_rule := COALESCE(v_config->>'draw_rule', v_config->>'drawRule', 'open');
    v_play_immediately := COALESCE((v_config->>'play_immediately')::boolean, (v_config->>'playImmediately')::boolean, true);
    v_auto_pass := COALESCE((v_config->>'auto_pass')::boolean, (v_config->>'autoPass')::boolean, true);
    v_max_draws := COALESCE((v_config->>'max_draws_per_turn')::integer, (v_config->>'maxDrawsPerTurn')::integer, 99);
    v_scoring_mode := COALESCE(v_config->>'scoring_mode', v_config->>'scoringMode', 'single_round');
    v_target_score := COALESCE((v_config->>'target_score')::integer, (v_config->>'targetScore')::integer, 100);
    v_team_mode := COALESCE(v_config->>'team_mode', v_config->>'teamMode', 'individual');
    v_block_rule := COALESCE(v_config->>'block_rule', v_config->>'blockRule', 'lowest_pip_count');

    v_num_players := array_length(v_turn_order, 1);
    IF v_num_players IS NULL OR v_num_players < 2 THEN
        v_num_players := 2;
    END IF;

    -- 1. Validar se a partida não foi finalizada anteriormente
    IF COALESCE((p_current_state->>'isFinished')::boolean, false) = true THEN
        RAISE EXCEPTION 'MATCH_ALREADY_FINISHED: Esta partida já foi finalizada.' USING ERRCODE = 'P0070';
    END IF;

    -- 2. Validar se é o turno do jogador
    IF v_current_turn_player_id != p_player_id THEN
        RAISE EXCEPTION 'NOT_YOUR_TURN: Não é o seu turno para realizar esta ação no Dominó.' USING ERRCODE = 'P0071';
    END IF;

    v_player_hand := COALESCE(v_hands->(p_player_id::text), '[]'::jsonb);

    -- Determinar se o jogador possui jogadas válidas na mão atual
    v_valid_moves_exist := false;
    IF v_left_end IS NULL OR v_right_end IS NULL OR jsonb_array_length(v_tiles) = 0 THEN
        v_valid_moves_exist := (jsonb_array_length(v_player_hand) > 0);
    ELSE
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
            v_t1 := (v_tile_elem->>0)::integer;
            v_t2 := (v_tile_elem->>1)::integer;
            IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                v_valid_moves_exist := true;
                EXIT;
            END IF;
        END LOOP;
    END IF;

    -- Calcular próximo jogador cíclico
    v_next_player_id := v_turn_order[1];
    FOR i IN 1..v_num_players LOOP
        IF v_turn_order[i] = p_player_id THEN
            v_next_idx := (i % v_num_players) + 1;
            v_next_player_id := v_turn_order[v_next_idx];
            EXIT;
        END IF;
    END LOOP;

    -- ========================================================================
    -- AÇÃO 1: play_tile (Colocar Peça no Tabuleiro)
    -- ========================================================================
    IF p_action_type = 'play_tile' THEN
        v_play_tile := p_payload->'tile';
        v_side := COALESCE(p_payload->>'side', 'right');

        IF v_play_tile IS NULL OR jsonb_array_length(v_play_tile) != 2 THEN
            RAISE EXCEPTION 'INVALID_TILE_PAYLOAD: Peça informada é inválida.' USING ERRCODE = 'P0072';
        END IF;

        v_t1 := (v_play_tile->>0)::integer;
        v_t2 := (v_play_tile->>1)::integer;

        -- Validar posse da peça
        v_has_tile := false;
        v_new_player_hand := ARRAY[]::JSONB[];
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
            IF NOT v_has_tile AND (
                ((v_tile_elem->>0)::int = v_t1 AND (v_tile_elem->>1)::int = v_t2) OR
                ((v_tile_elem->>0)::int = v_t2 AND (v_tile_elem->>1)::int = v_t1)
            ) THEN
                v_has_tile := true;
            ELSE
                v_new_player_hand := array_append(v_new_player_hand, v_tile_elem);
            END IF;
        END LOOP;

        IF NOT v_has_tile THEN
            RAISE EXCEPTION 'TILE_NOT_IN_HAND: Você não possui esta peça na sua mão.' USING ERRCODE = 'P0073';
        END IF;

        -- Validar posicionamento no tabuleiro
        IF v_left_end IS NULL OR v_right_end IS NULL OR jsonb_array_length(v_tiles) = 0 THEN
            v_new_left_end := v_t1;
            v_new_right_end := v_t2;
            v_new_placed_tile := jsonb_build_object(
                'id', v_t1 || '-' || v_t2 || '-0',
                'tile', jsonb_build_array(v_t1, v_t2),
                'exposedValueLeft', v_t1,
                'exposedValueRight', v_t2,
                'placedBy', p_player_id::text,
                'side', 'initial',
                'sequenceIndex', 0
            );
            v_new_board_tiles := jsonb_build_array(v_new_placed_tile);
        ELSE
            IF v_side = 'left' THEN
                IF v_t2 = v_left_end THEN
                    v_new_left_end := v_t1;
                ELSIF v_t1 = v_left_end THEN
                    v_new_left_end := v_t2;
                ELSE
                    RAISE EXCEPTION 'CANNOT_CONNECT_LEFT: A peça [%, %] não conecta na ponta esquerda (%).', v_t1, v_t2, v_left_end USING ERRCODE = 'P0074';
                END IF;
                v_new_right_end := v_right_end;

                v_new_placed_tile := jsonb_build_object(
                    'id', v_t1 || '-' || v_t2 || '-' || jsonb_array_length(v_tiles),
                    'tile', jsonb_build_array(v_t1, v_t2),
                    'exposedValueLeft', v_new_left_end,
                    'exposedValueRight', v_left_end,
                    'placedBy', p_player_id::text,
                    'side', 'left',
                    'sequenceIndex', jsonb_array_length(v_tiles)
                );
                v_new_board_tiles := jsonb_build_array(v_new_placed_tile) || v_tiles;

            ELSIF v_side = 'right' THEN
                IF v_t1 = v_right_end THEN
                    v_new_right_end := v_t2;
                ELSIF v_t2 = v_right_end THEN
                    v_new_right_end := v_t1;
                ELSE
                    RAISE EXCEPTION 'CANNOT_CONNECT_RIGHT: A peça [%, %] não conecta na ponta direita (%).', v_t1, v_t2, v_right_end USING ERRCODE = 'P0075';
                END IF;
                v_new_left_end := v_left_end;

                v_new_placed_tile := jsonb_build_object(
                    'id', v_t1 || '-' || v_t2 || '-' || jsonb_array_length(v_tiles),
                    'tile', jsonb_build_array(v_t1, v_t2),
                    'exposedValueLeft', v_right_end,
                    'exposedValueRight', v_new_right_end,
                    'placedBy', p_player_id::text,
                    'side', 'right',
                    'sequenceIndex', jsonb_array_length(v_tiles)
                );
                v_new_board_tiles := v_tiles || jsonb_build_array(v_new_placed_tile);
            ELSE
                RAISE EXCEPTION 'INVALID_BOARD_SIDE: O lado deve ser left ou right.' USING ERRCODE = 'P0074';
            END IF;
        END IF;

        -- Atualizar mão do jogador
        v_hands := v_hands || jsonb_build_object(p_player_id::text, to_jsonb(v_new_player_hand));
        v_rem_hand_len := array_length(v_new_player_hand, 1);
        IF v_rem_hand_len IS NULL THEN
            v_rem_hand_len := 0;
        END IF;

        -- Condição de Batida (Domino / Mão esgotada)
        IF v_rem_hand_len = 0 THEN
            v_winner_id := p_player_id;
            v_finish_reason := 'domino';

            -- Calcular pontos da rodada: soma das peças de todos os oponentes
            FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
                IF v_other_pid != p_player_id::text THEN
                    v_other_hand := v_hands->v_other_pid;
                    FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_other_hand) LOOP
                        v_round_points := v_round_points + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                    END LOOP;
                END IF;
            END LOOP;

            v_scores := v_scores || jsonb_build_object(p_player_id::text, COALESCE((v_scores->>p_player_id::text)::int, 0) + v_round_points);

            IF v_team_mode = 'teams_2v2' AND v_num_players = 4 THEN
                IF p_player_id = v_turn_order[1] OR p_player_id = v_turn_order[3] THEN
                    v_team_scores := v_team_scores || jsonb_build_object('teamA', COALESCE((v_team_scores->>'teamA')::int, 0) + v_round_points);
                    v_winning_team := 'teamA';
                ELSE
                    v_team_scores := v_team_scores || jsonb_build_object('teamB', COALESCE((v_team_scores->>'teamB')::int, 0) + v_round_points);
                    v_winning_team := 'teamB';
                END IF;
            END IF;

            -- Avaliação de encerramento pelo scoring_mode
            IF v_scoring_mode = 'single_round' THEN
                v_is_finished := true;
            ELSIF v_scoring_mode = 'target_score' THEN
                IF v_winning_team IS NOT NULL THEN
                    v_is_finished := (COALESCE((v_team_scores->>v_winning_team)::int, 0) >= v_target_score);
                ELSE
                    v_is_finished := (COALESCE((v_scores->>p_player_id::text)::int, 0) >= v_target_score);
                END IF;
            ELSE
                v_is_finished := true;
            END IF;
        END IF;

        v_new_state := p_current_state || jsonb_build_object(
            'board', jsonb_build_object(
                'tiles', v_new_board_tiles,
                'leftEnd', v_new_left_end,
                'rightEnd', v_new_right_end
            ),
            'hands', v_hands,
            'currentTurnPlayerId', CASE WHEN v_is_finished THEN v_current_turn_player_id ELSE v_next_player_id END,
            'drawsThisTurn', 0,
            'consecutivePasses', 0,
            'scores', v_scores,
            'teamScores', v_team_scores,
            'isFinished', v_is_finished,
            'winnerId', v_winner_id,
            'winnerTeam', v_winning_team,
            'finishReason', v_finish_reason,
            'lastAction', jsonb_build_object(
                'type', 'play',
                'playerId', p_player_id,
                'tile', jsonb_build_array(v_t1, v_t2),
                'side', v_side
            )
        );

        -- Se bateu a rodada em target_score mas ainda não atingiu a meta, inicia nova rodada
        IF v_rem_hand_len = 0 AND NOT v_is_finished AND v_scoring_mode = 'target_score' THEN
            v_new_state := public.start_domino_next_round(v_new_state, v_winner_id);
            v_next_player_id := (v_new_state->>'currentTurnPlayerId')::uuid;
        END IF;

        -- Atualizar pontuação no match_players
        UPDATE public.match_players
        SET score = COALESCE((v_scores->>user_id::text)::int, 0),
            is_winner = (user_id = v_winner_id)
        WHERE match_id = p_match_id;

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', CASE WHEN v_is_finished THEN NULL ELSE v_next_player_id END,
            'winner_id', v_winner_id,
            'is_draw', false,
            'is_finished', v_is_finished
        );

    -- ========================================================================
    -- AÇÃO 2: draw_tile (Comprar Peça do Monte)
    -- ========================================================================
    ELSIF p_action_type = 'draw_tile' THEN
        v_boneyard_len := jsonb_array_length(v_boneyard);
        IF v_boneyard_len = 0 THEN
            RAISE EXCEPTION 'BONEYARD_EMPTY: O monte de compra está vazio.' USING ERRCODE = 'P0076';
        END IF;

        -- Regra sem compra (no_draw ou block)
        IF v_draw_rule = 'no_draw' OR v_draw_rule = 'block' THEN
            RAISE EXCEPTION 'DRAW_NOT_ALLOWED: A regra da partida não permite comprar peças.' USING ERRCODE = 'P0077';
        END IF;

        -- Limite de compras por turno
        IF v_draw_rule = 'one_tile' AND v_draws_this_turn >= 1 THEN
            RAISE EXCEPTION 'DRAW_LIMIT_REACHED: Limite de 1 compra por turno atingido.' USING ERRCODE = 'P0078';
        END IF;

        IF v_draw_rule = 'custom_limit' AND v_draws_this_turn >= v_max_draws THEN
            RAISE EXCEPTION 'DRAW_LIMIT_REACHED: Limite máximo de compras por turno atingido.' USING ERRCODE = 'P0078';
        END IF;

        -- Permitir compra APENAS quando o jogador NÃO possui jogadas válidas na mão
        IF v_valid_moves_exist THEN
            RAISE EXCEPTION 'CANNOT_DRAW_WITH_VALID_MOVES: Você já possui peças jogáveis na mão e não pode comprar.' USING ERRCODE = 'P0082';
        END IF;

        -- Retira primeira peça do monte
        v_drawn_tile := v_boneyard->0;
        v_boneyard := v_boneyard - 0;

        -- Adiciona à mão do jogador
        v_player_hand := v_player_hand || jsonb_build_array(v_drawn_tile);
        v_hands := v_hands || jsonb_build_object(p_player_id::text, v_player_hand);

        -- Verifica se a peça comprada conecta no tabuleiro
        v_drawn_playable := false;
        IF v_left_end IS NULL OR v_right_end IS NULL THEN
            v_drawn_playable := true;
        ELSE
            IF (v_drawn_tile->>0)::int = v_left_end OR (v_drawn_tile->>1)::int = v_left_end OR
               (v_drawn_tile->>0)::int = v_right_end OR (v_drawn_tile->>1)::int = v_right_end THEN
                v_drawn_playable := true;
            END IF;
        END IF;

        -- LÓGICA DE TRANSIÇÃO: play_immediately e auto_pass
        IF NOT v_play_immediately THEN
            -- Regra: perde a vez imediatamente após comprar
            v_next_player_id := v_turn_order[v_next_idx];
            v_draws_this_turn := 0;
            v_consecutive_passes := 0;
        ELSIF v_drawn_playable THEN
            -- Permanece no turno do jogador para jogar a peça recém-adquirida
            v_next_player_id := v_current_turn_player_id;
            v_draws_this_turn := v_draws_this_turn + 1;
        ELSIF v_auto_pass AND NOT v_drawn_playable AND (
            jsonb_array_length(v_boneyard) = 0 OR
            (v_draw_rule = 'one_tile' AND (v_draws_this_turn + 1) >= 1) OR
            (v_draw_rule = 'custom_limit' AND (v_draws_this_turn + 1) >= v_max_draws)
        ) THEN
            -- Não pode jogar e não pode mais comprar, com auto_pass ativado: passa a vez automaticamente
            v_next_player_id := v_turn_order[v_next_idx];
            v_draws_this_turn := 0;
            v_consecutive_passes := v_consecutive_passes + 1;
        ELSE
            -- Permanece no turno para continuar comprando (se permitido) ou passar manualmente
            v_next_player_id := v_current_turn_player_id;
            v_draws_this_turn := v_draws_this_turn + 1;
        END IF;

        v_new_state := p_current_state || jsonb_build_object(
            'boneyard', v_boneyard,
            'hands', v_hands,
            'currentTurnPlayerId', v_next_player_id,
            'drawsThisTurn', v_draws_this_turn,
            'consecutivePasses', v_consecutive_passes,
            'lastAction', jsonb_build_object(
                'type', 'draw',
                'playerId', p_player_id
            )
        );

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', v_next_player_id,
            'winner_id', NULL,
            'is_draw', false,
            'is_finished', false
        );

    -- ========================================================================
    -- AÇÃO 3: pass_turn (Passar a Vez)
    -- ========================================================================
    ELSIF p_action_type = 'pass_turn' THEN
        -- 1. Não permitir passar se possuir jogadas válidas na mão
        IF v_valid_moves_exist THEN
            RAISE EXCEPTION 'CANNOT_PASS_WITH_VALID_MOVES: Você possui peças jogáveis e não pode passar a vez.' USING ERRCODE = 'P0079';
        END IF;

        -- 2. Não permitir passar se ainda puder/dever comprar no monte
        v_boneyard_len := jsonb_array_length(v_boneyard);
        IF v_boneyard_len > 0 AND v_draw_rule = 'open' THEN
            RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar peças do monte antes de passar a vez.' USING ERRCODE = 'P0083';
        END IF;

        IF v_boneyard_len > 0 AND v_draw_rule = 'one_tile' AND v_draws_this_turn = 0 THEN
            RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar uma peça do monte antes de passar a vez.' USING ERRCODE = 'P0083';
        END IF;

        IF v_boneyard_len > 0 AND v_draw_rule = 'custom_limit' AND v_draws_this_turn < v_max_draws THEN
            RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar peças do monte até o limite antes de passar.' USING ERRCODE = 'P0083';
        END IF;

        -- Passagem válida: incrementa passes consecutivos
        v_consecutive_passes := v_consecutive_passes + 1;

        -- 3. Tratar encerramento por trancamento (blocked game / fecha)
        IF v_consecutive_passes >= v_num_players THEN
            v_blocked_res := public.resolve_domino_blocked_round(
                p_current_state || jsonb_build_object(
                    'hands', v_hands,
                    'consecutivePasses', v_consecutive_passes
                )
            );

            v_winner_id := (v_blocked_res->>'winner_id')::uuid;
            v_winning_team := v_blocked_res->>'winning_team';
            v_is_draw := (v_blocked_res->>'is_draw')::boolean;
            v_is_finished := (v_blocked_res->>'is_finished')::boolean;
            v_finish_reason := v_blocked_res->>'finish_reason';
            v_scores := v_blocked_res->'scores';
            v_team_scores := v_blocked_res->'team_scores';
            v_new_state := v_blocked_res->'new_state';

            -- Se trancou em target_score mas não encerrou, inicia nova rodada
            IF NOT v_is_finished AND v_scoring_mode = 'target_score' THEN
                v_new_state := public.start_domino_next_round(v_new_state, v_winner_id);
                v_next_player_id := (v_new_state->>'currentTurnPlayerId')::uuid;
            END IF;

        ELSE
            v_new_state := p_current_state || jsonb_build_object(
                'currentTurnPlayerId', v_next_player_id,
                'drawsThisTurn', 0,
                'consecutivePasses', v_consecutive_passes,
                'isBlocked', false,
                'scores', v_scores,
                'teamScores', v_team_scores,
                'isFinished', false,
                'winnerId', NULL,
                'winnerTeam', NULL,
                'finishReason', NULL,
                'lastAction', jsonb_build_object(
                    'type', 'pass',
                    'playerId', p_player_id
                )
            );
        END IF;

        -- Atualizar pontuação no match_players
        UPDATE public.match_players
        SET score = COALESCE((v_scores->>user_id::text)::int, 0),
            is_winner = (user_id = v_winner_id)
        WHERE match_id = p_match_id;

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', CASE WHEN v_is_finished THEN NULL ELSE v_next_player_id END,
            'winner_id', v_winner_id,
            'is_draw', v_is_draw,
            'is_finished', v_is_finished
        );

    ELSE
        RAISE EXCEPTION 'UNKNOWN_DOMINO_ACTION: Ação % não é suportada no Dominó.', p_action_type USING ERRCODE = 'P0081';
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.validate_domino_action(UUID, UUID, VARCHAR, JSONB, JSONB, INTEGER) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 5. RPC Autoritativa: timeout_match_turn com Transição Completa de Bloqueio
-- Concorrência garantida via FOR UPDATE; resolve bloqueio para 2, 3 e 4 jogadores.
-- Preserva compatibilidade integral com Carta Duo, Tic-Tac-Toe e Snake.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.timeout_match_turn(
    p_match_id UUID,
    p_turn_number INTEGER
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_match RECORD;
    v_timed_out_player_id UUID;
    v_turn_timer INTEGER;
    v_new_deadline TIMESTAMPTZ;
    v_new_state JSONB;
    v_next_turn_player_id UUID;
    v_turn_order UUID[];
    v_num_players INTEGER;
    v_next_idx INTEGER;
    v_consecutive_passes INTEGER;
    v_envelope JSONB;
    v_new_action_history JSONB;

    -- Variáveis Carta Duo
    v_direction INTEGER;
    v_deck TEXT[];
    v_discard_pile TEXT[];
    v_hands JSONB;
    v_draw_card TEXT;
    v_hand_cards TEXT[];

    -- Variáveis Dominó Bloqueio por Timeouts
    v_blocked_res JSONB;
    v_is_finished BOOLEAN := false;
    v_resolved_winner_id UUID := NULL;
    v_resolved_is_draw BOOLEAN := false;
    v_resolved_scores JSONB;
    v_scoring_mode TEXT;
BEGIN
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Usuário não autenticado.' USING ERRCODE = 'P0001';
    END IF;

    -- 1. Trava Concorrente de Linha (FOR UPDATE)
    SELECT * INTO v_match
    FROM public.matches
    WHERE id = p_match_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATCH_NOT_FOUND: Partida não encontrada.' USING ERRCODE = 'P0016';
    END IF;

    -- Partida já finalizada: retorno idempotente
    IF v_match.status != 'in_progress' THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object('match_id', v_match.id, 'status', v_match.status, 'idempotent', true),
            'error', null
        );
    END IF;

    -- Validar pertencimento à partida
    IF NOT EXISTS (
        SELECT 1 FROM public.match_players WHERE match_id = p_match_id AND user_id = v_caller_id
    ) THEN
        RAISE EXCEPTION 'NOT_MATCH_PLAYER: Usuário não é participante da partida.' USING ERRCODE = 'P0018';
    END IF;

    -- 2. Proteção Concorrente contra Duplo Avanço
    IF v_match.turn_number != p_turn_number THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'match_id', v_match.id,
                'turn_number', v_match.turn_number,
                'current_turn_player_id', v_match.current_turn_player_id,
                'idempotent', true
            ),
            'error', null
        );
    END IF;

    -- 3. Validação Autoritativa de Tempo no Servidor: agora >= turn_deadline
    IF v_match.turn_deadline IS NOT NULL AND clock_timestamp() < v_match.turn_deadline THEN
        RAISE EXCEPTION 'TURN_NOT_EXPIRED: O prazo oficial do turno ainda não expirou no servidor.' USING ERRCODE = 'P0080';
    END IF;

    v_timed_out_player_id := v_match.current_turn_player_id;
    v_turn_timer := COALESCE((v_match.config->>'turn_timer')::INTEGER, (v_match.config->>'turnTimerSeconds')::INTEGER, 30);
    v_new_deadline := clock_timestamp() + (v_turn_timer || ' seconds')::INTERVAL;
    v_new_state := v_match.game_state;

    -- 4. Transição de Turno Conforme o Jogo
    IF v_match.game_id = 'carta_duo' THEN
        SELECT array_agg(user_id ORDER BY slot ASC) INTO v_turn_order
        FROM public.match_players
        WHERE match_id = p_match_id;

        v_direction := COALESCE((v_new_state->>'direction')::INTEGER, 1);
        v_next_turn_player_id := public.get_next_carta_duo_player_id(v_timed_out_player_id, v_turn_order, v_direction, 1);

        -- Penalidade de timeout no Carta Duo: compra forçada de 1 carta
        v_deck := ARRAY(SELECT jsonb_array_elements_text(v_new_state->'deck'));
        v_discard_pile := ARRAY(SELECT jsonb_array_elements_text(v_new_state->'discard_pile'));
        v_hands := v_new_state->'hands';

        IF array_length(v_deck, 1) IS NULL OR array_length(v_deck, 1) = 0 THEN
            IF array_length(v_discard_pile, 1) > 1 THEN
                DECLARE
                    v_top TEXT := v_discard_pile[1];
                    v_rest TEXT[] := v_discard_pile[2:array_length(v_discard_pile, 1)];
                BEGIN
                    SELECT array_agg(card ORDER BY random()) INTO v_deck FROM unnest(v_rest) AS card;
                    v_discard_pile := ARRAY[v_top];
                END;
            END IF;
        END IF;

        IF array_length(v_deck, 1) > 0 THEN
            v_draw_card := v_deck[1];
            v_deck := v_deck[2:array_length(v_deck, 1)];

            SELECT COALESCE(array_agg(c), ARRAY[]::TEXT[]) INTO v_hand_cards
            FROM jsonb_array_elements_text(v_hands->(v_timed_out_player_id::text)) AS c;

            v_hand_cards := array_append(v_hand_cards, v_draw_card);
            v_hands := v_hands || jsonb_build_object(v_timed_out_player_id::text, to_jsonb(v_hand_cards));
        END IF;

        v_new_state := v_new_state || jsonb_build_object(
            'deck', to_jsonb(COALESCE(v_deck, ARRAY[]::TEXT[])),
            'discard_pile', to_jsonb(COALESCE(v_discard_pile, ARRAY[]::TEXT[])),
            'top_card', v_discard_pile[1],
            'hands', v_hands,
            'currentTurnPlayerId', v_next_turn_player_id
        );

        UPDATE public.match_players
        SET score = jsonb_array_length(v_hands->(v_timed_out_player_id::text))
        WHERE match_id = p_match_id AND user_id = v_timed_out_player_id;

    ELSIF v_match.game_id = 'domino' THEN
        -- Dominó Duo: rotação cíclica entre 2, 3 ou 4 participantes
        v_turn_order := ARRAY(SELECT jsonb_array_elements_text(v_new_state->'turnOrder')::uuid);
        v_num_players := array_length(v_turn_order, 1);
        IF v_num_players IS NULL OR v_num_players = 0 THEN
            SELECT array_agg(user_id ORDER BY slot ASC) INTO v_turn_order
            FROM public.match_players
            WHERE match_id = p_match_id;
            v_num_players := array_length(v_turn_order, 1);
        END IF;

        v_next_turn_player_id := v_turn_order[1];
        FOR v_cur_idx IN 1..v_num_players LOOP
            IF v_turn_order[v_cur_idx] = v_timed_out_player_id THEN
                v_next_idx := (v_cur_idx % v_num_players) + 1;
                v_next_turn_player_id := v_turn_order[v_next_idx];
                EXIT;
            END IF;
        END LOOP;

        v_consecutive_passes := COALESCE((v_new_state->>'consecutivePasses')::integer, 0) + 1;

        -- DETECÇÃO E RESOLUÇÃO COMPLETA DE TRANCAMENTO (BLOCKED GAME)
        -- Ocorre quando os timeouts consecutivos atingem a quantidade de participantes
        IF v_consecutive_passes >= v_num_players THEN
            v_blocked_res := public.resolve_domino_blocked_round(
                v_new_state || jsonb_build_object('consecutivePasses', v_consecutive_passes)
            );

            v_is_finished := (v_blocked_res->>'is_finished')::boolean;
            v_resolved_winner_id := (v_blocked_res->>'winner_id')::uuid;
            v_resolved_is_draw := (v_blocked_res->>'is_draw')::boolean;
            v_resolved_scores := v_blocked_res->'scores';
            v_new_state := v_blocked_res->'new_state';

            v_scoring_mode := COALESCE(v_match.config->>'scoring_mode', v_match.config->>'scoringMode', 'single_round');
            IF NOT v_is_finished AND v_scoring_mode = 'target_score' THEN
                -- Inicia nova rodada quando não atinge a pontuação máxima
                v_new_state := public.start_domino_next_round(v_new_state, v_resolved_winner_id);
                v_next_turn_player_id := (v_new_state->>'currentTurnPlayerId')::uuid;
            END IF;
        ELSE
            v_new_state := v_new_state || jsonb_build_object(
                'currentTurnPlayerId', v_next_turn_player_id,
                'drawsThisTurn', 0,
                'consecutivePasses', v_consecutive_passes
            );
        END IF;

    ELSE
        -- Tic-Tac-Toe ou genérico: passa o turno para o oponente seguinte
        SELECT user_id INTO v_next_turn_player_id
        FROM public.match_players
        WHERE match_id = p_match_id AND user_id != v_timed_out_player_id
        ORDER BY slot ASC
        LIMIT 1;

        v_new_state := v_new_state || jsonb_build_object('currentTurnPlayerId', v_next_turn_player_id);
    END IF;

    -- 5. Registrar no histórico oficial
    v_envelope := jsonb_build_object(
        'action_id', gen_random_uuid()::text,
        'turn_number', v_match.turn_number,
        'player_id', v_timed_out_player_id,
        'action_type', 'timeout_turn',
        'payload', '{}'::jsonb,
        'server_timestamp', clock_timestamp()
    );
    v_new_action_history := v_match.action_history || jsonb_build_array(v_envelope);

    -- 6. Atualização oficial no PostgreSQL
    IF v_is_finished THEN
        UPDATE public.matches SET
            game_state = v_new_state,
            action_history = v_new_action_history,
            turn_number = v_match.turn_number + 1,
            current_turn_player_id = NULL,
            turn_deadline = NULL,
            status = 'finished',
            winner_id = v_resolved_winner_id,
            is_draw = v_resolved_is_draw,
            finish_reason = 'timeout',
            finished_at = clock_timestamp(),
            updated_at = clock_timestamp()
        WHERE id = p_match_id
        RETURNING * INTO v_match;

        -- Atualizar pontuação e vencedor no match_players
        IF v_resolved_scores IS NOT NULL THEN
            UPDATE public.match_players
            SET score = COALESCE((v_resolved_scores->>user_id::text)::int, 0),
                is_winner = (user_id = v_resolved_winner_id)
            WHERE match_id = p_match_id;
        ELSIF v_resolved_winner_id IS NOT NULL THEN
            UPDATE public.match_players
            SET is_winner = (user_id = v_resolved_winner_id)
            WHERE match_id = p_match_id;
        END IF;

        -- Liberar sala
        IF v_match.room_id IS NOT NULL THEN
            UPDATE public.rooms SET
                status = 'waiting',
                current_match_id = NULL,
                updated_at = clock_timestamp()
            WHERE id = v_match.room_id AND current_match_id = p_match_id;
        END IF;

    ELSE
        UPDATE public.matches SET
            game_state = v_new_state,
            action_history = v_new_action_history,
            turn_number = v_match.turn_number + 1,
            current_turn_player_id = v_next_turn_player_id,
            turn_deadline = v_new_deadline,
            updated_at = clock_timestamp()
        WHERE id = p_match_id
        RETURNING * INTO v_match;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'match_id', v_match.id,
            'turn_number', v_match.turn_number,
            'current_turn_player_id', v_match.current_turn_player_id,
            'turn_deadline', v_match.turn_deadline,
            'is_finished', v_is_finished,
            'winner_id', v_resolved_winner_id,
            'is_draw', v_resolved_is_draw
        ),
        'error', null
    );
END;
$$;

REVOKE ALL ON FUNCTION public.timeout_match_turn(UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.timeout_match_turn(UUID, INTEGER) TO authenticated;

-- ----------------------------------------------------------------------------
-- 6. RPC: get_match_snapshot_for_player (Garantia de Autorização e Sanitização)
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.get_match_snapshot_for_player(
    p_match_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_match RECORD;
    v_players_json JSON;
    v_state JSONB;
    v_sanitized_state JSONB;
    v_hands JSONB;
    v_my_hand JSONB;
    v_hands_count JSONB := '{}'::jsonb;
    v_pid TEXT;
    v_boneyard JSONB;
BEGIN
    -- 1. Rejeitar usuários não autenticados
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Usuário não autenticado.' USING ERRCODE = 'P0001';
    END IF;

    -- 2. Confirmar existência da partida
    SELECT * INTO v_match
    FROM public.matches
    WHERE id = p_match_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATCH_NOT_FOUND: Partida não encontrada.' USING ERRCODE = 'P0016';
    END IF;

    -- 3. Confirmar que o usuário autenticado pertence à partida (Autorização Estrita)
    IF NOT EXISTS (
        SELECT 1 FROM public.match_players
        WHERE match_id = p_match_id AND user_id = v_caller_id
    ) THEN
        RAISE EXCEPTION 'FORBIDDEN: Jogador não pertence a esta partida.' USING ERRCODE = 'P0003';
    END IF;

    -- 4. Carregar lista de participantes da partida ordenados por slot
    SELECT json_agg(row_to_json(mp) ORDER BY mp.slot ASC) INTO v_players_json
    FROM public.match_players mp
    WHERE mp.match_id = p_match_id;

    v_state := v_match.game_state;

    -- 5. Projeção segura de dados por jogo:
    IF v_match.game_id = 'domino' THEN
        v_hands := COALESCE(v_state->'hands', '{}'::jsonb);
        v_my_hand := COALESCE(v_hands->(v_caller_id::text), '[]'::jsonb);
        v_boneyard := COALESCE(v_state->'boneyard', '[]'::jsonb);

        -- Calcular contagens de peças para cada participante sem revelar as faces
        FOR v_pid IN SELECT jsonb_object_keys(v_hands) LOOP
            v_hands_count := v_hands_count || jsonb_build_object(v_pid, jsonb_array_length(v_hands->v_pid));
        END LOOP;

        IF v_match.status = 'in_progress' THEN
            -- Partida ativa: esconde boneyard e mãos adversárias
            v_sanitized_state := v_state - 'boneyard' - 'hands' || jsonb_build_object(
                'boneyardCount', jsonb_array_length(v_boneyard),
                'myHand', v_my_hand,
                'handsCount', v_hands_count
            );
        ELSE
            -- Partida encerrada: revela todas as mãos para auditoria e histórico
            v_sanitized_state := v_state || jsonb_build_object(
                'boneyardCount', jsonb_array_length(v_boneyard),
                'myHand', v_my_hand,
                'handsCount', v_hands_count,
                'revealedHands', v_hands
            );
        END IF;
    ELSE
        v_sanitized_state := v_state;
    END IF;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'id', v_match.id,
            'room_id', v_match.room_id,
            'game_id', v_match.game_id,
            'status', v_match.status,
            'current_turn_player_id', v_match.current_turn_player_id,
            'turn_deadline', v_match.turn_deadline,
            'turn_number', v_match.turn_number,
            'game_state', v_sanitized_state,
            'action_history', v_match.action_history,
            'winner_id', v_match.winner_id,
            'is_draw', v_match.is_draw,
            'finish_reason', v_match.finish_reason,
            'created_at', v_match.created_at,
            'started_at', v_match.started_at,
            'finished_at', v_match.finished_at,
            'match_players', coalesce(v_players_json, '[]'::json)
        ),
        'error', null
    );
END;
$$;

REVOKE ALL ON FUNCTION public.get_match_snapshot_for_player(UUID) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.get_match_snapshot_for_player(UUID) TO authenticated;
