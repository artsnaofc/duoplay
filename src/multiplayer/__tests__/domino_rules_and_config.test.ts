// ============================================================================
// Unit & Integration Tests: Dominó Duo — DuoPlay-Online
// Description: Testes autoritativos de configuração de regras, geração de peças,
//              tabuleiro, encaixes matemáticos, compras, passagens, bloqueio,
//              privacidade de mãos e integração com a Network Engine.
// ============================================================================

import { describe, it, beforeEach, afterEach } from 'node:test';
import assert from 'node:assert/strict';
import {
  generateDominoSet,
  canTileConnect,
  getValidPlays,
  placeTileOnBoard,
  isGameBlocked,
  resolveBlockedRoundWinner,
  projectDominoClientState,
  findStartingPlayer,
  normalizeTile,
  areTilesEqual,
  sumTilePips,
} from '@/games/domino/dominoEngine';
import {
  calculateTotalTiles,
  validateDominoConfig,
  normalizeDominoConfig,
  DOMINO_PRESETS,
  type DominoTile,
  type DominoBoard,
  type DominoGameState,
  type DominoRulesConfig,
} from '@/games/domino/types';
import { getGameDefinition, listGames, normalizeGameId } from '../registry/index';
import { GameSessionController } from '../controllers/GameSessionController';
import { setSnapshotFetcherForTest } from '../network/snapshot';
import { setActionSubmitterForTest, generateActionId } from '../network/actions';
import { clearSyncQueuesForTest } from '../network/sync';
import type { GameSnapshot, SubmitActionInput, ActionResult } from '../network/types';

