// ============================================================================
// Types & Configuration Contracts: Dominó Duo — DuoPlay-Online
// Description: Contratos tipados de configuração de regras, peças, tabuleiro,
//              mãos, equipes e snapshots de estado para o Dominó Duo.
// ============================================================================

export type DominoTile = [number, number]; // [top, bottom] onde top <= bottom matematicamente

export type TilesetType = 'double_6' | 'double_9' | 'double_12' | 'custom';

export type DrawRule = 'open' | 'one_tile' | 'custom_limit' | 'no_draw';

export type StartRule = 'random' | 'highest_double' | 'highest_tile' | 'host';

export type BlockRule = 'lowest_pip_count' | 'draw' | 'round_winner';

export type ScoringMode = 'single_round' | 'target_score';

export type TeamMode = 'individual' | 'teams_2v2';

export interface DominoPlacedTile {
  id: string; // Ex: "6-6-0"
  tile: DominoTile;
  exposedValueLeft: number;
  exposedValueRight: number;
  placedBy: string;
  side: 'left' | 'right';
  sequenceIndex: number;
}

export interface DominoBoard {
  tiles: DominoPlacedTile[];
  leftEnd: number | null;
  rightEnd: number | null;
}

export interface DominoRulesConfig {
  playerCount: number; // 2, 3 ou 4
  teamMode: TeamMode; // 'individual' ou 'teams_2v2' (apenas se playerCount === 4)
  tileset: TilesetType;
  maxTileValue: number; // 6 para double_6, 9 para double_9, 12 para double_12, 3..12 para custom
  initialHandSize: number; // Peças por jogador (ex: 7)
  drawRule: DrawRule;
  maxDrawsPerTurn: number; // Se custom_limit (ex: 2)
  playImmediately: boolean; // Se pode jogar imediatamente a peça recém-comprada
  autoPass: boolean; // Se passa automaticamente quando não há jogadas possíveis nem compras
  startRule: StartRule;
  blockRule: BlockRule;
  scoringMode: ScoringMode;
  targetScore: number; // 50, 100, 150, 200 ou custom
  turnTimerSeconds: number; // 0 (sem limite), 15, 30, 45, 60
}

export interface DominoGameState {
  config: DominoRulesConfig;
  board: DominoBoard;
  boneyard: DominoTile[]; // Monte secreto no servidor
  hands: Record<string, DominoTile[]>; // Mãos secretas por jogador no servidor
  turnOrder: string[]; // Ordem cíclica de IDs dos jogadores
  currentTurnPlayerId: string | null;
  drawsThisTurn: number;
  lastAction?: {
    type: 'play' | 'draw' | 'pass';
    playerId: string;
    tile?: DominoTile;
    side?: 'left' | 'right';
  };
  consecutivePasses: number; // Quantidade de passes seguidos (para detectar bloqueio)
  scores: Record<string, number>; // Pontuação acumulada por jogador (ou por equipe)
  teamScores?: { teamA: number; teamB: number }; // Se duplas
  roundNumber: number;
  isBlocked: boolean;
  winnerId: string | null;
  winnerTeam?: 'teamA' | 'teamB' | null;
  isFinished: boolean;
  finishReason?: 'domino' | 'blocked' | 'target_reached' | 'abandoned' | 'timeout';
}

/**
 * Projeção segura de estado para o cliente (Requirement 9: Privacidade das Mãos)
 * Adversários não recebem a identidade das peças uns dos outros nem do monte.
 */
export interface DominoClientGameState {
  config: DominoRulesConfig;
  board: DominoBoard;
  boneyardCount: number; // Quantidade de peças restantes no monte
  myHand: DominoTile[]; // Peças visíveis apenas do jogador autenticado
  handsCount: Record<string, number>; // Contagem de peças de cada jogador
  turnOrder: string[];
  currentTurnPlayerId: string | null;
  drawsThisTurn: number;
  lastAction?: DominoGameState['lastAction'];
  consecutivePasses: number;
  scores: Record<string, number>;
  teamScores?: { teamA: number; teamB: number };
  roundNumber: number;
  isBlocked: boolean;
  winnerId: string | null;
  winnerTeam?: 'teamA' | 'teamB' | null;
  isFinished: boolean;
  finishReason?: DominoGameState['finishReason'];
  revealedHands?: Record<string, DominoTile[]>; // Revelado integralmente APENAS no fim da partida
}

export type DominoPresetName = 'traditional' | 'fast' | 'competitive' | 'teams' | 'custom';

