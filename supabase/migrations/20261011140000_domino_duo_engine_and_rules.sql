-- ============================================================================
-- Migration: 20261011140000_domino_duo_engine_and_rules.sql
-- Project: DuoPlay-Online
-- Feature: Dominó Duo — Motor de Regras, Tabuleiro, Configuração e Validação Server-Side
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Registrar / Ativar Dominó Duo no Catálogo de Jogos (public.games)
-- ----------------------------------------------------------------------------
INSERT INTO public.games (
    id,
    name,
    description,
    min_players,
    max_players,
    is_active,
    game_type,
    capabilities,
    config
) VALUES (
    'domino',
    'Dominó Duo',
    'Clássico dominó competitivo de turnos rápidos e estratégia. Bloqueie as saídas e pontue com inteligência matemática.',
    2,
    4,
    true,
    'turn_based',
    '{"turns": true, "scoring": true, "custom_rules": true, "teams": true}'::jsonb,
    jsonb_build_object(
        'category_label', 'Estratégia / Tabuleiro',
        'requires_timer', true,
        'tileset', 'double_6',
        'max_tile_value', 6,
        'initial_hand_size', 7,
        'draw_rule', 'open',
        'play_immediately', true,
        'auto_pass', true,
        'start_rule', 'highest_double',
        'block_rule', 'lowest_pip_count',
        'scoring_mode', 'single_round',
        'target_score', 100,
        'turn_timer', 30
    )
)
ON CONFLICT (id) DO UPDATE SET
    name = EXCLUDED.name,
    description = EXCLUDED.description,
    min_players = 2,
    max_players = 4,
    is_active = true,
    game_type = 'turn_based',
    capabilities = EXCLUDED.capabilities,
    config = EXCLUDED.config;

-- ----------------------------------------------------------------------------
-- 2. Inicializador de Estado Oficial do Dominó Duo
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
BEGIN
    v_num_players := array_length(p_player_ids, 1);
    IF v_num_players IS NULL OR v_num_players < 2 THEN
        RAISE EXCEPTION 'INSUFFICIENT_PLAYERS: Dominó requer ao menos 2 jogadores.' USING ERRCODE = 'P0012';
    END IF;

    -- Parâmetros da configuração
    v_max_tile_val := COALESCE((p_config->>'max_tile_value')::INTEGER, (p_config->>'maxTileValue')::INTEGER, 6);
    IF v_max_tile_val < 3 OR v_max_tile_val > 12 THEN
        v_max_tile_val := 6;
    END IF;

    v_initial_hand_size := COALESCE((p_config->>'initial_hand_size')::INTEGER, (p_config->>'initialHandSize')::INTEGER, 7);
    v_start_rule := COALESCE(p_config->>'start_rule', p_config->>'startRule', 'highest_double');
    v_team_mode := COALESCE(p_config->>'team_mode', p_config->>'teamMode', 'individual');

    -- Ajusta hand_size para não estourar o conjunto
    -- Total de peças = (N + 1) * (N + 2) / 2
    IF (v_initial_hand_size * v_num_players) > (((v_max_tile_val + 1) * (v_max_tile_val + 2)) / 2) THEN
        v_initial_hand_size := (((v_max_tile_val + 1) * (v_max_tile_val + 2)) / 2) / v_num_players;
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

    -- Peças restantes formam o monte (boneyard)
    v_boneyard := COALESCE(v_shuffled, ARRAY[]::JSONB[]);

    -- 4. Determinar jogador inicial
    v_current_starter := p_player_ids[1];

    IF v_start_rule = 'random' THEN
        v_current_starter := p_player_ids[1 + floor(random() * v_num_players)::integer];
    ELSIF v_start_rule = 'highest_double' THEN
        -- Procura a maior dupla em todas as mãos
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

        -- Se ninguém tiver dupla, desempata pela maior soma
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
    END IF;

    RETURN jsonb_build_object(
        'config', p_config,
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
        'winnerId', null,
        'isFinished', false
    );
