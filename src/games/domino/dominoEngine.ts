// ============================================================================
// Logic Engine: Dominó Duo — DuoPlay-Online
// Description: Motor autoritativo e matemático das regras do Dominó Duo.
//              Gera conjuntos, gerencia tabuleiro, valida encaixes, compras,
//              passagens, contagem de pontos e detecção de bloqueio.
// ============================================================================

import type {
  DominoTile,
  DominoBoard,
  DominoPlacedTile,
  DominoGameState,
  DominoClientGameState,
  DominoRulesConfig,
  StartRule,
} from './types';
import { calculateTotalTiles } from './types';

/**
 * Gera matematicamente o conjunto completo de peças para um determinado valor máximo N.
 * Garante que cada combinação [i, j] com 0 <= i <= j <= N apareça exatamente uma vez.
 */
export function generateDominoSet(maxTileValue: number): DominoTile[] {
  const maxVal = Math.max(0, Math.floor(maxTileValue));
  const tiles: DominoTile[] = [];

  for (let i = 0; i <= maxVal; i++) {
    for (let j = i; j <= maxVal; j++) {
      tiles.push([i, j]);
    }
  }

  return tiles;
}

/**
 * Embaralha um array utilizando Fisher-Yates.
 */
export function shuffleArray<T>(items: T[]): T[] {
  const result = [...items];
  for (let i = result.length - 1; i > 0; i--) {
    const j = Math.floor(Math.random() * (i + 1));
    [result[i], result[j]] = [result[j], result[i]];
  }
  return result;
}

/**
 * Normaliza uma peça para que o menor valor fique sempre na primeira posição.
 */
export function normalizeTile(tile: DominoTile): DominoTile {
  return tile[0] <= tile[1] ? [tile[0], tile[1]] : [tile[1], tile[0]];
}

/**
 * Verifica se duas peças são equivalentes matematicamente.
 */
export function areTilesEqual(a: DominoTile, b: DominoTile): boolean {
  const normA = normalizeTile(a);
  const normB = normalizeTile(b);
  return normA[0] === normB[0] && normA[1] === normB[1];
}

/**
 * Calcula a soma dos pontos (pips) de uma peça ou conjunto de peças.
 */
export function sumTilePips(tiles: DominoTile[]): number {
  return tiles.reduce((acc, t) => acc + (t[0] + t[1]), 0);
}

/**
 * Determina se uma peça pode ser encaixada em uma extremidade aberta com determinado valor.
 */
export function canTileConnect(tile: DominoTile, openEnd: number): boolean {
  return tile[0] === openEnd || tile[1] === openEnd;
}

/**
 * Retorna as jogadas válidas para uma mão dado o estado atual das extremidades do tabuleiro.
 */
export function getValidPlays(
  hand: DominoTile[],
  leftEnd: number | null,
  rightEnd: number | null
): { tile: DominoTile; canPlayLeft: boolean; canPlayRight: boolean }[] {
  if (!hand || hand.length === 0) return [];

  // Se o tabuleiro estiver vazio, qualquer peça é válida
  if (leftEnd === null || rightEnd === null) {
    return hand.map((tile) => ({
      tile,
      canPlayLeft: true,
      canPlayRight: true,
    }));
  }

  const result: { tile: DominoTile; canPlayLeft: boolean; canPlayRight: boolean }[] = [];

  for (const tile of hand) {
    const canPlayLeft = canTileConnect(tile, leftEnd);
    const canPlayRight = canTileConnect(tile, rightEnd);

    if (canPlayLeft || canPlayRight) {
      result.push({ tile, canPlayLeft, canPlayRight });
    }
  }

  return result;
}

/**
 * Localiza o jogador inicial com base nas regras configuradas.
 */