export const DOMINO_PRESETS: Record<DominoPresetName, { name: string; description: string; config: DominoRulesConfig }> = {
  traditional: {
    name: 'Tradicional',
    description: 'Duelo clássico de 2 jogadores, conjunto duplo-6 (28 peças), 7 peças cada e compra livre.',
    config: {
      playerCount: 2,
      teamMode: 'individual',
      tileset: 'double_6',
      maxTileValue: 6,
      initialHandSize: 7,
      drawRule: 'open',
      maxDrawsPerTurn: 99,
      playImmediately: true,
      autoPass: true,
      startRule: 'highest_double',
      blockRule: 'lowest_pip_count',
      scoringMode: 'single_round',
      targetScore: 100,
      turnTimerSeconds: 30,
    },
  },
  fast: {
    name: 'Rápido (Blitz)',
    description: 'Partida relâmpago de 2 jogadores, 5 peças iniciais, no máximo 1 compra por turno e turnos de 15s.',
    config: {
      playerCount: 2,
      teamMode: 'individual',
      tileset: 'double_6',
      maxTileValue: 6,
      initialHandSize: 5,
      drawRule: 'one_tile',
      maxDrawsPerTurn: 1,
      playImmediately: true,
      autoPass: true,
      startRule: 'random',
      blockRule: 'lowest_pip_count',
      scoringMode: 'single_round',
      targetScore: 50,
      turnTimerSeconds: 15,
    },
  },
  competitive: {
    name: 'Competitivo',
    description: 'Disputa tática sem compra no monte, vitória até 100 pontos e penalidade estrita por bloqueio.',
    config: {
      playerCount: 2,
      teamMode: 'individual',
      tileset: 'double_6',
      maxTileValue: 6,
      initialHandSize: 7,
      drawRule: 'no_draw',
      maxDrawsPerTurn: 0,
      playImmediately: false,
      autoPass: false,
      startRule: 'highest_double',
      blockRule: 'lowest_pip_count',
      scoringMode: 'target_score',
      targetScore: 100,
      turnTimerSeconds: 30,
    },
  },
  teams: {
    name: 'Duplas (2v2)',
    description: '4 jogadores em duas equipes (1 & 3 vs 2 & 4), 7 peças para cada (todas as 28 peças distribuídas).',
    config: {
      playerCount: 4,
      teamMode: 'teams_2v2',
      tileset: 'double_6',
      maxTileValue: 6,
      initialHandSize: 7,
      drawRule: 'no_draw',
      maxDrawsPerTurn: 0,
      playImmediately: false,
      autoPass: true,
      startRule: 'highest_double',
      blockRule: 'lowest_pip_count',
      scoringMode: 'target_score',
      targetScore: 100,
      turnTimerSeconds: 30,
    },
  },
  custom: {
    name: 'Personalizado',
    description: 'Configuração totalmente customizada com limites configuráveis.',
    config: {
      playerCount: 2,
      teamMode: 'individual',
      tileset: 'custom',
      maxTileValue: 6,
      initialHandSize: 7,
      drawRule: 'open',
      maxDrawsPerTurn: 99,
      playImmediately: true,
      autoPass: true,
      startRule: 'random',
      blockRule: 'lowest_pip_count',
      scoringMode: 'single_round',
      targetScore: 100,
      turnTimerSeconds: 30,
    },
  },
};

/**
 * Calcula o total de peças em um conjunto duplo-N.
 * Fórmula clássica: (N + 1) * (N + 2) / 2
 */
export function calculateTotalTiles(maxTileValue: number): number {
  const n = Math.max(0, Math.floor(maxTileValue));
  return ((n + 1) * (n + 2)) / 2;
}

/**
 * Validação abrangente de integridade de configuração de regras.
 */
export function validateDominoConfig(config: Partial<DominoRulesConfig>): { valid: boolean; error?: string } {
  if (!config) {
    return { valid: false, error: 'Configuração de regras não informada.' };
  }

  const playerCount = config.playerCount ?? 2;
  if (![2, 3, 4].includes(playerCount)) {
    return { valid: false, error: 'Número de jogadores inválido. Permitido: 2, 3 ou 4 jogadores.' };
  }

  const teamMode = config.teamMode ?? 'individual';
  if (teamMode === 'teams_2v2' && playerCount !== 4) {
    return { valid: false, error: 'O modo de duplas (2v2) exige exatamente 4 jogadores.' };
  }

  const maxVal = config.maxTileValue ?? 6;
  if (maxVal < 3 || maxVal > 12) {
    return { valid: false, error: 'O valor máximo da peça deve estar entre 3 e 12.' };
  }

  const totalTiles = calculateTotalTiles(maxVal);
  const handSize = config.initialHandSize ?? 7;

  if (handSize < 3) {
    return { valid: false, error: 'A quantidade mínima de peças por jogador é 3.' };
  }

  const neededTiles = playerCount * handSize;
  if (neededTiles > totalTiles) {
    return {
      valid: false,
      error: `Distribuição impossível: ${neededTiles} peças necessárias para ${playerCount} jogadores, mas o conjunto duplo-${maxVal} contém apenas ${totalTiles} peças.`,
    };
  }

  if (config.targetScore !== undefined && config.targetScore < 10) {
    return { valid: false, error: 'A meta de pontuação deve ser de no mínimo 10 pontos.' };
  }

  return { valid: true };
}

/**
 * Normaliza e preenche com valores seguros qualquer configuração parcial.
 */
export function normalizeDominoConfig(partial?: Partial<DominoRulesConfig>): DominoRulesConfig {
  const preset = DOMINO_PRESETS.traditional.config;
  const merged: DominoRulesConfig = {
    ...preset,
    ...partial,
  };

  // Ajusta maxTileValue conforme o tileset
  if (merged.tileset === 'double_6') merged.maxTileValue = 6;
  else if (merged.tileset === 'double_9') merged.maxTileValue = 9;
  else if (merged.tileset === 'double_12') merged.maxTileValue = 12;
  else merged.maxTileValue = Math.min(12, Math.max(3, merged.maxTileValue || 6));

  // Ajusta teamMode se jogadores != 4
  if (merged.playerCount !== 4) {
    merged.teamMode = 'individual';
  }

  // Ajusta initialHandSize para nunca estourar o monte
  const total = calculateTotalTiles(merged.maxTileValue);
  const maxHand = Math.floor(total / merged.playerCount);
  merged.initialHandSize = Math.max(3, Math.min(merged.initialHandSize, maxHand));

  return merged;
}
