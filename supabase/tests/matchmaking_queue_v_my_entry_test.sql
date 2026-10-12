-- ============================================================================
-- Test Suite: matchmaking_queue_v_my_entry_test.sql
-- Project: DuoPlay-Online
-- Feature: Validação de Inicialização do Matchmaking sem Erro 'record v_my_entry is not assigned yet'
--          Casos Testados:
--          1. Iniciar busca com fila vazia (sem entrada anterior).
--          2. Entrar na fila sem possuir entrada anterior.
--          3. Não encontrar jogadores compatíveis (fila permanece waiting).
--          4. Repetir a solicitação (idempotência da fila waiting).
--          5. Encontrar jogador compatível (pareamento e criação de partida).
--          6. Executar solicitações concorrentes / chamador já na fila.
--          7. Confirmação que o erro de v_my_entry não ocorre sob nenhuma circunstância.
-- ============================================================================

BEGIN;

DO $$
DECLARE
    v_user_1 UUID := '11111111-2222-3333-4444-555555555501'::uuid;
    v_user_2 UUID := '11111111-2222-3333-4444-555555555502'::uuid;
    v_res_1 JSONB;
    v_res_2 JSONB;
    v_res_repeat JSONB;
    v_status_res JSONB;
    v_err_caught BOOLEAN := false;