export function findStartingPlayer(
  hands: Record<string, DominoTile[]>,
  playerOrder: string[],
  startRule: StartRule
): string {
  if (playerOrder.length === 0) return '';
  if (startRule === 'host') return playerOrder[0];
  if (startRule === 'random') {
    const randomIndex = Math.floor(Math.random() * playerOrder.length);
    return playerOrder[randomIndex];
  }

  // Regra: Maior dupla (highest_double)
  if (startRule === 'highest_double') {
    let highestDouble = -1;
    let starter = playerOrder[0];

    for (const pid of playerOrder) {
      const hand = hands[pid] || [];
      for (const tile of hand) {
        if (tile[0] === tile[1] && tile[0] > highestDouble) {
          highestDouble = tile[0];
          starter = pid;
        }
      }
    }

    // Se ninguém tiver dupla, desempata pela peça de maior soma
    if (highestDouble !== -1) {
      return starter;
    }
  }

  // Regra: Maior peça por soma ou valor mais alto (highest_tile)
  let maxPipSum = -1;
  let maxSinglePip = -1;
  let candidate = playerOrder[0];

  for (const pid of playerOrder) {
    const hand = hands[pid] || [];
    for (const tile of hand) {
      const sum = tile[0] + tile[1];
      const maxVal = Math.max(tile[0], tile[1]);
      if (sum > maxPipSum || (sum === maxPipSum && maxVal > maxSinglePip)) {
        maxPipSum = sum;
        maxSinglePip = maxVal;
        candidate = pid;
      }
    }
  }

  return candidate;
}

/**
 * Realiza o encaixe oficial de uma peça no tabuleiro, atualizando as extremidades.
 * Retorna o novo tabuleiro atualizado ou erro se a jogada for matematicamente ilegal.
 */
export function placeTileOnBoard(
  board: DominoBoard,
  tile: DominoTile,
  side: 'left' | 'right',
  placedBy: string
): { success: boolean; newBoard?: DominoBoard; error?: string } {
  const currentTiles = [...board.tiles];
  const seq = currentTiles.length;

  // Caso 1: Tabuleiro vazio (Primeira peça)
  if (board.leftEnd === null || board.rightEnd === null || currentTiles.length === 0) {
    const newPlaced: DominoPlacedTile = {
      id: `${tile[0]}-${tile[1]}-${seq}`,
      tile,
      exposedValueLeft: tile[0],
      exposedValueRight: tile[1],
      placedBy,
      side: 'left',
      sequenceIndex: seq,
    };

    return {
      success: true,
      newBoard: {
        tiles: [newPlaced],
        leftEnd: tile[0],
        rightEnd: tile[1],
      },
    };
  }

  // Caso 2: Encaixe na extremidade esquerda
  if (side === 'left') {
    const openVal = board.leftEnd;
    if (!canTileConnect(tile, openVal)) {
      return {
        success: false,
        error: `A peça [${tile[0]}|${tile[1]}] não conecta na extremidade esquerda aberta (${openVal}).`,
      };
    }

    // A ponta que combina com openVal fica para dentro (à direita da peça),
    // a outra ponta fica voltada para fora (novo leftEnd).
    const newLeftEnd = tile[0] === openVal ? tile[1] : tile[0];
    const newPlaced: DominoPlacedTile = {
      id: `${tile[0]}-${tile[1]}-${seq}`,
      tile,
      exposedValueLeft: newLeftEnd,
      exposedValueRight: openVal,
      placedBy,
      side: 'left',
      sequenceIndex: seq,
    };

    return {
      success: true,
      newBoard: {
        tiles: [newPlaced, ...currentTiles],
        leftEnd: newLeftEnd,
        rightEnd: board.rightEnd,
      },
    };
  }

  // Caso 3: Encaixe na extremidade direita
  if (side === 'right') {
    const openVal = board.rightEnd;
    if (!canTileConnect(tile, openVal)) {
      return {
        success: false,
        error: `A peça [${tile[0]}|${tile[1]}] não conecta na extremidade direita aberta (${openVal}).`,
      };
    }

    // A ponta que combina com openVal fica para dentro (à esquerda da peça),
    // a outra ponta fica voltada para fora (novo rightEnd).
    const newRightEnd = tile[0] === openVal ? tile[1] : tile[0];
    const newPlaced: DominoPlacedTile = {
      id: `${tile[0]}-${tile[1]}-${seq}`,
      tile,
      exposedValueLeft: openVal,
      exposedValueRight: newRightEnd,
      placedBy,
      side: 'right',
      sequenceIndex: seq,
    };

    return {
      success: true,
      newBoard: {
        tiles: [...currentTiles, newPlaced],
        leftEnd: board.leftEnd,
        rightEnd: newRightEnd,
      },
    };
  }

  return { success: false, error: 'Extremidade inválida. Escolha "left" ou "right".' };
}

/**
 * Verifica se a partida está bloqueada (trancada).
 * Acontece quando NENHUM jogador tem jogadas válidas na mão, e:
 * - O monte de compra está vazio, OU
 * - A regra de compra não permite compras (no_draw ou limite atingido para todos).
 */