END;
$$;

REVOKE ALL ON FUNCTION public.initialize_domino_state_for_players(UUID[], JSONB) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Validador Server-Side Oficial de Regras do Dominó Duo (validate_domino_action)
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

    -- Variáveis de jogada
    v_play_tile JSONB;
    v_t1 INTEGER;
    v_t2 INTEGER;
    v_side TEXT;
    v_has_tile BOOLEAN := false;
    v_tile_elem JSONB;
    v_can_connect BOOLEAN := false;
    v_new_left_end INTEGER;
    v_new_right_end INTEGER;
    v_new_placed_tile JSONB;
    v_new_board_tiles JSONB;
    v_drawn_tile JSONB;
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
    v_lowest_sum INTEGER := 999999;
    v_player_sum INTEGER;
    v_tie_blocked BOOLEAN := false;
    v_scores JSONB;
    v_new_state JSONB;
    v_valid_moves_exist BOOLEAN := false;
    p_idx INTEGER;
    v_check_tile JSONB;
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

    v_draw_rule := COALESCE(v_config->>'draw_rule', v_config->>'drawRule', 'open');
    v_play_immediately := COALESCE((v_config->>'play_immediately')::boolean, (v_config->>'playImmediately')::boolean, true);
    v_auto_pass := COALESCE((v_config->>'auto_pass')::boolean, (v_config->>'autoPass')::boolean, true);
    v_max_draws := COALESCE((v_config->>'max_draws_per_turn')::integer, (v_config->>'maxDrawsPerTurn')::integer, 99);
    v_scoring_mode := COALESCE(v_config->>'scoring_mode', v_config->>'scoringMode', 'single_round');
    v_target_score := COALESCE((v_config->>'target_score')::integer, (v_config->>'targetScore')::integer, 100);
    v_team_mode := COALESCE(v_config->>'team_mode', v_config->>'teamMode', 'individual');

    v_num_players := array_length(v_turn_order, 1);

    -- 1. Validar se a partida não foi finalizada anteriormente
    IF COALESCE((p_current_state->>'isFinished')::boolean, false) = true THEN
        RAISE EXCEPTION 'MATCH_ALREADY_FINISHED: Esta partida já foi finalizada.' USING ERRCODE = 'P0070';
    END IF;

    -- 2. Validar se é o turno do jogador
    IF v_current_turn_player_id != p_player_id THEN
        RAISE EXCEPTION 'NOT_YOUR_TURN: Não é o seu turno para realizar esta ação no Dominó.' USING ERRCODE = 'P0071';
    END IF;

    v_player_hand := COALESCE(v_hands->(p_player_id::text), '[]'::jsonb);

    -- Calcular próximo jogador na ordem cíclica
    FOR p_idx IN 1..v_num_players LOOP
        IF v_turn_order[p_idx] = p_player_id THEN
            v_next_idx := (p_idx % v_num_players) + 1;
            v_next_player_id := v_turn_order[v_next_idx];
            EXIT;
        END IF;
    END LOOP;

    -- ========================================================================
    -- AÇÃO 1: play_tile (Jogar / Encaixar uma Peça no Tabuleiro)
    -- ========================================================================
    IF p_action_type = 'play_tile' THEN
        v_play_tile := p_payload->'tile';
        v_side := COALESCE(p_payload->>'side', 'left');

        IF v_play_tile IS NULL OR jsonb_array_length(v_play_tile) != 2 THEN
            RAISE EXCEPTION 'INVALID_TILE_PAYLOAD: Peça inválida fornecida para jogada.' USING ERRCODE = 'P0072';
        END IF;

        v_t1 := (v_play_tile->>0)::integer;
        v_t2 := (v_play_tile->>1)::integer;

        -- Verificar se a peça pertence à mão do jogador
        v_new_player_hand := ARRAY[]::JSONB[];
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
            IF NOT v_has_tile AND (
                ((v_tile_elem->>0)::int = v_t1 AND (v_tile_elem->>1)::int = v_t2) OR
                ((v_tile_elem->>0)::int = v_t2 AND (v_tile_elem->>1)::int = v_t1)
            ) THEN
                v_has_tile := true; -- Retira a peça jogada da mão
            ELSE
                v_new_player_hand := array_append(v_new_player_hand, v_tile_elem);
            END IF;
        END LOOP;

        IF NOT v_has_tile THEN
            RAISE EXCEPTION 'TILE_NOT_IN_HAND: A peça jogada não pertence à sua mão.' USING ERRCODE = 'P0073';
        END IF;

        -- Validar encaixe matemático no tabuleiro
        IF v_left_end IS NULL OR v_right_end IS NULL OR jsonb_array_length(v_tiles) = 0 THEN
            -- Primeira peça jogada: define o início da cadeia
            v_new_left_end := v_t1;
            v_new_right_end := v_t2;
            v_new_placed_tile := jsonb_build_object(
                'id', v_t1 || '-' || v_t2 || '-0',
                'tile', jsonb_build_array(v_t1, v_t2),
                'exposedValueLeft', v_t1,
                'exposedValueRight', v_t2,
                'placedBy', p_player_id,
                'side', 'left',
                'sequenceIndex', 0
            );
            v_new_board_tiles := jsonb_build_array(v_new_placed_tile);
        ELSE
            IF v_side = 'left' THEN
                IF v_t1 != v_left_end AND v_t2 != v_left_end THEN
                    RAISE EXCEPTION 'ILLEGAL_TILE_PLACEMENT: A peça [%|%] não conecta na ponta esquerda (%).', v_t1, v_t2, v_left_end USING ERRCODE = 'P0074';
                END IF;
                -- Ponta livre vira o novo leftEnd
                IF v_t1 = v_left_end THEN v_new_left_end := v_t2; ELSE v_new_left_end := v_t1; END IF;
                v_new_right_end := v_right_end;

                v_new_placed_tile := jsonb_build_object(
                    'id', v_t1 || '-' || v_t2 || '-' || jsonb_array_length(v_tiles),
                    'tile', jsonb_build_array(v_t1, v_t2),
                    'exposedValueLeft', v_new_left_end,
                    'exposedValueRight', v_left_end,
                    'placedBy', p_player_id,
                    'side', 'left',
                    'sequenceIndex', jsonb_array_length(v_tiles)
                );
                v_new_board_tiles := jsonb_build_array(v_new_placed_tile) || v_tiles;

            ELSIF v_side = 'right' THEN
                IF v_t1 != v_right_end AND v_t2 != v_right_end THEN
                    RAISE EXCEPTION 'ILLEGAL_TILE_PLACEMENT: A peça [%|%] não conecta na ponta direita (%).', v_t1, v_t2, v_right_end USING ERRCODE = 'P0074';
                END IF;
                -- Ponta livre vira o novo rightEnd
                IF v_t1 = v_right_end THEN v_new_right_end := v_t2; ELSE v_new_right_end := v_t1; END IF;
                v_new_left_end := v_left_end;

                v_new_placed_tile := jsonb_build_object(
                    'id', v_t1 || '-' || v_t2 || '-' || jsonb_array_length(v_tiles),
                    'tile', jsonb_build_array(v_t1, v_t2),
                    'exposedValueLeft', v_right_end,
                    'exposedValueRight', v_new_right_end,
                    'placedBy', p_player_id,
                    'side', 'right',
                    'sequenceIndex', jsonb_array_length(v_tiles)
                );
                v_new_board_tiles := v_tiles || jsonb_build_array(v_new_placed_tile);
            ELSE
                RAISE EXCEPTION 'INVALID_BOARD_SIDE: Extremidade deve ser "left" ou "right".' USING ERRCODE = 'P0075';
            END IF;
        END IF;

        -- Atualizar mão do jogador no estado
        v_hands := v_hands || jsonb_build_object(p_player_id::text, to_jsonb(v_new_player_hand));
        v_rem_hand_len := array_length(v_new_player_hand, 1);
        IF v_rem_hand_len IS NULL THEN v_rem_hand_len := 0; END IF;

        -- Checar vitória por descarte (Bateu!)
        IF v_rem_hand_len = 0 THEN
            v_is_finished := true;
            v_winner_id := p_player_id;
            v_finish_reason := 'domino';

            -- Calcular pontos da rodada: soma das peças restantes dos oponentes
            FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
                IF v_other_pid != p_player_id::text THEN
                    v_other_hand := v_hands->v_other_pid;
                    FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_other_hand) LOOP
                        v_round_points := v_round_points + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                    END LOOP;
                END IF;
            END LOOP;

            v_scores := v_scores || jsonb_build_object(p_player_id::text, COALESCE((v_scores->>p_player_id::text)::int, 0) + v_round_points);
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
            'isFinished', v_is_finished,
            'winnerId', v_winner_id,
            'finishReason', v_finish_reason,
            'lastAction', jsonb_build_object(
                'type', 'play',
                'playerId', p_player_id,
                'tile', jsonb_build_array(v_t1, v_t2),
                'side', v_side
            )
        );

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

        IF v_draw_rule = 'no_draw' THEN
            RAISE EXCEPTION 'DRAW_NOT_ALLOWED: A regra da partida não permite comprar peças.' USING ERRCODE = 'P0077';
        END IF;

        IF v_draw_rule = 'one_tile' AND v_draws_this_turn >= 1 THEN
            RAISE EXCEPTION 'DRAW_LIMIT_REACHED: Limite de 1 compra por turno atingido.' USING ERRCODE = 'P0078';
        END IF;

        IF v_draw_rule = 'custom_limit' AND v_draws_this_turn >= v_max_draws THEN
            RAISE EXCEPTION 'DRAW_LIMIT_REACHED: Limite máximo de compras por turno atingido.' USING ERRCODE = 'P0078';
        END IF;

        -- Tirar primeira peça do boneyard
        v_drawn_tile := v_boneyard->0;
        v_boneyard := v_boneyard - 0;

        -- Adicionar à mão do jogador
        v_player_hand := v_player_hand || jsonb_build_array(v_drawn_tile);
        v_hands := v_hands || jsonb_build_object(p_player_id::text, v_player_hand);

        v_new_state := p_current_state || jsonb_build_object(
            'boneyard', v_boneyard,
            'hands', v_hands,
            'drawsThisTurn', v_draws_this_turn + 1,
            'lastAction', jsonb_build_object(
                'type', 'draw',
                'playerId', p_player_id
            )
        );

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', v_current_turn_player_id,
            'winner_id', NULL,
            'is_draw', false,
            'is_finished', false
        );

    -- ========================================================================
    -- AÇÃO 3: pass_turn (Passar a Vez)
    -- ========================================================================
    ELSIF p_action_type = 'pass_turn' THEN
        -- 1. Validar se o jogador realmente NÃO possui jogadas válidas na mão
        IF v_left_end IS NOT NULL AND v_right_end IS NOT NULL THEN
            FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
                v_t1 := (v_tile_elem->>0)::int;
                v_t2 := (v_tile_elem->>1)::int;
                IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                    v_valid_moves_exist := true;
                    EXIT;
                END IF;
            END LOOP;
        END IF;

        IF v_valid_moves_exist THEN
            RAISE EXCEPTION 'CANNOT_PASS_WITH_VALID_MOVES: Você possui peças jogáveis e não pode passar a vez.' USING ERRCODE = 'P0079';
        END IF;

        -- 2. Validar se o jogador ainda pode comprar no monte antes de passar
        v_boneyard_len := jsonb_array_length(v_boneyard);
        IF v_boneyard_len > 0 AND v_draw_rule = 'open' THEN
            RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar peças do monte até conseguir jogar ou esvaziar o monte.' USING ERRCODE = 'P0080';
        END IF;

        IF v_boneyard_len > 0 AND v_draw_rule = 'one_tile' AND v_draws_this_turn < 1 THEN
            RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar a peça do turno antes de passar.' USING ERRCODE = 'P0080';
        END IF;

        -- Passagem válida: incrementa passes consecutivos
        v_consecutive_passes := v_consecutive_passes + 1;

        -- Se todos os jogadores passaram em sequência: BLOQUEIO DETECTADO! (Trancado)
        IF v_consecutive_passes >= v_num_players THEN
            v_is_finished := true;
            v_finish_reason := 'blocked';

            -- Calcular soma dos pips de cada jogador para determinar quem vence
            FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
                v_player_sum := 0;
                FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_other_pid) LOOP
                    v_player_sum := v_player_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                END LOOP;

                IF v_player_sum < v_lowest_sum THEN
                    v_lowest_sum := v_player_sum;
                    v_winner_id := v_other_pid::uuid;
                    v_tie_blocked := false;
                ELSIF v_player_sum = v_lowest_sum THEN
                    v_tie_blocked := true;
                END IF;
            END LOOP;

            IF v_tie_blocked THEN
                v_winner_id := NULL;
                v_is_draw := true;
            ELSE
                v_is_draw := false;
                -- Vencedor por menor soma ganha os pontos das peças adversárias
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

        v_new_state := p_current_state || jsonb_build_object(
            'currentTurnPlayerId', CASE WHEN v_is_finished THEN v_current_turn_player_id ELSE v_next_player_id END,
            'drawsThisTurn', 0,
            'consecutivePasses', v_consecutive_passes,
            'isBlocked', (v_finish_reason = 'blocked'),
            'scores', v_scores,
            'isFinished', v_is_finished,
            'winnerId', v_winner_id,
            'finishReason', v_finish_reason,
            'lastAction', jsonb_build_object(
                'type', 'pass',
                'playerId', p_player_id
            )
        );

        -- Atualizar pontuações se bloqueado
        IF v_is_finished THEN
            UPDATE public.match_players
            SET score = COALESCE((v_scores->>user_id::text)::int, 0),
                is_winner = (user_id = v_winner_id)
            WHERE match_id = p_match_id;
        END IF;

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', CASE WHEN v_is_finished THEN NULL ELSE v_next_player_id END,
            'winner_id', v_winner_id,
            'is_draw', v_is_draw,
            'is_finished', v_is_finished
        );

    ELSE
        RAISE EXCEPTION 'UNKNOWN_DOMINO_ACTION: Ação % não é suportada pelas regras do Dominó Duo.', p_action_type USING ERRCODE = 'P0081';
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- 4. Atualizar dispatch_game_action para Suportar Dominó Duo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.dispatch_game_action(
    p_game_id VARCHAR(50),
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
BEGIN
    IF p_game_id = 'tic_tac_toe' OR p_game_id = 'tic-tac-toe' THEN
        RETURN public.validate_tic_tac_toe_action(
            p_match_id,
            p_player_id,
            p_action_type,
            p_payload,
            p_current_state,
            p_turn_number
        );
    ELSIF p_game_id = 'carta_duo' OR p_game_id = 'carta-duo' THEN
        RETURN public.validate_carta_duo_action(
            p_match_id,
            p_player_id,
            p_action_type,
            p_payload,
            p_current_state,
            p_turn_number
        );
    ELSIF p_game_id = 'snake' THEN
        RETURN public.validate_snake_action(
            p_match_id,
            p_player_id,
            p_action_type,
            p_payload,
            p_current_state,
            p_turn_number
        );
    ELSIF p_game_id = 'domino' THEN
        RETURN public.validate_domino_action(
            p_match_id,
            p_player_id,
            p_action_type,
            p_payload,
            p_current_state,
            p_turn_number
        );
    ELSE
        RAISE EXCEPTION 'GAME_VALIDATOR_NOT_AVAILABLE: As regras deste jogo ainda não estão disponíveis no servidor para validar esta ação.' USING ERRCODE = 'P0030';
    END IF;
END;
$$;

-- ----------------------------------------------------------------------------
-- 5. Atualizar start_match para Suportar Inicialização do Dominó Duo
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.start_match(
    p_room_id UUID
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_room RECORD;
    v_game RECORD;
    v_player_count INTEGER;
    v_unready_count INTEGER;
    v_match_id UUID;
    v_match RECORD;
    v_slot1_user_id UUID;
    v_players_json JSON;
    v_rec RECORD;
    v_player_ids UUID[];
    v_initial_game_state JSONB;
    v_config JSONB;
    v_turn_timer INTEGER;
BEGIN
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Usuário não autenticado.' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_room 
    FROM public.rooms 
    WHERE id = p_room_id 
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'ROOM_NOT_FOUND: Sala não encontrada.' USING ERRCODE = 'P0005';
    END IF;

    IF v_room.host_id != v_caller_id THEN
        RAISE EXCEPTION 'NOT_ROOM_HOST: Apenas o anfitrião pode iniciar a partida.' USING ERRCODE = 'P0010';
    END IF;

    -- Idempotência
    IF v_room.status = 'in_game' AND v_room.current_match_id IS NOT NULL THEN
        SELECT * INTO v_match FROM public.matches WHERE id = v_room.current_match_id;
        IF FOUND AND v_match.status = 'in_progress' THEN
            SELECT json_agg(row_to_json(mp)) INTO v_players_json
            FROM public.match_players mp
            WHERE mp.match_id = v_match.id;

            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'match', row_to_json(v_match),
                    'players', coalesce(v_players_json, '[]'::json),
                    'idempotent', true
                ),
                'error', null
            );
        END IF;
    END IF;

    IF v_room.status != 'waiting' THEN
        RAISE EXCEPTION 'INVALID_ROOM_STATUS: A sala não está em estado de espera.' USING ERRCODE = 'P0011';
    END IF;

    SELECT * INTO v_game FROM public.games WHERE id = v_room.game_id;
    IF NOT FOUND OR v_game.is_active = false THEN
        RAISE EXCEPTION 'GAME_NOT_FOUND: O jogo desta sala não está ativo.' USING ERRCODE = 'P0003';
    END IF;

    SELECT count(*) INTO v_player_count 
    FROM public.room_members 
    WHERE room_id = p_room_id AND role = 'player';

    IF v_player_count < v_game.min_players THEN
        RAISE EXCEPTION 'INSUFFICIENT_PLAYERS: Quantidade de jogadores insuficiente (mínimo exigido: %).', v_game.min_players USING ERRCODE = 'P0012';
    END IF;

    IF v_player_count > v_game.max_players THEN
        RAISE EXCEPTION 'TOO_MANY_PLAYERS: Quantidade de jogadores excede o limite máximo (máximo: %).', v_game.max_players USING ERRCODE = 'P0013';
    END IF;

    SELECT count(*) INTO v_unready_count 
    FROM public.room_members 
    WHERE room_id = p_room_id AND role = 'player' AND is_ready = false;

    IF v_unready_count > 0 THEN
        RAISE EXCEPTION 'PLAYERS_NOT_READY: Nem todos os jogadores confirmaram prontidão.' USING ERRCODE = 'P0014';
    END IF;

    SELECT array_agg(user_id ORDER BY slot_number ASC) INTO v_player_ids
    FROM public.room_members
    WHERE room_id = p_room_id AND role = 'player';

    v_slot1_user_id := v_player_ids[1];
    v_match_id := gen_random_uuid();
    v_config := coalesce(v_room.config, v_game.config, '{}'::jsonb);
    v_turn_timer := COALESCE((v_config->>'turn_timer')::INTEGER, (v_config->>'turnTimerSeconds')::INTEGER, 30);

    -- Inicializar estado determinístico de acordo com o jogo
    IF v_game.id = 'carta_duo' OR v_game.id = 'carta-duo' THEN
        v_initial_game_state := public.initialize_carta_duo_state_for_players(v_player_ids, v_config);
        v_slot1_user_id := (v_initial_game_state->>'current_turn_player_id')::uuid;
    ELSIF v_game.id = 'domino' THEN
        v_initial_game_state := public.initialize_domino_state_for_players(v_player_ids, v_config);
        v_slot1_user_id := (v_initial_game_state->>'currentTurnPlayerId')::uuid;
    ELSIF v_game.id = 'snake' THEN
        v_initial_game_state := public.initialize_snake_state_for_players(v_player_ids, v_config);
        v_slot1_user_id := v_player_ids[1];
    ELSE
        v_initial_game_state := jsonb_build_object('config', v_config);
    END IF;

    INSERT INTO public.matches (
        id,
        room_id,
        game_id,
        status,
        current_turn_player_id,
        turn_deadline,
        turn_number,
        game_state,
        action_history,
        config,
        created_at,
        started_at
    ) VALUES (
        v_match_id,
        p_room_id,
        v_game.id,
        'in_progress',
        v_slot1_user_id,
        CASE WHEN v_turn_timer > 0 THEN now() + (v_turn_timer || ' seconds')::INTERVAL ELSE NULL END,
        1,
        v_initial_game_state,
        '[]'::jsonb,
        v_config,
        now(),
        now()
    ) RETURNING * INTO v_match;

    FOR v_rec IN 
        SELECT user_id, slot_number 
        FROM public.room_members 
        WHERE room_id = p_room_id AND role = 'player' 
        ORDER BY slot_number ASC 
    LOOP
        INSERT INTO public.match_players (
            match_id,
            user_id,
            slot,
            game_symbol,
            score,
            is_winner,
            joined_at
        ) VALUES (
            v_match_id,
            v_rec.user_id,
            v_rec.slot_number,
            NULL,
            0,
            false,
            now()
        );
    END LOOP;

    UPDATE public.rooms 
    SET status = 'in_game', current_match_id = v_match_id, updated_at = now()
    WHERE id = p_room_id;

    SELECT json_agg(row_to_json(mp)) INTO v_players_json
    FROM public.match_players mp
    WHERE mp.match_id = v_match_id;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'match', row_to_json(v_match),
            'players', coalesce(v_players_json, '[]'::json)
        ),
        'error', null
    );
