-- ============================================================================
-- Migration: 20261012180000_fix_matchmaking_v_my_entry_unassigned.sql
-- Project: DuoPlay-Online
-- Feature: Correção Definitiva do Erro 'record v_my_entry is not assigned yet'
--          ao Iniciar Busca no Matchmaking
-- ============================================================================

-- ----------------------------------------------------------------------------
-- RPC: join_matchmaking_queue
-- Garante:
-- 1. Declaração explícita de v_my_entry com %ROWTYPE (public.matchmaking_queue%ROWTYPE)
--    e v_game com %ROWTYPE (public.games%ROWTYPE) para evitar exceções de acesso a RECORD não-atribuído.
-- 2. Tratamento seguro quando o usuário não possui entrada prévia na fila (reconcile retorna NULL).
-- 3. Inicialização e distribuição autoritativa de peças para Domino Duo, Carta Duo, Snake e Tic-Tac-Toe.
-- 4. Inserção ou atualização atômica da entrada na fila com retorno garantido.
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

    -- Se o usuário já possuir entrada ativa reconciliada e ela já estiver pareada (matched):
    IF v_my_entry.id IS NOT NULL THEN
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
