-- ============================================================================
-- Migration: 20261012170000_domino_duo_matchmaking_and_winner_hardening.sql
-- Project: DuoPlay-Online
-- Feature: Dominó Duo — Correção Definitiva de Matchmaking e Distribuição de Peças
--          + Correção da Escrita Não-Nula em match_players.is_winner
-- ============================================================================

-- ----------------------------------------------------------------------------
-- 1. Atualizar RPC join_matchmaking_queue com Inicialização Autoritativa do Dominó
-- Garante que partidas de Dominó pareadas via matchmaking distribuam as peças
-- dos jogadores e o monte inicial exatamente como o fluxo de salas privadas.
-- ----------------------------------------------------------------------------
CREATE OR REPLACE FUNCTION public.join_matchmaking_queue(
    p_game_id VARCHAR(50)
)
RETURNS JSONB
LANGUAGE plpgsql
SECURITY DEFINER
SET search_path = public, pg_temp
AS $$
DECLARE
    v_caller_id UUID;
    v_norm_game_id VARCHAR(50);
    v_game public.games%ROWTYPE;
    v_my_entry public.matchmaking_queue%ROWTYPE;
    v_opponent_queue_ids UUID[] := ARRAY[]::uuid[];
    v_opponent_user_ids UUID[] := ARRAY[]::uuid[];
    v_valid_opponent_queue_ids UUID[] := ARRAY[]::uuid[];
    v_valid_opponent_user_ids UUID[] := ARRAY[]::uuid[];
    v_opponents_count INTEGER;
    v_total_players INTEGER;
    v_all_user_ids UUID[] := ARRAY[]::uuid[];
    v_new_match_id UUID;
    v_initial_game_state JSONB;
    v_first_player_id UUID;
    v_config JSONB;
    v_u_id UUID;
    v_opp_user_id UUID;
    v_opp_q_id UUID;
    v_is_opp_valid BOOLEAN;
    v_i INTEGER;
    i INTEGER;