END;
$$;

-- ----------------------------------------------------------------------------
-- 6. RPC: get_match_snapshot_for_player (Requirement 9: Projeção Segura e Privacidade)
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
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Usuário não autenticado.' USING ERRCODE = 'P0001';
    END IF;

    SELECT * INTO v_match
    FROM public.matches
    WHERE id = p_match_id;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATCH_NOT_FOUND: Partida não encontrada.' USING ERRCODE = 'P0016';
    END IF;

    SELECT json_agg(row_to_json(mp)) INTO v_players_json
    FROM public.match_players mp
    WHERE mp.match_id = p_match_id;

    v_state := v_match.game_state;

    -- Se for Dominó e a partida estiver em andamento, sanitizar mãos e monte
    IF v_match.game_id = 'domino' AND v_match.status = 'in_progress' THEN
        v_hands := COALESCE(v_state->'hands', '{}'::jsonb);
        v_my_hand := COALESCE(v_hands->(v_caller_id::text), '[]'::jsonb);
        v_boneyard := COALESCE(v_state->'boneyard', '[]'::jsonb);

        -- Criar handsCount sem revelar as peças dos adversários
        FOR v_pid IN SELECT jsonb_object_keys(v_hands) LOOP
            v_hands_count := v_hands_count || jsonb_build_object(v_pid, jsonb_array_length(v_hands->v_pid));
        END LOOP;

        v_sanitized_state := v_state - 'boneyard' - 'hands' || jsonb_build_object(
            'boneyardCount', jsonb_array_length(v_boneyard),
            'myHand', v_my_hand,
            'handsCount', v_hands_count
        );
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
