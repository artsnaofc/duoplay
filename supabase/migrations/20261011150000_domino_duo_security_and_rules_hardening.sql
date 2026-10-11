-- ============================================================================
-- Migration: 20261011150000_domino_duo_security_and_rules_hardening.sql
-- Project: DuoPlay-Online
-- Feature: Dominó Duo — Auditoria de Segurança, Autorização Estrita,
--          Proteção de Mãos/Monte e Hardening de Regras de Compra e Passagem
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. RPC: get_match_snapshot_for_player (Auditoria de Autorização & Privacidade)
-- ----------------------------------------------------------------------------
-- REQUISITOS OBRIGATÓRIOS:
-- - Rejeitar usuários não autenticados (P0001).
-- - Rejeitar usuários que não pertençam à partida (P0003).
-- - Confirmar autorização antes de retornar qualquer dado da partida.
-- - Durante fases ativas (in_progress), expor apenas myHand, contagens de peças
--   (handsCount) e contagem do monte (boneyardCount).
-- - Revelar o estado completo com todas as mãos apenas após a finalização.
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

-- ----------------------------------------------------------------------------
-- 2. Validador Server-Side Hardened de Regras do Dominó (validate_domino_action)
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
    v_lowest_count INTEGER := 999999;
    v_player_sum INTEGER;
    v_player_count INTEGER;
    v_tie_blocked BOOLEAN := false;
    v_scores JSONB;
    v_team_scores JSONB;
    v_new_state JSONB;
    v_valid_moves_exist BOOLEAN := false;
    p_idx INTEGER;
    v_team_a_sum INTEGER := 0;
    v_team_b_sum INTEGER := 0;
    v_winning_team TEXT := null;
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
        -- Tabuleiro vazio: se tiver peças na mão, pode jogar
        IF jsonb_array_length(v_player_hand) > 0 THEN
            v_valid_moves_exist := true;
        END IF;
    ELSE
        -- Tabuleiro com peças: verifica se alguma peça conecta nas pontas
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
            v_t1 := (v_tile_elem->>0)::int;
            v_t2 := (v_tile_elem->>1)::int;
            IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                v_valid_moves_exist := true;
                EXIT;
            END IF;
        END LOOP;
    END IF;

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
                v_has_tile := true;
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

        -- Checar vitória por descarte completo (Bateu!)
        IF v_rem_hand_len = 0 THEN
            v_is_finished := true;
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

            -- Se for modo de duplas 2v2 (P1 & P3 = Team A, P2 & P4 = Team B)
            IF v_team_mode = 'teams_2v2' AND v_num_players = 4 THEN
                IF p_player_id = v_turn_order[1] OR p_player_id = v_turn_order[3] THEN
                    v_team_scores := v_team_scores || jsonb_build_object('teamA', COALESCE((v_team_scores->>'teamA')::int, 0) + v_round_points);
                    v_winning_team := 'teamA';
                ELSE
                    v_team_scores := v_team_scores || jsonb_build_object('teamB', COALESCE((v_team_scores->>'teamB')::int, 0) + v_round_points);
                    v_winning_team := 'teamB';
                END IF;
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

        -- REQUISITO 4: Permitir compra APENAS quando o jogador NÃO possui jogadas válidas na mão
        IF v_valid_moves_exist THEN
            RAISE EXCEPTION 'CANNOT_DRAW_WITH_VALID_MOVES: Você já possui peças jogáveis na mão e não pode comprar.' USING ERRCODE = 'P0082';
        END IF;

        -- Retira primeira peça do monte (boneyard)
        v_drawn_tile := v_boneyard->0;
        v_boneyard := v_boneyard - 0;

        -- Adiciona à mão do jogador
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
        -- 1. REQUISITO 4: Não permitir passar se possuir jogadas válidas na mão
        IF v_valid_moves_exist THEN
            RAISE EXCEPTION 'CANNOT_PASS_WITH_VALID_MOVES: Você possui peças jogáveis e não pode passar a vez.' USING ERRCODE = 'P0079';
        END IF;

        -- 2. REQUISITO 4: Não permitir passar se ainda puder comprar no monte
        v_boneyard_len := jsonb_array_length(v_boneyard);
        IF v_boneyard_len > 0 THEN
            IF v_draw_rule = 'open' THEN
                RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar peças do monte até conseguir jogar ou esvaziar o monte.' USING ERRCODE = 'P0080';
            ELSIF v_draw_rule = 'one_tile' AND v_draws_this_turn < 1 THEN
                RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar a peça do turno antes de passar.' USING ERRCODE = 'P0080';
            ELSIF v_draw_rule = 'custom_limit' AND v_draws_this_turn < v_max_draws THEN
                RAISE EXCEPTION 'MUST_DRAW_BEFORE_PASS: Você deve comprar peças até o limite configurado antes de passar.' USING ERRCODE = 'P0080';
            END IF;
        END IF;

        -- Passagem válida: incrementa passes consecutivos
        v_consecutive_passes := v_consecutive_passes + 1;

        -- 3. REQUISITO 4: Tratar encerramento por trancamento (blocked game / fecha)
        -- Ocorre quando todos os jogadores passaram consecutivamente
        IF v_consecutive_passes >= v_num_players THEN
            v_is_finished := true;
            v_finish_reason := 'blocked';

            IF v_block_rule = 'draw' THEN
                -- Regra: Empate direto
                v_winner_id := NULL;
                v_is_draw := true;
            ELSIF v_team_mode = 'teams_2v2' AND v_num_players = 4 THEN
                -- Desempate em Duplas 2v2: soma de Team A vs Team B
                v_team_a_sum := 0;
                v_team_b_sum := 0;

                -- P1 e P3 são Team A
                FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_turn_order[1]::text) LOOP
                    v_team_a_sum := v_team_a_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                END LOOP;
                FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_turn_order[3]::text) LOOP
                    v_team_a_sum := v_team_a_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                END LOOP;

                -- P2 e P4 são Team B
                FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_turn_order[2]::text) LOOP
                    v_team_b_sum := v_team_b_sum + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                END LOOP;
                FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_hands->v_turn_order[4]::text) LOOP
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
                -- Desempate Individual por menor soma de pontos (lowest_pip_count)
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
        END IF;

        v_new_state := p_current_state || jsonb_build_object(
            'currentTurnPlayerId', CASE WHEN v_is_finished THEN v_current_turn_player_id ELSE v_next_player_id END,
            'drawsThisTurn', 0,
            'consecutivePasses', v_consecutive_passes,
            'isBlocked', (v_finish_reason = 'blocked'),
            'scores', v_scores,
            'teamScores', v_team_scores,
            'isFinished', v_is_finished,
            'winnerId', v_winner_id,
            'winnerTeam', v_winning_team,
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

REVOKE ALL ON FUNCTION public.validate_domino_action(UUID, UUID, VARCHAR, JSONB, JSONB, INTEGER) FROM PUBLIC, anon, authenticated;

-- ----------------------------------------------------------------------------
-- 3. Atualizar timeout_match_turn com Suporte Robusto a Dominó Duo
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
    v_next_turn_player_id UUID;
    v_timed_out_player_id UUID;
    v_turn_timer INTEGER;
    v_new_deadline TIMESTAMPTZ;
    v_new_action_history JSONB;
    v_envelope JSONB;
    v_new_state JSONB;
    v_turn_order UUID[];
    v_direction INTEGER := 1;
    v_deck TEXT[];
    v_discard_pile TEXT[];
    v_hands JSONB;
    v_hand_cards TEXT[];
    v_draw_card TEXT;
    v_num_players INTEGER;
    v_cur_idx INTEGER;
    v_next_idx INTEGER;
    v_consecutive_passes INTEGER;
    v_is_finished BOOLEAN := false;
BEGIN
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHORIZED: Usuário não autenticado.' USING ERRCODE = 'P0001';
    END IF;

    -- 1. Trava transacional exclusiva da partida
    SELECT * INTO v_match
    FROM public.matches
    WHERE id = p_match_id
    FOR UPDATE;

    IF NOT FOUND THEN
        RAISE EXCEPTION 'MATCH_NOT_FOUND: Partida não encontrada.' USING ERRCODE = 'P0016';
    END IF;

    -- Se a partida já estiver finalizada
    IF v_match.status != 'in_progress' THEN
        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object('match_id', v_match.id, 'status', v_match.status, 'idempotent', true),
            'error', null
        );
    END IF;

    -- Validar que o usuário autenticado participa da partida
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

        v_new_state := v_new_state || jsonb_build_object(
            'currentTurnPlayerId', v_next_turn_player_id,
            'drawsThisTurn', 0,
            'consecutivePasses', v_consecutive_passes
        );

    ELSE
        -- Tic-Tac-Toe ou genérico: passa o turno para o oponente seguinte
        SELECT user_id INTO v_next_turn_player_id
        FROM public.match_players
        WHERE match_id = p_match_id AND user_id != v_timed_out_player_id
        ORDER BY slot ASC
        LIMIT 1;

        v_new_state := v_new_state || jsonb_build_object('currentTurnPlayerId', v_next_turn_player_id);
    END IF;

    -- 5. Registrar no histórico de ações oficiais
    v_envelope := jsonb_build_object(
        'action_id', gen_random_uuid()::text,
        'turn_number', v_match.turn_number,
        'player_id', v_timed_out_player_id,
        'action_type', 'timeout_turn',
        'payload', '{}'::jsonb,
        'server_timestamp', clock_timestamp()
    );
    v_new_action_history := v_match.action_history || jsonb_build_array(v_envelope);

    -- 6. Atualizar a partida oficialmente no PostgreSQL
    UPDATE public.matches SET
        game_state = v_new_state,
        action_history = v_new_action_history,
        turn_number = v_match.turn_number + 1,
        current_turn_player_id = v_next_turn_player_id,
        turn_deadline = v_new_deadline,
        updated_at = now()
    WHERE id = p_match_id
    RETURNING * INTO v_match;

    RETURN jsonb_build_object(
        'success', true,
        'data', jsonb_build_object(
            'match_id', v_match.id,
            'turn_number', v_match.turn_number,
            'current_turn_player_id', v_match.current_turn_player_id,
            'turn_deadline', v_match.turn_deadline
        ),
        'error', null
    );
END;
$$;

REVOKE ALL ON FUNCTION public.timeout_match_turn(UUID, INTEGER) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.timeout_match_turn(UUID, INTEGER) TO authenticated;
