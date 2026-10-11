-- ============================================================================
-- Test Suite: domino_security_rules_timeout_test.sql
-- Project: DuoPlay-Online
-- Feature: Dominó Duo — Auditoria de Segurança, Autorização, Privacidade de Mãos,
--          Validação Server-Side, Timeouts Acumulados e Resolução de Bloqueio
-- ============================================================================

BEGIN;

DO $$
DECLARE
    -- Usuários de teste
    v_user_1 UUID := '11111111-0000-0000-0000-000000000001'::uuid;
    v_user_2 UUID := '22222222-0000-0000-0000-000000000002'::uuid;
    v_user_3 UUID := '33333333-0000-0000-0000-000000000003'::uuid;
    v_user_4 UUID := '44444444-0000-0000-0000-000000000004'::uuid;
    v_intruder UUID := '99999999-0000-0000-0000-000000000099'::uuid;

    v_match_id UUID;
    v_res JSONB;
    v_snapshot JSONB;
    v_data JSONB;
    v_state JSONB;
    v_action_id UUID;
    v_err_caught BOOLEAN;
BEGIN
    RAISE NOTICE '====================================================================';
    RAISE NOTICE '>>> TESTES AUTORITATIVOS: DOMINÓ DUO — REGRAS, TIMEOUT & PRIVACIDADE <<<';
    RAISE NOTICE '====================================================================';

    -- 1. SETUP: Criar perfis dos jogadores
    INSERT INTO public.profiles (id, username, display_name, total_matches, total_wins, total_draws, total_losses)
    VALUES
        (v_user_1, 'domino_p1', 'Player 1', 0, 0, 0, 0),
        (v_user_2, 'domino_p2', 'Player 2', 0, 0, 0, 0),
        (v_user_3, 'domino_p3', 'Player 3', 0, 0, 0, 0),
        (v_user_4, 'domino_p4', 'Player 4', 0, 0, 0, 0),
        (v_intruder, 'intruder_x', 'Intruder', 0, 0, 0, 0)
    ON CONFLICT (id) DO NOTHING;

    -- 2. SETUP: Partida de Dominó Duo entre user_1 e user_2
    v_match_id := gen_random_uuid();
    INSERT INTO public.matches (
        id, room_id, game_id, status, current_turn_player_id, turn_number,
        turn_deadline, game_state, action_history, created_at, started_at
    ) VALUES (
        v_match_id, NULL, 'domino', 'in_progress', v_user_1, 1,
        clock_timestamp() + interval '30 seconds',
        jsonb_build_object(
            'config', jsonb_build_object(
                'playerCount', 2,
                'teamMode', 'individual',
                'drawRule', 'open',
                'playImmediately', true,
                'autoPass', true,
                'blockRule', 'lowest_pip_count',
                'scoringMode', 'single_round',
                'targetScore', 100
            ),
            'board', jsonb_build_object('tiles', '[]'::jsonb, 'leftEnd', null, 'rightEnd', null),
            'boneyard', jsonb_build_array(jsonb_build_array(0, 0), jsonb_build_array(1, 1)),
            'hands', jsonb_build_object(
                v_user_1::text, jsonb_build_array(jsonb_build_array(6, 6), jsonb_build_array(3, 4)),
                v_user_2::text, jsonb_build_array(jsonb_build_array(5, 5), jsonb_build_array(2, 3))
            ),
            'turnOrder', jsonb_build_array(v_user_1, v_user_2),
            'currentTurnPlayerId', v_user_1,
            'drawsThisTurn', 0,
            'consecutivePasses', 0,
            'scores', jsonb_build_object(v_user_1::text, 0, v_user_2::text, 0),
            'roundNumber', 1,
            'isBlocked', false,
            'isFinished', false
        ),
        '[]'::jsonb, clock_timestamp(), clock_timestamp()
    );

    INSERT INTO public.match_players (match_id, user_id, slot, score, is_winner, connection_status)
    VALUES
        (v_match_id, v_user_1, 1, 0, false, 'connected'),
        (v_match_id, v_user_2, 2, 0, false, 'connected');

    -- ------------------------------------------------------------------------
    -- TESTE 1: Autorização da RPC de Snapshot (get_match_snapshot_for_player)
    -- ------------------------------------------------------------------------
    -- 1.1 Terceiro não participante é rejeitado com FORBIDDEN (P0003)
    SET LOCAL ROLE authenticated;
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_intruder::text, 'role', 'authenticated')::text;

    v_err_caught := false;
    BEGIN
        PERFORM public.get_match_snapshot_for_player(v_match_id);
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'P0003' THEN
            v_err_caught := true;
        END IF;
    END;

    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'FALHA TESTE 1.1: Terceiro não participante não foi rejeitado!';
    END IF;
    RAISE NOTICE 'OK: Teste 1.1 (Autorização estrita contra intrusos aprovada)';

    -- 1.2 Participante autorizado obtém snapshot protegido
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_user_1::text, 'role', 'authenticated')::text;
    v_res := public.get_match_snapshot_for_player(v_match_id);

    IF (v_res->>'success')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 1.2: Participante legítimo teve acesso negado!';
    END IF;

    v_data := v_res->'data';
    v_state := v_data->'game_state';

    -- Confirma privacidade: mão do adversário e monte estão ocultados
    IF v_state ? 'hands' OR v_state ? 'boneyard' THEN
        RAISE EXCEPTION 'FALHA TESTE 1.2: Snapshot vazou mãos secretas ou monte!';
    END IF;

    IF (v_state->>'boneyardCount')::int != 2 THEN
        RAISE EXCEPTION 'FALHA TESTE 1.2: Contagem de monte incorreta no snapshot!';
    END IF;

    IF jsonb_array_length(v_state->'myHand') != 2 THEN
        RAISE EXCEPTION 'FALHA TESTE 1.2: Peças do próprio jogador ausentes!';
    END IF;
    RAISE NOTICE 'OK: Teste 1.2 (Privacidade e isolamento de mãos e monte aprovados)';

    -- ------------------------------------------------------------------------
    -- TESTE 2: Rejeição de Jogadas e Ações Inválidas no Dominó
    -- ------------------------------------------------------------------------
    -- 2.1 Rejeita jogada fora do turno
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_user_2::text, 'role', 'authenticated')::text;
    v_err_caught := false;
    BEGIN
        PERFORM public.validate_domino_action(
            v_match_id, v_user_2, 'play_tile',
            jsonb_build_object('tile', jsonb_build_array(5, 5), 'side', 'right'),
            v_state, 1
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'P0071' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'FALHA TESTE 2.1: Jogada fora do turno aceita indevidamente!';
    END IF;
    RAISE NOTICE 'OK: Teste 2.1 (Rejeição de jogada fora do turno)';

    -- 2.2 Rejeita compra quando jogador possui peças válidas na mão
    SET LOCAL "request.jwt.claims" TO jsonb_build_object('sub', v_user_1::text, 'role', 'authenticated')::text;
    v_err_caught := false;
    BEGIN
        -- No tabuleiro vazio, qualquer peça é válida; tentar comprar deve falhar
        PERFORM public.validate_domino_action(
            v_match_id, v_user_1, 'draw_tile',
            '{}'::jsonb,
            (SELECT game_state FROM public.matches WHERE id = v_match_id), 1
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'P0082' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'FALHA TESTE 2.2: Compra com jogada válida aceita indevidamente!';
    END IF;
    RAISE NOTICE 'OK: Teste 2.2 (Rejeição de compra com jogada disponível)';

    -- 2.3 Rejeita passar a vez quando possui jogadas válidas
    v_err_caught := false;
    BEGIN
        PERFORM public.validate_domino_action(
            v_match_id, v_user_1, 'pass_turn',
            '{}'::jsonb,
            (SELECT game_state FROM public.matches WHERE id = v_match_id), 1
        );
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'P0079' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'FALHA TESTE 2.3: Passagem indevida aceita com jogadas válidas!';
    END IF;
    RAISE NOTICE 'OK: Teste 2.3 (Rejeição de passagem indevida)';

    -- ------------------------------------------------------------------------
    -- TESTE 3: Timeouts Acumulados e Resolução Completa de Trancamento
    -- ------------------------------------------------------------------------
    -- 3.1 Timeout com prazo não expirado no servidor é rejeitado
    v_err_caught := false;
    BEGIN
        PERFORM public.timeout_match_turn(v_match_id, 1);
    EXCEPTION WHEN OTHERS THEN
        IF SQLSTATE = 'P0080' THEN
            v_err_caught := true;
        END IF;
    END;
    IF NOT v_err_caught THEN
        RAISE EXCEPTION 'FALHA TESTE 3.1: Timeout executado antes do prazo oficial!';
    END IF;
    RAISE NOTICE 'OK: Teste 3.1 (Proteção de prazo do servidor aprovada)';

    -- 3.2 Avançar deadline para o passado para testar timeouts consecutivos
    UPDATE public.matches
    SET turn_deadline = clock_timestamp() - interval '5 seconds'
    WHERE id = v_match_id;

    -- 1º Timeout (Jogador 1 timeout -> passa para Jogador 2, consecutivePasses = 1)
    v_res := public.timeout_match_turn(v_match_id, 1);
    IF (v_res->'data'->>'is_finished')::boolean IS TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 3.2: 1º timeout encerrou a partida precipitadamente!';
    END IF;

    -- 3.3 Teste de idempotência no turno 1
    v_res := public.timeout_match_turn(v_match_id, 1);
    IF (v_res->'data'->>'idempotent')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 3.3: Idempotência de turno antigo violada!';
    END IF;
    RAISE NOTICE 'OK: Teste 3.2 & 3.3 (1º Timeout e Idempotência aprovados)';

    -- Forçar deadline para o 2º turno
    UPDATE public.matches
    SET turn_deadline = clock_timestamp() - interval '5 seconds'
    WHERE id = v_match_id;

    -- 2º Timeout (Jogador 2 timeout -> consecutivePasses = 2 = num_players)
    -- Deve TRANCAR e FINALIZAR a partida com cálculo de vencedor por menor soma
    v_res := public.timeout_match_turn(v_match_id, 2);

    IF (v_res->'data'->>'is_finished')::boolean IS NOT TRUE THEN
        RAISE EXCEPTION 'FALHA TESTE 3.4: 2 timeouts consecutivos não trancaram/finalizaram a partida!';
    END IF;

    -- Conferir campos oficiais na tabela matches
    SELECT * INTO v_data FROM public.matches WHERE id = v_match_id;
    IF v_data->>'status' != 'finished' THEN
        RAISE EXCEPTION 'FALHA TESTE 3.4: matches.status não está finished!';
    END IF;
    IF v_data->>'finish_reason' NOT IN ('timeout', 'normal') THEN
        RAISE EXCEPTION 'FALHA TESTE 3.4: finish_reason inválido: %', v_data->>'finish_reason';
    END IF;

    RAISE NOTICE 'OK: Teste 3.4 (Bloqueio completo por timeouts consecutivos validado com sucesso)';
    RAISE NOTICE '====================================================================';
    RAISE NOTICE '>>> TODOS OS TESTES AUTORITATIVOS DO DOMINÓ PASSARAM COM SUCESSO <<<';
    RAISE NOTICE '====================================================================';
END;
$$;

ROLLBACK;
