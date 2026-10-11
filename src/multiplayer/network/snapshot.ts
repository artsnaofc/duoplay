// ============================================================================
// Network Engine: Snapshot Retrieval & Mapping — DuoPlay-Online
// Phase: Fase 6.1 — Hardening do Supabase Realtime
// ============================================================================

import { supabase } from '@/lib/supabase';
import type { GameSnapshot, MatchPlayerSnapshot } from './types';
import { normalizeNetworkError } from './errors';
import type { MatchPlayerRow, MatchRow } from '@/types/database';

export type SnapshotFetcher = <TState = unknown>(
  matchId: string
) => Promise<GameSnapshot<TState>>;

let customSnapshotFetcher: SnapshotFetcher | null = null;

/**
 * Permite configurar um provedor customizado de snapshots para suítes de testes unitários isoladas.
 */
export function setSnapshotFetcherForTest(fetcher: SnapshotFetcher | null): void {
  customSnapshotFetcher = fetcher;
}

/**
 * Calcula uma versão monotônica estrita a partir de dados oficiais do PostgreSQL.
 * Nunca utiliza timestamps ou contadores locais do cliente.
 */
export function calculateMonotonicVersion(
  turnNumber: number,
  actionHistoryLength: number,
  isFinished: boolean
): number {
  const baseVersion = Math.max(turnNumber, actionHistoryLength);
  return isFinished ? baseVersion + 1 : baseVersion;
}

/**
 * Converte linhas relacionais do banco em MatchPlayerSnapshot tipado.
 */
export function mapMatchPlayerRow(row: Partial<MatchPlayerRow>): MatchPlayerSnapshot {
  const isDisconnected = Boolean(row.disconnected_at) || row.connection_status === 'disconnected';
  return {
    userId: row.user_id || '',
    slot: row.slot ?? 1,
    gameSymbol: row.game_symbol ?? null,
    score: row.score ?? 0,
    isWinner: Boolean(row.is_winner),
    disconnectedAt: row.disconnected_at ?? null,
    gracePeriodExpiresAt: row.grace_period_expires_at ?? null,
    lastSeenAt: row.last_seen_at ?? null,
    connectionStatus: isDisconnected ? 'disconnected' : 'connected',
    joinedAt: row.joined_at || new Date().toISOString(),
  };
}

/**
 * Mapeia os dados do PostgreSQL para o objeto imutável GameSnapshot<TState>.
 */
export function mapDatabaseToGameSnapshot<TState = unknown>(
  matchData: MatchRow & { match_players?: MatchPlayerRow[] | null }
): GameSnapshot<TState> {
  const rawPlayers = Array.isArray(matchData.match_players) ? matchData.match_players : [];
  const sortedPlayers = [...rawPlayers]
    .sort((a, b) => (a.slot ?? 0) - (b.slot ?? 0))
    .map(mapMatchPlayerRow);

  const rawActionHistory = Array.isArray(matchData.action_history)
    ? matchData.action_history
    : [];

  const turnNumber = matchData.turn_number ?? 1;
  const isFinished = matchData.status === 'finished';
  const version = calculateMonotonicVersion(turnNumber, rawActionHistory.length, isFinished);

  return {
    matchId: matchData.id,
    roomId: matchData.room_id,
    gameId: matchData.game_id,
    status: matchData.status,
    state: (matchData.game_state as TState) ?? ({} as TState),
    currentTurnPlayerId: matchData.current_turn_player_id,
    turnNumber,
    turnDeadline: matchData.turn_deadline,
    winnerId: matchData.winner_id,
    isDraw: Boolean(matchData.is_draw),
    finishReason: matchData.finish_reason,
    players: sortedPlayers,
    version,
    actionHistory: rawActionHistory as unknown as GameSnapshot['actionHistory'],
    createdAt: matchData.created_at,
    startedAt: matchData.started_at,
    finishedAt: matchData.finished_at,
  };
}

/**
 * Consulta o estado oficial da partida no PostgreSQL em uma única operação.
 * Retorna o snapshot completo tipado.
 */
export async function getMatchSnapshot<TState = unknown>(
  matchId: string
): Promise<GameSnapshot<TState>> {
  if (customSnapshotFetcher) {
    return customSnapshotFetcher<TState>(matchId);
  }

  if (!matchId || typeof matchId !== 'string') {
    throw normalizeNetworkError({
      code: 'INVALID_MATCH_ID',
      message: 'Identificador da partida inválido.',
      category: 'rule',
    });
  }

  try {
    // Consulta exclusivamente via RPC autoritativa com verificação estrita de autenticação,
    // pertencimento à partida e sanitização de dados privados (mãos adversárias e monte).
    // Jamais consulta diretamente a tabela 'matches' para evitar qualquer exposição de estado privado.
    // eslint-disable-next-line @typescript-eslint/no-explicit-any
    const { data: rpcRes, error: rpcErr } = await (supabase.rpc as any)('get_match_snapshot_for_player', {
      p_match_id: matchId,
    });

    if (rpcErr) {
      const errCode = (rpcErr as any)?.code;
      const errMsg = String((rpcErr as any)?.message || '');
      if (
        errCode === 'P0001' ||
        errCode === 'P0003' ||
        errCode === 'P0016' ||
        errMsg.includes('UNAUTHORIZED') ||
        errMsg.includes('FORBIDDEN') ||
        errMsg.includes('MATCH_NOT_FOUND')
      ) {
        throw normalizeNetworkError({
          code: errCode === 'P0001' ? 'UNAUTHORIZED' : errCode === 'P0003' ? 'FORBIDDEN' : 'MATCH_NOT_FOUND',
          message: errMsg || 'Acesso não autorizado aos dados da partida.',
          category: 'rule',
        });
      }
      throw normalizeNetworkError(rpcErr);
    }

    if (!rpcRes || !rpcRes.success || !rpcRes.data) {
      throw normalizeNetworkError({
        code: 'MATCH_NOT_FOUND',
        message: rpcRes?.error || 'Partida não encontrada ou sem permissão de visualização.',
        category: 'rule',
      });
    }

    return mapDatabaseToGameSnapshot<TState>(
      rpcRes.data as unknown as MatchRow & { match_players: MatchPlayerRow[] }
    );
  } catch (err) {
    throw normalizeNetworkError(err);
  }
}