export function isGameBlocked(
  hands: Record<string, DominoTile[]>,
  turnOrder: string[],
  leftEnd: number | null,
  rightEnd: number | null,
  boneyardCount: number,
  config: DominoRulesConfig
): boolean {
  if (leftEnd === null || rightEnd === null) return false;

  // Se ainda houver peças no monte e a regra permite compras, a partida não está travada
  if (boneyardCount > 0 && config.drawRule !== 'no_draw') {
    return false;
  }

  // Checa se algum jogador possui pelo menos uma jogada válida
  for (const pid of turnOrder) {
    const hand = hands[pid] || [];
    const plays = getValidPlays(hand, leftEnd, rightEnd);
    if (plays.length > 0) {
      return false;
    }
  }

  return true;
}

/**
 * Determina o vencedor de uma rodada trancada (bloqueada).
 * Vence quem tiver a MENOR soma de pontos nas peças restantes.
 * Em duplas (2v2), soma os pontos da dupla.
 */
export function resolveBlockedRoundWinner(
  hands: Record<string, DominoTile[]>,
  turnOrder: string[],
  config: DominoRulesConfig
): {
  winnerId: string | null;
  winnerTeam?: 'teamA' | 'teamB' | null;
  isDraw: boolean;
  sums: Record<string, number>;
  teamSums?: { teamA: number; teamB: number };
} {
  const sums: Record<string, number> = {};

  for (const pid of turnOrder) {
    sums[pid] = sumTilePips(hands[pid] || []);
  }

  // Caso Duplas 2v2 (P1 & P3 vs P2 & P4)
  if (config.teamMode === 'teams_2v2' && turnOrder.length === 4) {
    const teamASum = (sums[turnOrder[0]] || 0) + (sums[turnOrder[2]] || 0);
    const teamBSum = (sums[turnOrder[1]] || 0) + (sums[turnOrder[3]] || 0);

    const teamSums = { teamA: teamASum, teamB: teamBSum };

    if (teamASum < teamBSum) {
      return { winnerId: turnOrder[0], winnerTeam: 'teamA', isDraw: false, sums, teamSums };
    } else if (teamBSum < teamASum) {
      return { winnerId: turnOrder[1], winnerTeam: 'teamB', isDraw: false, sums, teamSums };
    } else {
      return { winnerId: null, winnerTeam: null, isDraw: true, sums, teamSums };
    }
  }

  // Caso Individual (2, 3 ou 4 jogadores)
  let lowestSum = Infinity;
  let winnerId: string | null = null;
  let tie = false;

  for (const pid of turnOrder) {
    const pSum = sums[pid];
    if (pSum < lowestSum) {
      lowestSum = pSum;
      winnerId = pid;
      tie = false;
    } else if (pSum === lowestSum) {
      tie = true;
    }
  }

  if (tie) {
    return { winnerId: null, isDraw: true, sums };
  }

  return { winnerId, isDraw: false, sums };
}

/**
 * Projeta o estado seguro da partida para o cliente (Requirement 9: Privacidade).
 * Oculta peças dos adversários e do monte de compra enquanto a partida estiver ativa.
 */
export function projectDominoClientState(
  fullState: DominoGameState,
  viewerUserId: string
): DominoClientGameState {
  const handsCount: Record<string, number> = {};
  for (const [pid, hand] of Object.entries(fullState.hands || {})) {
    handsCount[pid] = (hand || []).length;
  }

  const myHand = (fullState.hands && fullState.hands[viewerUserId]) ? [...fullState.hands[viewerUserId]] : [];

  const clientState: DominoClientGameState = {
    config: fullState.config,
    board: fullState.board,
    boneyardCount: (fullState.boneyard || []).length,
    myHand,
    handsCount,
    turnOrder: fullState.turnOrder,
    currentTurnPlayerId: fullState.currentTurnPlayerId,
    drawsThisTurn: fullState.drawsThisTurn,
    lastAction: fullState.lastAction,
    consecutivePasses: fullState.consecutivePasses,
    scores: fullState.scores,
    teamScores: fullState.teamScores,
    roundNumber: fullState.roundNumber,
    isBlocked: fullState.isBlocked,
    winnerId: fullState.winnerId,
    winnerTeam: fullState.winnerTeam,
    isFinished: fullState.isFinished,
    finishReason: fullState.finishReason,
  };

  // Se a partida estiver finalizada, revela as mãos de todos para transparência e verificação de pontuação
  if (fullState.isFinished) {
    clientState.revealedHands = fullState.hands;
  }

  return clientState;
}