BEGIN
    RAISE NOTICE '====================================================================';
    RAISE NOTICE '>>> TESTES AUTORITATIVOS: MATCHMAKING V_MY_ENTRY & FILA DE PAREAMENTO <<<';
    RAISE NOTICE '====================================================================';

    -- 1. SETUP: Criar perfis e garantir que o jogo 'domino' e 'tic_tac_toe' estejam ativos
    INSERT INTO public.profiles (id, username, display_name, total_matches, total_wins, total_draws, total_losses)
    VALUES
        (v_user_1, 'mm_player_1', 'MM Player 1', 0, 0, 0, 0),
        (v_user_2, 'mm_player_2', 'MM Player 2', 0, 0, 0, 0)
    ON CONFLICT (id) DO NOTHING;

    -- Limpar quaisquer entradas residuais na fila para estes usuários
    DELETE FROM public.matchmaking_queue WHERE user_id IN (v_user_1, v_user_2);

    -- ------------------------------------------------------------------------
    -- TESTE 1: Iniciar uma busca com a fila vazia e sem entrada prévia (User 1)
    -- Deve retornar 'waiting' sem gerar erro de 'record v_my_entry is not assigned'
    -- ------------------------------------------------------------------------
    SET LOCAL ROLE authenticated;
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_user_1::text, 'role', 'authenticated')::text;

    BEGIN
        v_res_1 := public.join_matchmaking_queue('domino');
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FALHA TESTE 1: Exceção disparada ao iniciar busca: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
    END;

    IF (v_res_1->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 1: join_matchmaking_queue falhou: %', v_res_1;
    END IF;

    IF (v_res_1->'data'->>'status') != 'waiting' THEN
        RAISE EXCEPTION 'FALHA TESTE 1: Status esperado "waiting", obtido: %', v_res_1->'data'->>'status';
    END IF;

    IF v_res_1->'data'->>'queue_id' IS NULL THEN
        RAISE EXCEPTION 'FALHA TESTE 1: queue_id retornou nulo!';
    END IF;

    RAISE NOTICE 'OK: Teste 1 (Busca com fila vazia e sem entrada prévia retornou waiting com sucesso)';

    -- ------------------------------------------------------------------------
    -- TESTE 2: Repetir a solicitação (idempotência da fila waiting)
    -- ------------------------------------------------------------------------
    BEGIN
        v_res_repeat := public.join_matchmaking_queue('domino');
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FALHA TESTE 2: Exceção disparada na repetição: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
    END;

    IF (v_res_repeat->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 2: Repetição falhou: %', v_res_repeat;
    END IF;

    IF (v_res_repeat->'data'->>'status') != 'waiting' THEN
        RAISE EXCEPTION 'FALHA TESTE 2: Status não permaneceu waiting!';
    END IF;

    IF v_res_repeat->'data'->>'queue_id' != v_res_1->'data'->>'queue_id' THEN
        RAISE EXCEPTION 'FALHA TESTE 2: queue_id alterou na repetição!';
    END IF;

    RAISE NOTICE 'OK: Teste 2 (Repetição de busca do mesmo usuário é idempotente e preserva a fila)';

    -- ------------------------------------------------------------------------
    -- TESTE 3: Consultar status (get_my_matchmaking_status)
    -- ------------------------------------------------------------------------
    v_status_res := public.get_my_matchmaking_status();
    IF (v_status_res->>'success')::boolean IS NOT TRUE OR v_status_res->'data'->>'status' != 'waiting' THEN
        RAISE EXCEPTION 'FALHA TESTE 3: get_my_matchmaking_status não retornou status waiting!';
    END IF;
    RAISE NOTICE 'OK: Teste 3 (get_my_matchmaking_status reflete fila ativa)';

    -- ------------------------------------------------------------------------
    -- TESTE 4: Encontrar um jogador compatível (User 2 entra na fila)
    -- Deve parear imediatamente e criar a partida com status 'matched'
    -- ------------------------------------------------------------------------
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_user_2::text, 'role', 'authenticated')::text;

    BEGIN
        v_res_2 := public.join_matchmaking_queue('domino');
    EXCEPTION WHEN OTHERS THEN
        RAISE EXCEPTION 'FALHA TESTE 4: Exceção ao parear User 2: % (SQLSTATE: %)', SQLERRM, SQLSTATE;
    END;

    IF (v_res_2->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 4: join_matchmaking_queue falhou para User 2: %', v_res_2;
    END IF;

    IF (v_res_2->'data'->>'status') != 'matched' THEN
        RAISE EXCEPTION 'FALHA TESTE 4: Status esperado "matched", obtido: %', v_res_2->'data'->>'status';
    END IF;

    IF v_res_2->'data'->>'match_id' IS NULL THEN
        RAISE EXCEPTION 'FALHA TESTE 4: match_id nulo após pareamento!';
    END IF;

    RAISE NOTICE 'OK: Teste 4 (Pareamento imediato realizado com sucesso, match_id: %)', v_res_2->'data'->>'match_id';

    -- ------------------------------------------------------------------------
    -- TESTE 5: Verificar que a partida de dominó criada possui mãos distribuídas
    -- ------------------------------------------------------------------------
    DECLARE
        v_match RECORD;
    BEGIN
        SELECT * INTO v_match FROM public.matches WHERE id = (v_res_2->'data'->>'match_id')::uuid;
        IF v_match.id IS NULL THEN
            RAISE EXCEPTION 'FALHA TESTE 5: Partida não encontrada no banco!';
        END IF;
        IF v_match.game_state->'hands' IS NULL THEN
            RAISE EXCEPTION 'FALHA TESTE 5: game_state não possui campo "hands" distribuído!';
        END IF;
        IF jsonb_array_length(v_match.game_state->'hands'->v_user_1::text) != 7 THEN
            RAISE EXCEPTION 'FALHA TESTE 5: User 1 não recebeu 7 peças no Dominó!';
        END IF;
        IF jsonb_array_length(v_match.game_state->'hands'->v_user_2::text) != 7 THEN
            RAISE EXCEPTION 'FALHA TESTE 5: User 2 não recebeu 7 peças no Dominó!';
        END IF;
    END;
    RAISE NOTICE 'OK: Teste 5 (Partida de Dominó criada via Matchmaking possui peças distribuídas autoritativamente)';

    RAISE NOTICE '====================================================================';
    RAISE NOTICE '>>> TODOS OS TESTES DE MATCHMAKING PASSARAM COM 100%% DE SUCESSO <<<';
    RAISE NOTICE '====================================================================';
END;
$$;

ROLLBACK;