BEGIN
    v_caller_id := auth.uid();
    IF v_caller_id IS NULL THEN
        RAISE EXCEPTION 'UNAUTHENTICATED: Apenas usuários autenticados podem entrar na fila.' USING ERRCODE = 'P0001';
    END IF;

    -- Trava transacional primária para o chamador
    PERFORM pg_advisory_xact_lock(hashtext(v_caller_id::text));

    -- Auto-limpeza de partidas in_progress obsoletas/abandonadas (> 2 horas)
    UPDATE public.matches
    SET status = 'finished', finish_reason = 'timeout', updated_at = clock_timestamp()
    WHERE status = 'in_progress'
      AND started_at < (clock_timestamp() - INTERVAL '2 hours')
      AND id IN (
          SELECT match_id FROM public.match_players WHERE user_id = v_caller_id
      );

    -- Bloqueio se o jogador já estiver em alguma partida 'in_progress' ativa
    IF EXISTS (
        SELECT 1 FROM public.match_players mp
        JOIN public.matches m ON m.id = mp.match_id
        WHERE mp.user_id = v_caller_id AND m.status = 'in_progress'
    ) THEN
        RETURN jsonb_build_object(
            'success', false,
            'error', 'Você possui uma partida em andamento. Conclua-a antes de buscar outra.',
            'code', 'ACTIVE_MATCH_EXISTS'
        );
    END IF;

    -- Normalização e validação no catálogo de jogos
    v_norm_game_id := replace(p_game_id, '-', '_');
    SELECT * INTO v_game FROM public.games WHERE id = v_norm_game_id AND is_active = true;
    IF NOT FOUND OR v_game.id IS NULL THEN
        RAISE EXCEPTION 'GAME_NOT_ACTIVE: O jogo especificado não existe ou não possui matchmaking público ativo.' USING ERRCODE = 'P0015';
    END IF;

    -- Limpar filas expiradas globalmente para manter sanidade
    DELETE FROM public.matchmaking_queue WHERE expires_at < clock_timestamp();

    -- Reconciliar fila específica deste usuário para este jogo
    v_my_entry := public.reconcile_user_matchmaking_queue(v_caller_id, v_game.id);

    IF v_my_entry.id IS NOT NULL THEN
        -- Se já estiver matched para este jogo
        IF v_my_entry.status = 'matched' AND v_my_entry.match_id IS NOT NULL THEN
            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'queue_id', v_my_entry.id,
                    'game_id', v_my_entry.game_id,
                    'status', 'matched',
                    'match_id', v_my_entry.match_id,
                    'expires_at', v_my_entry.expires_at
                ),
                'error', null
            );
        END IF;
    END IF;

    -- Buscar oponentes candidatos na mesma fila (mesmo game_id)
    -- Filtra oponentes que comprovadamente já estejam em partida in_progress ou com fila 'matched'
    SELECT 
        coalesce(array_agg(sub.id), ARRAY[]::uuid[]),
        coalesce(array_agg(sub.user_id), ARRAY[]::uuid[])
    INTO v_opponent_queue_ids, v_opponent_user_ids
    FROM (
        SELECT q.id, q.user_id
        FROM public.matchmaking_queue q
        WHERE q.game_id = v_game.id
          AND q.status = 'waiting'
          AND q.user_id != v_caller_id
          AND clock_timestamp() < q.expires_at
          AND NOT EXISTS (
              SELECT 1 FROM public.match_players mp
              JOIN public.matches m ON m.id = mp.match_id
              WHERE mp.user_id = q.user_id AND m.status = 'in_progress'
          )
          AND NOT EXISTS (
              SELECT 1 FROM public.matchmaking_queue mq_other
              WHERE mq_other.user_id = q.user_id
                AND mq_other.status = 'matched'
          )
        ORDER BY q.created_at ASC
        LIMIT (v_game.max_players - 1)
        FOR UPDATE SKIP LOCKED
    ) sub;

    -- ========================================================================
    -- PROTEÇÃO ATÔMICA MULTIJOGO CONTRA RACE CONDITIONS QUASE SIMULTÂNEAS
    -- ========================================================================
    IF (cardinality(v_opponent_user_ids) + 1) >= v_game.min_players THEN
        v_all_user_ids := array_append(v_opponent_user_ids, v_caller_id);

        -- Adquire advisory locks de todos os jogadores em ordem determinística
        FOR v_u_id IN (
            SELECT DISTINCT unnest(v_all_user_ids) ORDER BY 1
        ) LOOP
            PERFORM pg_advisory_xact_lock(hashtext(v_u_id::text));
        END LOOP;

        -- Re-validação estrita sob a trava de todos os oponentes candidatos:
        FOR v_i IN 1..cardinality(v_opponent_user_ids) LOOP
            v_opp_user_id := v_opponent_user_ids[v_i];
            v_opp_q_id := v_opponent_queue_ids[v_i];
            v_is_opp_valid := true;

            -- 1. O oponente ainda tem esta fila específica como 'waiting'?
            IF NOT EXISTS (
                SELECT 1 FROM public.matchmaking_queue
                WHERE id = v_opp_q_id AND status = 'waiting' AND expires_at > clock_timestamp()
            ) THEN
                v_is_opp_valid := false;
            END IF;

            -- 2. O oponente tem alguma outra fila 'matched'?
            IF v_is_opp_valid AND EXISTS (
                SELECT 1 FROM public.matchmaking_queue
                WHERE user_id = v_opp_user_id AND status = 'matched'
            ) THEN
                v_is_opp_valid := false;
            END IF;

            -- 3. O oponente entrou em alguma partida in_progress no ínterim?
            IF v_is_opp_valid AND EXISTS (
                SELECT 1 FROM public.match_players mp
                JOIN public.matches m ON m.id = mp.match_id
                WHERE mp.user_id = v_opp_user_id AND m.status = 'in_progress'
            ) THEN
                v_is_opp_valid := false;
            END IF;

            IF v_is_opp_valid THEN
                v_valid_opponent_queue_ids := array_append(v_valid_opponent_queue_ids, v_opp_q_id);
                v_valid_opponent_user_ids := array_append(v_valid_opponent_user_ids, v_opp_user_id);
            END IF;
        END LOOP;

        v_opponents_count := cardinality(v_valid_opponent_user_ids);
        v_total_players := v_opponents_count + 1;
    ELSE
        v_valid_opponent_queue_ids := ARRAY[]::uuid[];
        v_valid_opponent_user_ids := ARRAY[]::uuid[];
        v_total_players := 1;
    END IF;

    -- Se após re-validação atômica ainda temos o número mínimo de jogadores: CRIA A PARTIDA!
    IF v_total_players >= v_game.min_players THEN
        v_new_match_id := gen_random_uuid();
        v_all_user_ids := array_append(v_valid_opponent_user_ids, v_caller_id);
        v_first_player_id := v_all_user_ids[1];
        v_config := coalesce(v_game.config, '{}'::jsonb);

        -- Inicialização autoritativa para cada jogo
        IF v_game.id = 'carta_duo' OR v_game.id = 'carta-duo' THEN
            v_initial_game_state := public.initialize_carta_duo_state_for_players(v_all_user_ids, v_config);
            v_first_player_id := (v_initial_game_state->>'current_turn_player_id')::uuid;
        ELSIF v_game.id = 'domino' THEN
            -- CORREÇÃO CRÍTICA: Distribuição autoritativa de peças para Dominó no Matchmaking
            v_initial_game_state := public.initialize_domino_state_for_players(v_all_user_ids, v_config);
            v_first_player_id := (v_initial_game_state->>'currentTurnPlayerId')::uuid;
        ELSIF v_game.id = 'snake' THEN
            v_initial_game_state := public.initialize_snake_state_for_players(v_all_user_ids, v_config);
            v_first_player_id := NULL;
        ELSE
            v_initial_game_state := jsonb_build_object('config', v_config);
        END IF;

        -- Inserir partida autoritativa
        INSERT INTO public.matches (
            id, room_id, game_id, status, current_turn_player_id,
            turn_deadline, turn_number, game_state, action_history, config, created_at, started_at
        ) VALUES (
            v_new_match_id, NULL, v_game.id, 'in_progress', v_first_player_id,
            CASE WHEN v_game.id = 'snake' THEN NULL ELSE clock_timestamp() + (COALESCE((v_config->>'turn_timer')::INTEGER, 30) || ' seconds')::INTERVAL END,
            1, v_initial_game_state, '[]'::jsonb, v_config,
            clock_timestamp(), clock_timestamp()
        );

        -- Inserir participantes com is_winner explicitamente false (NOT NULL)
        FOR i IN 1..cardinality(v_all_user_ids) LOOP
            INSERT INTO public.match_players (
                match_id, user_id, slot, game_symbol, score, is_winner, joined_at
            ) VALUES (
                v_new_match_id, v_all_user_ids[i], i, NULL, 0, false, clock_timestamp()
            );
        END LOOP;

        -- Atualizar status da fila deste jogo para 'matched' para os oponentes
        UPDATE public.matchmaking_queue
        SET status = 'matched', match_id = v_new_match_id, updated_at = clock_timestamp()
        WHERE id = ANY(v_valid_opponent_queue_ids);

        -- Atualizar ou inserir entrada do chamador como 'matched'
        IF v_my_entry.id IS NOT NULL THEN
            UPDATE public.matchmaking_queue
            SET status = 'matched', match_id = v_new_match_id, updated_at = clock_timestamp()
            WHERE id = v_my_entry.id
            RETURNING * INTO v_my_entry;
        ELSE
            INSERT INTO public.matchmaking_queue (
                user_id, game_id, status, match_id, expires_at
            ) VALUES (
                v_caller_id, v_game.id, 'matched', v_new_match_id, clock_timestamp() + INTERVAL '5 minutes'
            )
            ON CONFLICT (user_id, game_id) WHERE status IN ('waiting', 'matched')
            DO UPDATE SET status = 'matched', match_id = v_new_match_id, updated_at = clock_timestamp()
            RETURNING * INTO v_my_entry;
        END IF;

        -- Cancelar automaticamente outras filas 'waiting' de todos os jogadores pareados
        FOREACH v_u_id IN ARRAY v_all_user_ids LOOP
            UPDATE public.matchmaking_queue
            SET status = 'cancelled', updated_at = clock_timestamp()
            WHERE user_id = v_u_id
              AND status = 'waiting'
              AND game_id != v_game.id;
        END LOOP;

        RETURN jsonb_build_object(
            'success', true,
            'data', jsonb_build_object(
                'queue_id', v_my_entry.id,
                'game_id', v_game.id,
                'status', 'matched',
                'match_id', v_new_match_id,
                'expires_at', v_my_entry.expires_at
            ),
            'error', null
        );

    ELSE
        -- Menos jogadores que o mínimo: permanecer ou entrar em 'waiting' para este jogo
        IF v_my_entry.id IS NOT NULL AND v_my_entry.status = 'waiting' THEN
            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'queue_id', v_my_entry.id,
                    'game_id', v_my_entry.game_id,
                    'status', 'waiting',
                    'match_id', null,
                    'expires_at', v_my_entry.expires_at
                ),
                'error', null
            );
        ELSE
            INSERT INTO public.matchmaking_queue (
                user_id, game_id, status, expires_at
            ) VALUES (
                v_caller_id, v_game.id, 'waiting', clock_timestamp() + INTERVAL '5 minutes'
            )
            ON CONFLICT (user_id, game_id) WHERE status IN ('waiting', 'matched')
            DO UPDATE SET status = 'waiting', match_id = null, expires_at = clock_timestamp() + INTERVAL '5 minutes', updated_at = clock_timestamp()
            RETURNING * INTO v_my_entry;

            RETURN jsonb_build_object(
                'success', true,
                'data', jsonb_build_object(
                    'queue_id', v_my_entry.id,
                    'game_id', v_my_entry.game_id,
                    'status', 'waiting',
                    'match_id', null,
                    'expires_at', v_my_entry.expires_at
                ),
                'error', null
            );
        END IF;
    END IF;