describe('Dominó Duo: Motor de Regras, Configurações e Segurança Server-Side', () => {
  beforeEach(() => {
    clearSyncQueuesForTest();
  });

  afterEach(() => {
    setSnapshotFetcherForTest(null);
    setActionSubmitterForTest(null);
  });

  // --------------------------------------------------------------------------
  // 1. Catálogo e Registro Central de Jogos
  // --------------------------------------------------------------------------
  describe('1. Game Registry & Integração de Plataforma', () => {
    it('1.1. Dominó Duo deve estar registrado e ativo no Game Registry', () => {
      const def = getGameDefinition('domino');
      assert.ok(def !== null, 'Definição de domino não deve ser nula');
      assert.strictEqual(def?.id, 'domino');
      assert.strictEqual(def?.title, 'Dominó Duo');
      assert.strictEqual(def?.isAvailable, true);
      assert.strictEqual(def?.minPlayers, 2);
      assert.strictEqual(def?.maxPlayers, 4);
      assert.ok(def?.component !== undefined, 'Componente visual deve estar registrado');
    });

    it('1.2. normalização de gameId deve suportar domino de forma uniforme', () => {
      assert.strictEqual(normalizeGameId('domino'), 'domino');
      assert.strictEqual(normalizeGameId('DOMINO'), 'domino');
    });
  });

  // --------------------------------------------------------------------------
  // 2. Sistema de Configuração e Presets
  // --------------------------------------------------------------------------
  describe('2. Validação e Normalização de Configurações', () => {
    it('2.1. Todos os presets oficiais devem ser válidos e coerentes', () => {
      for (const [key, preset] of Object.entries(DOMINO_PRESETS)) {
        const val = validateDominoConfig(preset.config);
        assert.strictEqual(val.valid, true, `Preset ${key} deve ser válido: ${val.error}`);
      }
    });

    it('2.2. Cálculo matemático de total de peças (N + 1) * (N + 2) / 2', () => {
      assert.strictEqual(calculateTotalTiles(6), 28, 'Duplo-6 deve ter 28 peças');
      assert.strictEqual(calculateTotalTiles(9), 55, 'Duplo-9 deve ter 55 peças');
      assert.strictEqual(calculateTotalTiles(12), 91, 'Duplo-12 deve ter 91 peças');
      assert.strictEqual(calculateTotalTiles(3), 10, 'Duplo-3 deve ter 10 peças');
    });

    it('2.3. Rejeita distribuição impossível que exceda o conjunto de peças', () => {
      // 4 jogadores * 8 peças = 32 peças > 28 do duplo-6
      const invalidConfig: Partial<DominoRulesConfig> = {
        playerCount: 4,
        maxTileValue: 6,
        initialHandSize: 8,
      };
      const result = validateDominoConfig(invalidConfig);
      assert.strictEqual(result.valid, false);
      assert.ok(result.error?.includes('Distribuição impossível'));
    });

    it('2.4. Rejeita modo de duplas se o número de jogadores não for exatamente 4', () => {
      const invalidTeam: Partial<DominoRulesConfig> = {
        playerCount: 2,
        teamMode: 'teams_2v2',
      };
      const result = validateDominoConfig(invalidTeam);
      assert.strictEqual(result.valid, false);
      assert.ok(result.error?.includes('exige exatamente 4 jogadores'));
    });

    it('2.5. Rejeita valor máximo de peça fora dos limites permitidos (3 a 12)', () => {
      assert.strictEqual(validateDominoConfig({ maxTileValue: 2 }).valid, false);
      assert.strictEqual(validateDominoConfig({ maxTileValue: 15 }).valid, false);
    });

    it('2.6. normalizeDominoConfig preenche valores padrão seguros para configs parciais', () => {
      const norm = normalizeDominoConfig({
        tileset: 'double_9',
      });
      assert.strictEqual(norm.maxTileValue, 9);
      assert.strictEqual(norm.playerCount, 2);
      assert.strictEqual(norm.drawRule, 'open');
      assert.strictEqual(norm.playImmediately, true);
    });
  });

  // --------------------------------------------------------------------------
  // 3. Geração Matemática e Unicidade das Peças
  // --------------------------------------------------------------------------
  describe('3. Geração Matemática do Conjunto de Peças', () => {
    it('3.1. generateDominoSet(6) deve gerar exatamente 28 peças únicas sem duplicações', () => {
      const set = generateDominoSet(6);
      assert.strictEqual(set.length, 28);

      const seen = new Set<string>();
      for (const tile of set) {
        assert.ok(tile[0] <= tile[1], 'Peça deve estar ordenada matematicamente');
        const key = `${tile[0]}-${tile[1]}`;
        assert.strictEqual(seen.has(key), false, `Peça duplicada encontrada: ${key}`);
        seen.add(key);
      }
    });

    it('3.2. generateDominoSet(9) deve gerar exatamente 55 peças únicas', () => {
      const set = generateDominoSet(9);
      assert.strictEqual(set.length, 55);
    });

    it('3.3. sumTilePips deve calcular a soma exata dos pontos', () => {
      const tiles: DominoTile[] = [
        [6, 6],
        [0, 5],
        [1, 2],
      ];
      assert.strictEqual(sumTilePips(tiles), 12 + 5 + 3);
    });
  });

  // --------------------------------------------------------------------------
  // 4. Regras de Encaixe e Tabuleiro
  // --------------------------------------------------------------------------
  describe('4. Encaixe de Peças e Tabuleiro', () => {
    it('4.1. canTileConnect valida corretamente se a peça possui o valor aberto', () => {
      assert.strictEqual(canTileConnect([3, 5], 3), true);
      assert.strictEqual(canTileConnect([3, 5], 5), true);
      assert.strictEqual(canTileConnect([3, 5], 4), false);
    });

    it('4.2. Primeira peça jogada define o início da cadeia e abre ambas as extremidades', () => {
      const emptyBoard: DominoBoard = { tiles: [], leftEnd: null, rightEnd: null };
      const res = placeTileOnBoard(emptyBoard, [6, 6], 'left', 'user-1');

      assert.strictEqual(res.success, true);
      assert.strictEqual(res.newBoard?.leftEnd, 6);
      assert.strictEqual(res.newBoard?.rightEnd, 6);
      assert.strictEqual(res.newBoard?.tiles.length, 1);
    });

    it('4.3. Encaixe válido na extremidade esquerda atualiza novo leftEnd', () => {
      const board: DominoBoard = {
        tiles: [
          {
            id: '6-6-0',
            tile: [6, 6],
            exposedValueLeft: 6,
            exposedValueRight: 6,
            placedBy: 'user-1',
            side: 'left',
            sequenceIndex: 0,
          },
        ],
        leftEnd: 6,
        rightEnd: 6,
      };

      // Encaixa [4, 6] na esquerda. O 6 conecta no 6, a nova ponta aberta vira 4.
      const res = placeTileOnBoard(board, [4, 6], 'left', 'user-2');
      assert.strictEqual(res.success, true);
      assert.strictEqual(res.newBoard?.leftEnd, 4);
      assert.strictEqual(res.newBoard?.rightEnd, 6);
      assert.strictEqual(res.newBoard?.tiles.length, 2);
    });

    it('4.4. Encaixe válido na extremidade direita atualiza novo rightEnd', () => {
      const board: DominoBoard = {
        tiles: [
          {
            id: '6-6-0',
            tile: [6, 6],
            exposedValueLeft: 6,
            exposedValueRight: 6,
            placedBy: 'user-1',
            side: 'left',
            sequenceIndex: 0,
          },
        ],
        leftEnd: 6,
        rightEnd: 6,
      };

      // Encaixa [6, 2] na direita. O 6 conecta no 6, a nova ponta aberta vira 2.
      const res = placeTileOnBoard(board, [2, 6], 'right', 'user-2');
      assert.strictEqual(res.success, true);
      assert.strictEqual(res.newBoard?.leftEnd, 6);
      assert.strictEqual(res.newBoard?.rightEnd, 2);
    });

    it('4.5. Rejeita encaixe com valores incompatíveis', () => {
      const board: DominoBoard = {
        tiles: [
          {
            id: '3-5-0',
            tile: [3, 5],
            exposedValueLeft: 3,
            exposedValueRight: 5,
            placedBy: 'user-2',
            side: 'left',
            sequenceIndex: 0,
          },
        ],
        leftEnd: 3,
        rightEnd: 5,
      };

      const res = placeTileOnBoard(board, [1, 2], 'left', 'user-1');
      assert.strictEqual(res.success, false);
      assert.ok(res.error?.includes('não conecta'));
    });
  });

  // --------------------------------------------------------------------------
  // 5. Início de Partida e Detecção do Jogador Inicial
  // --------------------------------------------------------------------------
  describe('5. Determinação do Jogador Inicial', () => {
    it('5.1. Regra highest_double seleciona o jogador com a maior dupla', () => {
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 2], [5, 5]],
        'user-2': [[6, 6], [0, 1]],
        'user-3': [[3, 4], [4, 4]],
      };

      const starter = findStartingPlayer(hands, ['user-1', 'user-2', 'user-3'], 'highest_double');
      assert.strictEqual(starter, 'user-2', 'User 2 com [6,6] deve começar');
    });

    it('5.2. Se ninguém possuir dupla, desempata pela peça de maior soma', () => {
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 2], [3, 4]], // Max: 3+4=7
        'user-2': [[0, 1], [4, 5]], // Max: 4+5=9
      };

      const starter = findStartingPlayer(hands, ['user-1', 'user-2'], 'highest_double');
      assert.strictEqual(starter, 'user-2', 'User 2 com [4,5]=9 deve começar');
    });
  });

  // --------------------------------------------------------------------------
  // 6. Bloqueio e Resolução de Partida Trancada
  // --------------------------------------------------------------------------
  describe('6. Bloqueio (Trancamento) e Vencedor por Menor Soma', () => {
    it('6.1. isGameBlocked detecta quando ninguém tem jogadas e o monte está vazio', () => {
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 1], [2, 2]],
        'user-2': [[3, 3], [4, 4]],
      };

      const config = DOMINO_PRESETS.traditional.config;

      // Pontas abertas são 5 e 6: ninguém tem 5 ou 6
      const blocked = isGameBlocked(hands, ['user-1', 'user-2'], 5, 6, 0, config);
      assert.strictEqual(blocked, true);
    });

    it('6.2. isGameBlocked retorna false se ainda houver peças no monte com compra permitida', () => {
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 1]],
        'user-2': [[2, 2]],
      };

      const config = DOMINO_PRESETS.traditional.config;
      // Pontas 5 e 6, mas ainda há 3 peças no monte
      const blocked = isGameBlocked(hands, ['user-1', 'user-2'], 5, 6, 3, config);
      assert.strictEqual(blocked, false);
    });

    it('6.3. resolveBlockedRoundWinner elege o jogador com a menor soma de pontos', () => {
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 2], [0, 1]], // Soma: 3 + 1 = 4
        'user-2': [[5, 6], [3, 4]], // Soma: 11 + 7 = 18
      };

      const config = DOMINO_PRESETS.traditional.config;
      const res = resolveBlockedRoundWinner(hands, ['user-1', 'user-2'], config);

      assert.strictEqual(res.isDraw, false);
      assert.strictEqual(res.winnerId, 'user-1');
      assert.strictEqual(res.sums['user-1'], 4);
      assert.strictEqual(res.sums['user-2'], 18);
    });

    it('6.4. resolveBlockedRoundWinner em duplas soma os pontos combinados de cada dupla', () => {
      // Dupla A: P1 + P3; Dupla B: P2 + P4
      const hands: Record<string, DominoTile[]> = {
        'user-1': [[1, 1]], // 2
        'user-2': [[3, 3]], // 6
        'user-3': [[1, 2]], // 3 -> Dupla A soma = 2 + 3 = 5
        'user-4': [[2, 2]], // 4 -> Dupla B soma = 6 + 4 = 10
      };

      const config = DOMINO_PRESETS.teams.config;
      const res = resolveBlockedRoundWinner(
        hands,
        ['user-1', 'user-2', 'user-3', 'user-4'],
        config
      );

      assert.strictEqual(res.isDraw, false);
      assert.strictEqual(res.winnerTeam, 'teamA');
      assert.strictEqual(res.teamSums?.teamA, 5);
      assert.strictEqual(res.teamSums?.teamB, 10);
    });
  });

  // --------------------------------------------------------------------------
  // 7. Privacidade das Mãos e Projeção Segura (Requirement 9)
  // --------------------------------------------------------------------------
  describe('7. Privacidade das Mãos e Ocultação de Peças (Requirement 9)', () => {
    it('7.1. projectDominoClientState oculta peças dos adversários e do monte durante partida ativa', () => {
      const serverState: DominoGameState = {
        config: DOMINO_PRESETS.traditional.config,
        board: { tiles: [], leftEnd: 6, rightEnd: 6 },
        boneyard: [[0, 0], [0, 1], [0, 2]],
        hands: {
          'user-1': [[6, 6], [3, 4]],
          'user-2': [[5, 5], [1, 2]],
        },
        turnOrder: ['user-1', 'user-2'],
        currentTurnPlayerId: 'user-1',
        drawsThisTurn: 0,
        consecutivePasses: 0,
        scores: { 'user-1': 0, 'user-2': 0 },
        roundNumber: 1,
        isBlocked: false,
        winnerId: null,
        isFinished: false,
      };

      // User 1 visualiza o estado
      const projectedForUser1 = projectDominoClientState(serverState, 'user-1');

      // 1. Minha mão deve estar presente com as 2 peças
      assert.strictEqual(projectedForUser1.myHand.length, 2);
      assert.deepStrictEqual(projectedForUser1.myHand, [[6, 6], [3, 4]]);

      // 2. Mão do oponente NÃO deve estar presente no client state
      assert.strictEqual((projectedForUser1 as any).hands, undefined);

      // 3. Contagem de peças deve ser precisa
      assert.strictEqual(projectedForUser1.handsCount['user-1'], 2);
      assert.strictEqual(projectedForUser1.handsCount['user-2'], 2);

      // 4. Peças do monte NÃO devem ser reveladas, apenas o contador
      assert.strictEqual((projectedForUser1 as any).boneyard, undefined);
      assert.strictEqual(projectedForUser1.boneyardCount, 3);

      // 5. Mãos reveladas devem ser nulas enquanto partida estiver em andamento
      assert.strictEqual(projectedForUser1.revealedHands, undefined);
    });

    it('7.2. Revela as mãos de todos apenas quando a partida é finalizada para auditoria', () => {
      const finishedServerState: DominoGameState = {
        config: DOMINO_PRESETS.traditional.config,
        board: { tiles: [], leftEnd: 6, rightEnd: 6 },
        boneyard: [],
        hands: {
          'user-1': [],
          'user-2': [[5, 5]],
        },
        turnOrder: ['user-1', 'user-2'],
        currentTurnPlayerId: 'user-1',
        drawsThisTurn: 0,
        consecutivePasses: 0,
        scores: { 'user-1': 10, 'user-2': 0 },
        roundNumber: 1,
        isBlocked: false,
        winnerId: 'user-1',
        isFinished: true,
        finishReason: 'domino',
      };

      const projected = projectDominoClientState(finishedServerState, 'user-2');
      assert.strictEqual(projected.isFinished, true);
      assert.ok(projected.revealedHands !== undefined);
      assert.deepStrictEqual(projected.revealedHands?.['user-2'], [[5, 5]]);
    });
  });

  // --------------------------------------------------------------------------
  // 8. Integração com o GameSessionController e Network Engine
  // --------------------------------------------------------------------------
  describe('8. Integração com GameSessionController e Idempotência', () => {
    it('8.1. Controlador carrega snapshot inicial de Dominó e emite estado sincronizado', async () => {
      const mockSnapshot: GameSnapshot<any> = {
        matchId: 'match-domino-1',
        roomId: 'room-1',
        gameId: 'domino',
        status: 'in_progress',
        state: {
          config: DOMINO_PRESETS.traditional.config,
          board: { tiles: [], leftEnd: 6, rightEnd: 6 },
          boneyardCount: 14,
          myHand: [[6, 6], [2, 3]],
          handsCount: { 'user-1': 2, 'user-2': 2 },
          turnOrder: ['user-1', 'user-2'],
          currentTurnPlayerId: 'user-1',
          drawsThisTurn: 0,
          consecutivePasses: 0,
          scores: { 'user-1': 0, 'user-2': 0 },
          roundNumber: 1,
          isBlocked: false,
          winnerId: null,
          isFinished: false,
        },
        currentTurnPlayerId: 'user-1',
        turnNumber: 1,
        turnDeadline: null,
        winnerId: null,
        isDraw: false,
        finishReason: null,
        players: [
          {
            userId: 'user-1',
            slot: 1,
            gameSymbol: null,
            score: 0,
            isWinner: false,
            disconnectedAt: null,
            gracePeriodExpiresAt: null,
            lastSeenAt: null,
            connectionStatus: 'connected',
            joinedAt: new Date().toISOString(),
          },
          {
            userId: 'user-2',
            slot: 2,
            gameSymbol: null,
            score: 0,
            isWinner: false,
            disconnectedAt: null,
            gracePeriodExpiresAt: null,
            lastSeenAt: null,
            connectionStatus: 'connected',
            joinedAt: new Date().toISOString(),
          },
        ],
        version: 1,
        actionHistory: [],
        createdAt: new Date().toISOString(),
        startedAt: new Date().toISOString(),
        finishedAt: null,
      };

      setSnapshotFetcherForTest(async () => mockSnapshot);

      const controller = new GameSessionController('match-domino-1');
      const loaded = await controller.init();

      assert.ok(loaded !== null);
      assert.strictEqual(loaded?.gameId, 'domino');
      assert.strictEqual(controller.getSyncState(), 'synced');
      assert.strictEqual((loaded?.state as any).boneyardCount, 14);

      controller.destroy();
    });

    it('8.2. Submissão de jogada autorizada propaga payload tipado com actionId', async () => {
      const mockSnapshot: GameSnapshot<any> = {
        matchId: 'match-domino-2',
        roomId: 'room-1',
        gameId: 'domino',
        status: 'in_progress',
        state: {
          config: DOMINO_PRESETS.traditional.config,
          board: { tiles: [], leftEnd: 6, rightEnd: 6 },
          boneyardCount: 14,
          myHand: [[6, 6]],
          handsCount: { 'user-1': 1, 'user-2': 1 },
          turnOrder: ['user-1', 'user-2'],
          currentTurnPlayerId: 'user-1',
          drawsThisTurn: 0,
          consecutivePasses: 0,
          scores: { 'user-1': 0, 'user-2': 0 },
          roundNumber: 1,
          isBlocked: false,
          winnerId: null,
          isFinished: false,
        },
        currentTurnPlayerId: 'user-1',
        turnNumber: 1,
        turnDeadline: null,
        winnerId: null,
        isDraw: false,
        finishReason: null,
        players: [],
        version: 1,
        actionHistory: [],
        createdAt: new Date().toISOString(),
        startedAt: new Date().toISOString(),
        finishedAt: null,
      };

      setSnapshotFetcherForTest(async () => mockSnapshot);

      let capturedActionInput: SubmitActionInput<any> | null = null;
      setActionSubmitterForTest(async (input) => {
        capturedActionInput = input as SubmitActionInput<any>;
        return {
          accepted: true,
          actionId: generateActionId(),
          error: null,
          snapshot: {
            ...mockSnapshot,
            turnNumber: 2,
            version: 2,
          },
        };
      });

      const controller = new GameSessionController('match-domino-2');
      await controller.init();

      const result = await controller.submitAction('play_tile', {
        tile: [6, 6],
        side: 'left',
      });

      assert.strictEqual(result.accepted, true);
      assert.strictEqual((capturedActionInput as any)?.actionType, 'play_tile');
      assert.deepStrictEqual((capturedActionInput as any)?.payload?.tile, [6, 6]);
      assert.strictEqual((capturedActionInput as any)?.payload?.side, 'left');

      controller.destroy();
    });
  });
});