END;
$$;

REVOKE ALL ON FUNCTION public.join_matchmaking_queue(VARCHAR) FROM PUBLIC, anon;
GRANT EXECUTE ON FUNCTION public.join_matchmaking_queue(VARCHAR) TO authenticated;

-- ----------------------------------------------------------------------------
-- 2. Endurecimento contra Escrita NULL em match_players.is_winner
-- Atualiza validate_domino_action e timeout_match_turn para garantir que
-- `is_winner = COALESCE(user_id = v_winner_id, false)` ou `(v_winner_id IS NOT NULL AND user_id = v_winner_id)`.
-- ----------------------------------------------------------------------------

-- Em validate_domino_action:
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
        RAISE EXCEPTION 'NOT_YOUR_TURN: Não é o seu turno para realizar jogadas.' USING ERRCODE = 'P0071';
    END IF;

    -- Extrair a mão do jogador atual
    v_player_hand := COALESCE(v_hands->(p_player_id::text), '[]'::jsonb);

    -- ========================================================================
    -- AÇÃO 1: play_tile (Jogar Peça no Tabuleiro)
    -- ========================================================================
    IF p_action_type = 'play_tile' THEN
        v_play_tile := p_payload->'tile';
        v_side := COALESCE(p_payload->>'side', 'left');

        IF v_play_tile IS NULL OR jsonb_array_length(v_play_tile) != 2 THEN
            RAISE EXCEPTION 'INVALID_TILE_FORMAT: Formato inválido de peça de dominó.' USING ERRCODE = 'P0072';
        END IF;

        v_t1 := (v_play_tile->>0)::integer;
        v_t2 := (v_play_tile->>1)::integer;

        -- Verificar posse da peça na mão
        v_new_player_hand := ARRAY[]::jsonb[];
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

        -- Tabuleiro Vazio: Primeira jogada
        IF jsonb_array_length(v_tiles) = 0 THEN
            v_new_left_end := v_t1;
            v_new_right_end := v_t2;
            v_new_placed_tile := jsonb_build_object(
                'tile', jsonb_build_array(v_t1, v_t2),
                'playedBy', p_player_id,
                'end', 'center'
            );
            v_new_board_tiles := jsonb_build_array(v_new_placed_tile);
        ELSE
            IF v_side = 'left' THEN
                IF v_t2 = v_left_end THEN
                    v_new_left_end := v_t1;
                    v_new_right_end := v_right_end;
                    v_new_placed_tile := jsonb_build_object(
                        'tile', jsonb_build_array(v_t1, v_t2),
                        'playedBy', p_player_id,
                        'end', 'left'
                    );
                ELSIF v_t1 = v_left_end THEN
                    v_new_left_end := v_t2;
                    v_new_right_end := v_right_end;
                    v_new_placed_tile := jsonb_build_object(
                        'tile', jsonb_build_array(v_t2, v_t1),
                        'playedBy', p_player_id,
                        'end', 'left'
                    );
                ELSE
                    RAISE EXCEPTION 'ILLEGAL_DOMINO_MOVE: A peça [%, %] não conecta na ponta esquerda (%).', v_t1, v_t2, v_left_end USING ERRCODE = 'P0074';
                END IF;
                v_new_board_tiles := jsonb_build_array(v_new_placed_tile) || v_tiles;
            ELSE
                IF v_t1 = v_right_end THEN
                    v_new_right_end := v_t2;
                    v_new_left_end := v_left_end;
                    v_new_placed_tile := jsonb_build_object(
                        'tile', jsonb_build_array(v_t1, v_t2),
                        'playedBy', p_player_id,
                        'end', 'right'
                    );
                ELSIF v_t2 = v_right_end THEN
                    v_new_right_end := v_t1;
                    v_new_left_end := v_left_end;
                    v_new_placed_tile := jsonb_build_object(
                        'tile', jsonb_build_array(v_t2, v_t1),
                        'playedBy', p_player_id,
                        'end', 'right'
                    );
                ELSE
                    RAISE EXCEPTION 'ILLEGAL_DOMINO_MOVE: A peça [%, %] não conecta na ponta direita (%).', v_t1, v_t2, v_right_end USING ERRCODE = 'P0074';
                END IF;
                v_new_board_tiles := v_tiles || jsonb_build_array(v_new_placed_tile);
            END IF;
        END IF;

        -- Atualizar mãos
        v_hands := v_hands || jsonb_build_object(p_player_id::text, to_jsonb(v_new_player_hand));
        v_rem_hand_len := cardinality(v_new_player_hand);

        -- Verificar Batida Normal (Dominó esvaziou a mão)
        IF v_rem_hand_len = 0 THEN
            v_winner_id := p_player_id;
            v_finish_reason := 'normal';

            -- Calcular pontuação da rodada
            v_round_points := 0;
            FOR v_other_pid IN SELECT jsonb_object_keys(v_hands) LOOP
                IF v_other_pid != p_player_id::text THEN
                    v_other_hand := v_hands->v_other_pid;
                    FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_other_hand) LOOP
                        v_round_points := v_round_points + (v_tile_elem->>0)::int + (v_tile_elem->>1)::int;
                    END LOOP;
                END IF;
            END LOOP;

            -- Aplicar pontuação
            IF v_team_mode = 'teams_2v2' AND v_num_players = 4 THEN
                IF p_player_id IN (v_turn_order[1], v_turn_order[3]) THEN
                    v_winning_team := 'teamA';
                    v_team_scores := v_team_scores || jsonb_build_object('teamA', COALESCE((v_team_scores->>'teamA')::int, 0) + v_round_points);
                ELSE
                    v_winning_team := 'teamB';
                    v_team_scores := v_team_scores || jsonb_build_object('teamB', COALESCE((v_team_scores->>'teamB')::int, 0) + v_round_points);
                END IF;
            END IF;

            v_scores := v_scores || jsonb_build_object(p_player_id::text, COALESCE((v_scores->>p_player_id::text)::int, 0) + v_round_points);

            -- Condição de encerramento da partida
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

            v_next_player_id := NULL;

        ELSE
            -- Jogo continua: avançar turno para o próximo jogador
            v_next_idx := 1;
            FOR i IN 1..v_num_players LOOP
                IF v_turn_order[i] = p_player_id THEN
                    v_next_idx := (i % v_num_players) + 1;
                    EXIT;
                END IF;
            END LOOP;
            v_next_player_id := v_turn_order[v_next_idx];
            v_is_finished := false;
        END IF;

        v_new_state := p_current_state || jsonb_build_object(
            'board', jsonb_build_object(
                'tiles', v_new_board_tiles,
                'leftEnd', v_new_left_end,
                'rightEnd', v_new_right_end
            ),
            'hands', v_hands,
            'currentTurnPlayerId', v_next_player_id,
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

        -- Atualizar pontuação e is_winner no match_players (garantia NOT NULL)
        UPDATE public.match_players
        SET score = COALESCE((v_scores->>user_id::text)::int, 0),
            is_winner = (v_winner_id IS NOT NULL AND user_id = v_winner_id)
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
        IF v_draw_rule = 'no_draw' THEN
            RAISE EXCEPTION 'DRAW_NOT_ALLOWED: A regra da partida não permite compras no monte.' USING ERRCODE = 'P0075';
        END IF;

        IF jsonb_array_length(v_tiles) > 0 THEN
            FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
                v_t1 := (v_tile_elem->>0)::int;
                v_t2 := (v_tile_elem->>1)::int;
                IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                    v_valid_moves_exist := true;
                    EXIT;
                END IF;
            END LOOP;

            IF v_valid_moves_exist THEN
                RAISE EXCEPTION 'CANNOT_DRAW_WITH_VALID_MOVES: Você possui peças jogáveis na sua mão. Não é permitido comprar.' USING ERRCODE = 'P0082';
            END IF;
        END IF;

        v_boneyard_len := jsonb_array_length(v_boneyard);
        IF v_boneyard_len = 0 THEN
            RAISE EXCEPTION 'BONEYARD_EMPTY: O monte de compras está vazio.' USING ERRCODE = 'P0076';
        END IF;

        IF v_draw_rule = 'one_tile' AND v_draws_this_turn >= 1 THEN
            RAISE EXCEPTION 'MAX_DRAWS_REACHED: Regra permite comprar apenas 1 peça por turno.' USING ERRCODE = 'P0077';
        END IF;

        IF v_draw_rule = 'custom_limit' AND v_draws_this_turn >= v_max_draws THEN
            RAISE EXCEPTION 'MAX_DRAWS_REACHED: Limite de compras atingido para este turno.' USING ERRCODE = 'P0077';
        END IF;

        v_drawn_tile := v_boneyard->0;
        v_t1 := (v_drawn_tile->>0)::int;
        v_t2 := (v_drawn_tile->>1)::int;

        v_new_player_hand := ARRAY[]::jsonb[];
        FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
            v_new_player_hand := array_append(v_new_player_hand, v_tile_elem);
        END LOOP;
        v_new_player_hand := array_append(v_new_player_hand, v_drawn_tile);
        v_hands := v_hands || jsonb_build_object(p_player_id::text, to_jsonb(v_new_player_hand));

        v_boneyard := jsonb_path_query_array(v_boneyard, '$[1 to last]');
        IF v_boneyard IS NULL THEN
            v_boneyard := '[]'::jsonb;
        END IF;

        IF jsonb_array_length(v_tiles) = 0 THEN
            v_drawn_playable := true;
        ELSE
            IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                v_drawn_playable := true;
            END IF;
        END IF;

        IF v_play_immediately = false THEN
            v_next_idx := 1;
            FOR i IN 1..v_num_players LOOP
                IF v_turn_order[i] = p_player_id THEN
                    v_next_idx := (i % v_num_players) + 1;
                    EXIT;
                END IF;
            END LOOP;
            v_next_player_id := v_turn_order[v_next_idx];
            v_draws_this_turn := 0;
        ELSE
            v_next_player_id := p_player_id;
            v_draws_this_turn := v_draws_this_turn + 1;
        END IF;

        v_new_state := p_current_state || jsonb_build_object(
            'boneyard', v_boneyard,
            'hands', v_hands,
            'currentTurnPlayerId', v_next_player_id,
            'drawsThisTurn', v_draws_this_turn,
            'consecutivePasses', 0,
            'lastAction', jsonb_build_object(
                'type', 'draw',
                'playerId', p_player_id,
                'tilePlayable', v_drawn_playable
            )
        );

        RETURN jsonb_build_object(
            'accepted', true,
            'new_state', v_new_state,
            'next_player_id', v_next_player_id,
            'drawn_tile', v_drawn_tile,
            'tile_playable', v_drawn_playable
        );

    -- ========================================================================
    -- AÇÃO 3: pass_turn (Passar a Vez)
    -- ========================================================================
    ELSIF p_action_type = 'pass_turn' THEN
        IF jsonb_array_length(v_tiles) > 0 THEN
            FOR v_tile_elem IN SELECT * FROM jsonb_array_elements(v_player_hand) LOOP
                v_t1 := (v_tile_elem->>0)::int;
                v_t2 := (v_tile_elem->>1)::int;
                IF v_t1 = v_left_end OR v_t2 = v_left_end OR v_t1 = v_right_end OR v_t2 = v_right_end THEN
                    v_valid_moves_exist := true;
                    EXIT;
                END IF;
            END LOOP;

            IF v_valid_moves_exist THEN
                RAISE EXCEPTION 'CANNOT_PASS_WITH_VALID_MOVES: Você possui peças jogáveis na sua mão. Não é permitido passar a vez.' USING ERRCODE = 'P0079';
            END IF;
        END IF;

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

        v_consecutive_passes := v_consecutive_passes + 1;

        -- Trancamento completo de rodada
        IF v_consecutive_passes >= v_num_players THEN
            v_blocked_res := public.resolve_domino_blocked_round(
                p_current_state || jsonb_build_object(
                    'consecutivePasses', v_consecutive_passes,
                    'drawsThisTurn', 0
                )
            );

            v_new_state := v_blocked_res->'new_state';
            v_is_finished := (v_blocked_res->>'is_finished')::boolean;
            v_winner_id := (v_blocked_res->>'winner_id')::uuid;
            v_winning_team := v_blocked_res->>'winning_team';
            v_is_draw := (v_blocked_res->>'is_draw')::boolean;
            v_finish_reason := v_blocked_res->>'finish_reason';
            v_scores := v_blocked_res->'scores';
            v_team_scores := v_blocked_res->'team_scores';

            IF NOT v_is_finished AND v_scoring_mode = 'target_score' THEN
                v_new_state := public.start_domino_next_round(v_new_state, v_winner_id);
                v_next_player_id := (v_new_state->>'currentTurnPlayerId')::uuid;
            ELSE
                v_next_player_id := NULL;
            END IF;

        ELSE
            v_next_idx := 1;
            FOR i IN 1..v_num_players LOOP
                IF v_turn_order[i] = p_player_id THEN
                    v_next_idx := (i % v_num_players) + 1;
                    EXIT;
                END IF;
            END LOOP;
            v_next_player_id := v_turn_order[v_next_idx];
            v_is_finished := false;

            v_new_state := p_current_state || jsonb_build_object(
                'currentTurnPlayerId', v_next_player_id,
                'drawsThisTurn', 0,
                'consecutivePasses', v_consecutive_passes,
                'isBlocked', false,
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

        -- Atualizar pontuação e is_winner no match_players (garantia NOT NULL)
        UPDATE public.match_players
        SET score = COALESCE((v_scores->>user_id::text)::int, 0),
            is_winner = (v_winner_id IS NOT NULL AND user_id = v_winner_id)
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

-- Em timeout_match_turn:
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
        v_turn_order := ARRAY(SELECT jsonb_array_elements_text(v_new_state->'turnOrder')::uuid);
        v_num_players := array_length(v_turn_order, 1);
        IF v_num_players IS NULL OR v_num_players < 2 THEN
            v_num_players := 2;
        END IF;

        v_next_idx := 1;
        FOR i IN 1..v_num_players LOOP
            IF v_turn_order[i] = v_timed_out_player_id THEN
                v_next_idx := (i % v_num_players) + 1;
                EXIT;
            END IF;
        END LOOP;
        v_next_turn_player_id := v_turn_order[v_next_idx];

        v_consecutive_passes := COALESCE((v_new_state->>'consecutivePasses')::INTEGER, 0) + 1;

        IF v_consecutive_passes >= v_num_players THEN
            v_blocked_res := public.resolve_domino_blocked_round(
                v_new_state || jsonb_build_object(
                    'consecutivePasses', v_consecutive_passes,
                    'drawsThisTurn', 0
                )
            );

            v_new_state := v_blocked_res->'new_state';
            v_is_finished := (v_blocked_res->>'is_finished')::boolean;
            v_resolved_winner_id := (v_blocked_res->>'winner_id')::uuid;
            v_resolved_is_draw := (v_blocked_res->>'is_draw')::boolean;
            v_resolved_scores := v_blocked_res->'scores';
            v_scoring_mode := COALESCE(v_match.config->>'scoring_mode', v_match.config->>'scoringMode', 'single_round');

            IF NOT v_is_finished AND v_scoring_mode = 'target_score' THEN
                v_new_state := public.start_domino_next_round(v_new_state, v_resolved_winner_id);
                v_next_turn_player_id := (v_new_state->>'currentTurnPlayerId')::uuid;
            ELSE
                v_next_turn_player_id := NULL;
            END IF;

        ELSE
            v_new_state := v_new_state || jsonb_build_object(
                'currentTurnPlayerId', v_next_turn_player_id,
                'drawsThisTurn', 0,
                'consecutivePasses', v_consecutive_passes,
                'lastAction', jsonb_build_object(
                    'type', 'timeout_pass',
                    'playerId', v_timed_out_player_id
                )
            );
        END IF;

    ELSE
        SELECT user_id INTO v_next_turn_player_id
        FROM public.match_players
        WHERE match_id = p_match_id AND user_id != v_timed_out_player_id
        ORDER BY slot ASC
        LIMIT 1;
    END IF;

    -- 5. Gravar Histórico da Ação de Timeout
    v_envelope := jsonb_build_object(
        'action_id', gen_random_uuid()::text,
        'turn_number', v_match.turn_number,
        'player_id', v_timed_out_player_id,
        'action_type', 'turn_timeout',
        'payload', jsonb_build_object(
            'timed_out_player_id', v_timed_out_player_id,
            'next_turn_player_id', v_next_turn_player_id,
            'is_blocked', v_is_finished
        ),
        'client_timestamp', clock_timestamp(),
        'server_timestamp', clock_timestamp()
    );
    v_new_action_history := v_match.action_history || jsonb_build_array(v_envelope);

    -- 6. Transição de Estado Oficial na Tabela Matches
    IF v_is_finished THEN
        UPDATE public.matches SET
            game_state = v_new_state,
            action_history = v_new_action_history,
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

        -- Atualizar pontuação e vencedor no match_players com garantia NOT NULL
        IF v_resolved_scores IS NOT NULL THEN
            UPDATE public.match_players
            SET score = COALESCE((v_resolved_scores->>user_id::text)::int, 0),
                is_winner = (v_resolved_winner_id IS NOT NULL AND user_id = v_resolved_winner_id)
            WHERE match_id = p_match_id;
        ELSIF v_resolved_winner_id IS NOT NULL THEN
            UPDATE public.match_players
            SET is_winner = (v_resolved_winner_id IS NOT NULL AND user_id = v_resolved_winner_id)
            WHERE match_id = p_match_id;
        ELSE
            UPDATE public.match_players
            SET is_winner = false
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
