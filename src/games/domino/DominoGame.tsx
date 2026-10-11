// ============================================================================
// Component: DominoGame — DuoPlay-Online
// Description: Arena multiplayer completa do Dominó Duo com design tátil,
//              tabuleiro interativo com extremidades jogáveis, suporte a
//              regras personalizadas e duplas, e validação no servidor.
// ============================================================================

import React, { useState, useMemo, useEffect, useCallback, useRef } from 'react';
import {
  RotateCw,
  AlertCircle,
  ArrowLeft,
  Sparkles,
  HelpCircle,
  Flag,
  Volume2,
  VolumeX,
  Plus,
  ArrowRight,
  ArrowLeft as ArrowLeftIcon,
  Crown,
  Layers,
  Users,
  CheckCircle2,
  X,
} from 'lucide-react';
import { useGameSession } from '@/multiplayer/hooks/useGameSession';
import { useAuth } from '@/hooks/useAuth';
import { AbandonMatchModal } from '@/components/match/AbandonMatchModal';
import { MatchResultModal } from '@/components/match/MatchResultModal';
import { abandonMatch, claimAbandonment, timeoutMatchTurn } from '@/services/matchSession';
import { PlayerAvatar } from '@/components/profile/PlayerAvatar';
import { fetchPublicProfile, type PublicPlayerProfile } from '@/services/profile';
import { ConnectionStatusIndicator } from '@/components/match/ConnectionStatusIndicator';
import { TurnTimer } from '@/components/match/TurnTimer';
import {
  type DominoTile,
  type DominoGameState,
  type DominoClientGameState,
  type DominoPlacedTile,
  type DominoRulesConfig,
  DOMINO_PRESETS,
} from './types';
import {
  canTileConnect,
  getValidPlays,
  normalizeTile,
  areTilesEqual,
  sumTilePips,
} from './dominoEngine';

interface DominoGameProps {
  matchId: string;
  onLeave: () => void;
  onViewHistory?: () => void;
  onPlayAgain?: () => void;
  onStartRematch?: (newMatchId: string) => void;
  onViewPlayerProfile?: (userId: string) => void;
}

// Síntese de áudio Web Audio API para jogadas táteis
const playTone = (type: 'play' | 'draw' | 'pass' | 'win' | 'error') => {
  if (typeof window === 'undefined') return;
  try {
    const AudioCtx = window.AudioContext || (window as unknown as { webkitAudioContext: typeof AudioContext }).webkitAudioContext;
    if (!AudioCtx) return;
    const ctx = new AudioCtx();
    const osc = ctx.createOscillator();
    const gain = ctx.createGain();
    osc.connect(gain);
    gain.connect(ctx.destination);

    const now = ctx.currentTime;
    if (type === 'play') {
      osc.frequency.setValueAtTime(360, now);
      osc.frequency.exponentialRampToValueAtTime(540, now + 0.1);
      gain.gain.setValueAtTime(0.18, now);
      gain.gain.exponentialRampToValueAtTime(0.01, now + 0.1);
      osc.start(now);
      osc.stop(now + 0.1);
    } else if (type === 'draw') {
      osc.frequency.setValueAtTime(260, now);
      osc.frequency.exponentialRampToValueAtTime(320, now + 0.08);
      gain.gain.setValueAtTime(0.12, now);
      gain.gain.exponentialRampToValueAtTime(0.01, now + 0.08);
      osc.start(now);
      osc.stop(now + 0.08);
    } else if (type === 'pass') {
      osc.frequency.setValueAtTime(200, now);
      gain.gain.setValueAtTime(0.1, now);
      gain.gain.exponentialRampToValueAtTime(0.01, now + 0.12);
      osc.start(now);
      osc.stop(now + 0.12);
    } else if (type === 'win') {
      osc.frequency.setValueAtTime(440, now);
      osc.frequency.setValueAtTime(554, now + 0.1);
      osc.frequency.setValueAtTime(659, now + 0.2);
      gain.gain.setValueAtTime(0.2, now);
      gain.gain.exponentialRampToValueAtTime(0.01, now + 0.35);
      osc.start(now);
      osc.stop(now + 0.35);
    } else if (type === 'error') {
      osc.frequency.setValueAtTime(160, now);
      gain.gain.setValueAtTime(0.15, now);
      gain.gain.exponentialRampToValueAtTime(0.01, now + 0.15);
      osc.start(now);
      osc.stop(now + 0.15);
    }
  } catch {
    // Autoplay policy silenciado
  }
};

/**
 * Renderizador de Pips (Pontos do Dominó)
 */
const DominoPips: React.FC<{ value: number }> = ({ value }) => {
  // Render padrão de dados para valores de 0 a 6
  if (value === 0) {
    return <div className="w-5 h-5 flex items-center justify-center text-[10px] text-slate-500 font-bold">·</div>;
  }

  if (value > 6) {
    return <div className="w-5 h-5 flex items-center justify-center text-xs font-black text-slate-900">{value}</div>;
  }

  const pipsCount = value;
  // Mapas de posições de pontos para uma grade 3x3
  const pipPositions: Record<number, number[]> = {
    1: [4],
    2: [0, 8],
    3: [0, 4, 8],
    4: [0, 2, 6, 8],
    5: [0, 2, 4, 6, 8],
    6: [0, 2, 3, 5, 6, 8],
  };

  const activeIndices = new Set(pipPositions[pipsCount] || []);

  return (
    <div className="w-5 h-5 grid grid-cols-3 grid-rows-3 p-0.5 gap-0.5">
      {Array.from({ length: 9 }).map((_, i) => (
        <div key={i} className="flex items-center justify-center">
          {activeIndices.has(i) && <span className="w-1.5 h-1.5 rounded-full bg-slate-900 shadow-inner" />}
        </div>
      ))}
    </div>
  );
};

/**
 * Componente visual de uma peça de Dominó
 */
const DominoTileView: React.FC<{
  tile: DominoTile;
  isPlayable?: boolean;
  isSelected?: boolean;
  isVertical?: boolean;
  size?: 'sm' | 'md' | 'lg';
  onClick?: () => void;
}> = ({ tile, isPlayable = false, isSelected = false, isVertical = true, size = 'md', onClick }) => {
  const isDouble = tile[0] === tile[1];

  const sizeClasses = {
    sm: 'w-7 h-14',
    md: 'w-10 h-20 sm:w-11 sm:h-22',
    lg: 'w-12 h-24 sm:w-14 sm:h-28',
  };

  const horizSizeClasses = {
    sm: 'w-14 h-7',
    md: 'w-20 h-10 sm:w-22 sm:h-11',
    lg: 'w-24 h-12 sm:w-28 h-14',
  };

  return (
    <button
      type="button"
      onClick={onClick}
      disabled={!onClick}
      className={`relative select-none rounded-lg bg-amber-50 border-2 transition-all duration-150 flex ${
        isVertical ? 'flex-col' : 'flex-row'
      } items-center justify-between p-1 shadow-md ${
        isVertical ? sizeClasses[size] : horizSizeClasses[size]
      } ${
        isSelected
          ? 'ring-4 ring-blue-500 border-blue-400 scale-105 z-20 shadow-blue-500/30'
          : isPlayable
          ? 'border-amber-400 hover:border-blue-400 hover:scale-102 cursor-pointer shadow-amber-300/20'
          : 'border-slate-300 opacity-90 cursor-default'
      } ${isDouble ? 'bg-amber-100/90' : ''}`}
    >
      {/* Metade 1 */}
      <div className="flex-1 flex items-center justify-center">
        <DominoPips value={tile[0]} />
      </div>

      {/* Linha divisória metálica */}
      <div className={`${isVertical ? 'w-full h-0.5' : 'h-full w-0.5'} bg-slate-400/80 rounded`} />

      {/* Metade 2 */}
      <div className="flex-1 flex items-center justify-center">
        <DominoPips value={tile[1]} />
      </div>
    </button>
  );
};

export const DominoGame: React.FC<DominoGameProps> = ({
  matchId,
  onLeave,
  onViewHistory,
  onPlayAgain,
  onStartRematch,
  onViewPlayerProfile,
}) => {
  const { user } = useAuth();
  const currentUserId = user?.id || null;

  const [opponentsProfiles, setOpponentsProfiles] = useState<Record<string, PublicPlayerProfile>>({});
  const [soundEnabled, setSoundEnabled] = useState(true);
  const [showRulesModal, setShowRulesModal] = useState(false);
  const [selectedTile, setSelectedTile] = useState<DominoTile | null>(null);
  const [feedbackError, setFeedbackError] = useState<string | null>(null);
  const [submittingAction, setSubmittingAction] = useState(false);
  const [isAbandonModalOpen, setIsAbandonModalOpen] = useState(false);
  const [isAbandoning, setIsAbandoning] = useState(false);
  const [isResultModalOpen, setIsResultModalOpen] = useState(true);

  const {
    snapshot,
    syncState,
    error: sessionError,
    isLoading,
    isMyTurn,
    myPlayer,
    submitAction,
    refresh,
    reconnect,
  } = useGameSession<DominoGameState | DominoClientGameState>(matchId);

  const state = snapshot?.state;
  const isFinished = snapshot?.status === 'finished' || snapshot?.status === 'abandoned';

  // Configurações ativas da partida
  const config: DominoRulesConfig = useMemo(() => {
    return (
      (state?.config as DominoRulesConfig) ||
      DOMINO_PRESETS.traditional.config
    );
  }, [state?.config]);

  // Tabuleiro e extremidades
  const board = state?.board || { tiles: [], leftEnd: null, rightEnd: null };
  const leftEnd = board.leftEnd;
  const rightEnd = board.rightEnd;

  // Mão visível do jogador (suporta tanto DominoClientGameState projetado quanto DominoGameState)
  const myHand: DominoTile[] = useMemo(() => {
    if (!state) return [];
    if ('myHand' in state && Array.isArray((state as DominoClientGameState).myHand)) {
      return (state as DominoClientGameState).myHand;
    }
    if ('hands' in state && currentUserId && (state as DominoGameState).hands?.[currentUserId]) {
      return (state as DominoGameState).hands[currentUserId] || [];
    }
    return [];
  }, [state, currentUserId]);

  // Contagem de peças dos oponentes
  const handsCount: Record<string, number> = useMemo(() => {
    if (!state) return {};
    if ('handsCount' in state) {
      return (state as DominoClientGameState).handsCount || {};
    }
    if ('hands' in state && (state as DominoGameState).hands) {
      const res: Record<string, number> = {};
      for (const [k, v] of Object.entries((state as DominoGameState).hands || {})) {
        res[k] = (v || []).length;
      }
      return res;
    }
    return {};
  }, [state]);

  // Peças restantes no monte
  const boneyardCount: number = useMemo(() => {
    if (!state) return 0;
    if ('boneyardCount' in state) {
      return (state as DominoClientGameState).boneyardCount || 0;
    }
    if ('boneyard' in state && Array.isArray((state as DominoGameState).boneyard)) {
      return (state as DominoGameState).boneyard.length;
    }
    return 0;
  }, [state]);

  // Jogadas válidas na mão atual
  const validPlays = useMemo(() => {
    return getValidPlays(myHand, leftEnd, rightEnd);
  }, [myHand, leftEnd, rightEnd]);

  const hasAnyValidPlay = validPlays.length > 0;

  // Oponentes na partida
  const opponents = useMemo(() => {
    if (!snapshot) return [];
    return snapshot.players.filter((p) => p.userId !== currentUserId);
  }, [snapshot, currentUserId]);

  // Carrega perfis dos oponentes
  useEffect(() => {
    opponents.forEach((opp) => {
      if (opp.userId && !opponentsProfiles[opp.userId]) {
        fetchPublicProfile(opp.userId).then((res) => {
          if (res.success && res.data) {
            setOpponentsProfiles((prev) => ({
              ...prev,
              [opp.userId]: res.data!,
            }));
          }
        });
      }
    });
  }, [opponents, opponentsProfiles]);

  // Limpa seleção se não for meu turno ou se a peça não estiver mais na mão
  useEffect(() => {
    if (!isMyTurn) {
      setSelectedTile(null);
    }
    if (selectedTile && !myHand.some((t) => areTilesEqual(t, selectedTile))) {
      setSelectedTile(null);
    }
  }, [isMyTurn, myHand, selectedTile]);

  // Ação 1: Jogar Peça no Tabuleiro
  const handlePlayTile = async (tile: DominoTile, side: 'left' | 'right') => {
    if (!isMyTurn || submittingAction || isFinished) return;
    setSubmittingAction(true);
    setFeedbackError(null);

    if (soundEnabled) playTone('play');

    const result = await submitAction('play_tile', {
      tile: [tile[0], tile[1]],
      side,
    });

    setSubmittingAction(false);

    if (!result.accepted) {
      if (soundEnabled) playTone('error');
      setFeedbackError(result.error?.message || 'Jogada inválida rejeitada pelo servidor.');
    } else {
      setSelectedTile(null);
    }
  };

  // Clique em uma peça da mão
  const handleTileClick = (tile: DominoTile) => {
    if (!isMyTurn || isFinished) return;

    // Se o tabuleiro estiver vazio, joga direto na primeira ponta
    if (leftEnd === null || rightEnd === null) {
      handlePlayTile(tile, 'left');
      return;
    }

    const canLeft = canTileConnect(tile, leftEnd);
    const canRight = canTileConnect(tile, rightEnd);

    if (!canLeft && !canRight) {
      setFeedbackError(`Esta peça não encaixa em nenhuma das pontas abertas (${leftEnd} ou ${rightEnd}).`);
      if (soundEnabled) playTone('error');
      return;
    }

    // Se encaixar nas duas pontas, seleciona para o jogador escolher o lado
    if (canLeft && canRight) {
      setSelectedTile(tile);
      return;
    }

    // Se encaixar apenas na esquerda
    if (canLeft) {
      handlePlayTile(tile, 'left');
      return;
    }

    // Se encaixar apenas na direita
    if (canRight) {
      handlePlayTile(tile, 'right');
      return;
    }
  };

  // Ação 2: Comprar Peça do Monte
  const handleDrawTile = async () => {
    if (!isMyTurn || submittingAction || isFinished) return;
    if (hasAnyValidPlay) {
      setFeedbackError('Você já possui peças válidas na mão e não pode comprar.');
      if (soundEnabled) playTone('error');
      return;
    }
    if (boneyardCount <= 0) {
      setFeedbackError('O monte de compra está vazio.');
      return;
    }
    if (config.drawRule === 'no_draw' || (config.drawRule as string) === 'block') {
      setFeedbackError('A regra desta sala não permite compra de peças.');
      return;
    }

    setSubmittingAction(true);
    setFeedbackError(null);

    if (soundEnabled) playTone('draw');

    const result = await submitAction('draw_tile', {});
    setSubmittingAction(false);

    if (!result.accepted) {
      if (soundEnabled) playTone('error');
      setFeedbackError(result.error?.message || 'Não foi possível comprar peça.');
    }
  };

  // Ação 3: Passar Vez
  const handlePassTurn = async () => {
    if (!isMyTurn || submittingAction || isFinished) return;
    if (hasAnyValidPlay) {
      setFeedbackError('Você possui peças jogáveis na sua mão e não pode passar.');
      if (soundEnabled) playTone('error');
      return;
    }
    if (boneyardCount > 0 && config.drawRule === 'open') {
      setFeedbackError('Você deve comprar peças do monte até conseguir jogar ou esvaziar o monte antes de passar.');
      if (soundEnabled) playTone('error');
      return;
    }

    setSubmittingAction(true);
    setFeedbackError(null);

    if (soundEnabled) playTone('pass');

    const result = await submitAction('pass_turn', {});
    setSubmittingAction(false);

    if (!result.accepted) {
      if (soundEnabled) playTone('error');
      setFeedbackError(result.error?.message || 'Não foi possível passar a vez.');
    }
  };

  // Auto-pass se configurado e o jogador não puder jogar nem comprar
  useEffect(() => {
    if (!isMyTurn || submittingAction || isFinished) return;
    const drawsThisTurn = state?.drawsThisTurn ?? 0;
    const canDraw =
      boneyardCount > 0 &&
      config.drawRule !== 'no_draw' &&
      (config.drawRule as string) !== 'block' &&
      (config.drawRule !== 'one_tile' || drawsThisTurn === 0) &&
      (config.drawRule !== 'custom_limit' || drawsThisTurn < config.maxDrawsPerTurn);

    if (config.autoPass && !hasAnyValidPlay && !canDraw) {
      const timer = setTimeout(() => {
        handlePassTurn();
      }, 1200);
      return () => clearTimeout(timer);
    }
  }, [
    isMyTurn,
    submittingAction,
    isFinished,
    config.autoPass,
    hasAnyValidPlay,
    boneyardCount,
    config.drawRule,
    config.maxDrawsPerTurn,
    state?.drawsThisTurn,
  ]);

  // Loading inicial
  if (isLoading || !snapshot) {
    return (
      <div className="flex flex-col items-center justify-center min-h-[60vh] space-y-4 px-4">
        <div className="w-12 h-12 rounded-2xl bg-amber-500/20 border border-amber-500/40 flex items-center justify-center text-amber-400">
          <RotateCw className="w-6 h-6 animate-spin text-amber-400" />
        </div>
        <div className="text-center space-y-1">
          <h2 className="text-base font-bold text-white">Carregando Dominó Duo</h2>
          <p className="text-xs text-slate-400">Consultando o tabuleiro oficial no servidor...</p>
        </div>
      </div>
    );
  }

  const currentTurnPlayer = snapshot.players.find((p) => p.userId === snapshot.currentTurnPlayerId);
  const isSelectedTileCanLeft = selectedTile && leftEnd !== null ? canTileConnect(selectedTile, leftEnd) : false;
  const isSelectedTileCanRight = selectedTile && rightEnd !== null ? canTileConnect(selectedTile, rightEnd) : false;

  return (
    <div className="w-full max-w-5xl mx-auto px-3 sm:px-6 py-4 flex flex-col min-h-[85vh] justify-between">
      {/* 1. BARRA SUPERIOR — STATUS, OPONENTES E CONTROLES */}
      <header className="space-y-3 pb-3 border-b border-slate-800">
        <div className="flex items-center justify-between">
          <div className="flex items-center gap-2.5">
            <button
              type="button"
              onClick={onLeave}
              className="p-2 rounded-xl bg-slate-900 border border-slate-800 text-slate-400 hover:text-white transition-colors"
              title="Voltar para a Home"
            >
              <ArrowLeft className="w-4 h-4" />
            </button>
            <div>
              <div className="flex items-center gap-2">
                <span className="w-2.5 h-2.5 rounded-full bg-amber-400 animate-pulse" />
                <h1 className="text-base sm:text-lg font-black text-white tracking-tight">Dominó Duo</h1>
                <span className="text-[10px] uppercase font-bold tracking-wider px-2 py-0.5 rounded bg-amber-500/20 border border-amber-500/30 text-amber-300">
                  {config.teamMode === 'teams_2v2' ? 'Duplas 2v2' : `${snapshot.players.length} Jogadores`}
                </span>
              </div>
              <p className="text-[11px] text-slate-400">
                Conjunto Duplo-{config.maxTileValue} · {config.scoringMode === 'single_round' ? 'Partida Única' : `Meta ${config.targetScore} pts`}
              </p>
            </div>
          </div>

          <div className="flex items-center gap-1.5 sm:gap-2">
            <ConnectionStatusIndicator syncState={syncState} />

            <button
              type="button"
              onClick={() => setShowRulesModal(true)}
              className="p-2 rounded-xl bg-slate-900 border border-slate-800 text-slate-400 hover:text-white transition-colors"
              title="Ver Regras da Sala"
            >
              <HelpCircle className="w-4 h-4" />
            </button>

            <button
              type="button"
              onClick={() => setSoundEnabled((v) => !v)}
              className="p-2 rounded-xl bg-slate-900 border border-slate-800 text-slate-400 hover:text-white transition-colors"
              title={soundEnabled ? 'Silenciar Áudio' : 'Ativar Áudio'}
            >
              {soundEnabled ? <Volume2 className="w-4 h-4 text-amber-400" /> : <VolumeX className="w-4 h-4" />}
            </button>

            <button
              type="button"
              onClick={() => setIsAbandonModalOpen(true)}
              className="p-2 rounded-xl bg-red-950/40 border border-red-800/60 text-red-400 hover:bg-red-900/50 transition-colors"
              title="Abandonar Partida"
            >
              <Flag className="w-4 h-4" />
            </button>
          </div>
        </div>

        {/* HUD DOS OPONENTES */}
        <div className="flex flex-wrap items-center justify-center sm:justify-start gap-2.5 pt-1">
          {snapshot.players.map((p, idx) => {
            const isItMyPlayer = p.userId === currentUserId;
            const isTurn = p.userId === snapshot.currentTurnPlayerId;
            const profile = opponentsProfiles[p.userId];
            const pCount = handsCount[p.userId] ?? (isItMyPlayer ? myHand.length : 0);
            const pScore = (state?.scores as Record<string, number>)?.[p.userId] ?? p.score ?? 0;

            return (
              <div
                key={p.userId}
                className={`flex items-center gap-2 px-3 py-1.5 rounded-xl border transition-all ${
                  isTurn
                    ? 'bg-amber-950/40 border-amber-500/80 shadow-md shadow-amber-950/30'
                    : 'bg-slate-900/80 border-slate-800'
                }`}
              >
                <div className="relative">
                  <div className="w-7 h-7 rounded-lg overflow-hidden bg-slate-800 flex items-center justify-center text-xs font-bold text-white">
                    {profile?.avatarUrl ? (
                      <img src={profile.avatarUrl} alt="" className="w-full h-full object-cover" />
                    ) : (
                      p.slot
                    )}
                  </div>
                  {isTurn && (
                    <span className="absolute -top-1 -right-1 w-2.5 h-2.5 rounded-full bg-amber-400 animate-ping" />
                  )}
                </div>

                <div className="text-left">
                  <div className="flex items-center gap-1">
                    <span className="text-xs font-bold text-white truncate max-w-[5rem] sm:max-w-[7rem]">
                      {isItMyPlayer ? 'Você' : profile?.displayName || `Jogador ${p.slot}`}
                    </span>
                    {config.teamMode === 'teams_2v2' && (
                      <span className="text-[9px] font-black uppercase text-amber-400">
                        {p.slot % 2 !== 0 ? '(A)' : '(B)'}
                      </span>
                    )}
                  </div>
                  <div className="text-[10px] text-slate-400 flex items-center gap-1.5">
                    <span className="font-semibold text-amber-300">🀰 {pCount} peças</span>
                    <span>·</span>
                    <span>{pScore} pts</span>
                  </div>
                </div>
              </div>
            );
          })}
        </div>

        {/* INDICADOR DE TURNO E TEMPORIZADOR */}
        <div className="flex items-center justify-between px-3 py-2 rounded-xl bg-slate-900/90 border border-slate-800 text-xs">
          <div className="flex items-center gap-2">
            <span
              className={`w-2 h-2 rounded-full ${
                isMyTurn ? 'bg-emerald-400 animate-pulse' : 'bg-amber-400'
              }`}
            />
            <span className="font-bold text-white">
              {isMyTurn ? 'SEU TURNO: Escolha uma peça ou compre no monte' : `Vez de ${currentTurnPlayer ? `Jogador ${currentTurnPlayer.slot}` : 'Adversário'}`}
            </span>
          </div>

          {snapshot.turnDeadline && !isFinished && (
            <TurnTimer
              turnDeadline={snapshot.turnDeadline}
              isMyTurn={Boolean(isMyTurn)}
              onVisualZero={() => {
                if (matchId && snapshot.turnNumber) {
                  timeoutMatchTurn(matchId, snapshot.turnNumber);
                }
              }}
            />
          )}
        </div>
      </header>

      {/* FEEDBACK DE ERRO */}
      {feedbackError && (
        <div className="my-2 p-3 rounded-xl bg-red-950/70 border border-red-800 text-red-200 text-xs flex items-center justify-between animate-fade-in">
          <div className="flex items-center gap-2">
            <AlertCircle className="w-4 h-4 shrink-0 text-red-400" />
            <span>{feedbackError}</span>
          </div>
          <button type="button" onClick={() => setFeedbackError(null)} className="text-slate-400 hover:text-white">
            <X className="w-4 h-4" />
          </button>
        </div>
      )}

      {/* 2. TABULEIRO CENTRAL DE JOGO (CHAIN / CADEIA DE PEÇAS) */}
      <main className="my-4 flex-1 flex flex-col justify-center items-center relative min-h-[300px] sm:min-h-[360px] p-4 rounded-2xl bg-slate-950/60 border border-slate-900 overflow-hidden shadow-inner">
        {/* Glow de fundo */}
        <div className="absolute inset-0 bg-radial from-amber-950/15 via-transparent to-transparent pointer-events-none" />

        {/* Indicadores de extremidades abertas */}
        <div className="absolute top-3 inset-x-4 flex justify-between items-center text-xs pointer-events-none z-10">
          <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-slate-900/90 border border-slate-800 text-slate-300 shadow">
            <ArrowLeftIcon className="w-3.5 h-3.5 text-amber-400" />
            <span className="text-[11px] font-bold">Ponta Esquerda:</span>
            <span className="font-black text-amber-400 text-sm">
              {leftEnd !== null ? leftEnd : '—'}
            </span>
          </div>

          <div className="flex items-center gap-1.5 px-2.5 py-1 rounded-lg bg-slate-900/90 border border-slate-800 text-slate-300 shadow">
            <span className="text-[11px] font-bold">Ponta Direita:</span>
            <span className="font-black text-amber-400 text-sm">
              {rightEnd !== null ? rightEnd : '—'}
            </span>
            <ArrowRight className="w-3.5 h-3.5 text-amber-400" />
          </div>
        </div>

        {/* CADEIA DE PEÇAS NO TABULEIRO */}
        {board.tiles.length === 0 ? (
          <div className="text-center space-y-2 py-12">
            <div className="w-16 h-16 rounded-2xl bg-amber-500/10 border border-amber-500/30 flex items-center justify-center text-amber-400 mx-auto animate-pulse">
              <Sparkles className="w-8 h-8" />
            </div>
            <h3 className="text-sm sm:text-base font-bold text-white">Tabuleiro Vazio</h3>
            <p className="text-xs text-slate-400 max-w-xs">
              {isMyTurn ? 'Você começa a partida! Escolha qualquer peça da sua mão para iniciar a cadeia.' : 'Aguardando o primeiro jogador iniciar a mesa...'}
            </p>
          </div>
        ) : (
          <div className="w-full overflow-x-auto flex items-center justify-start sm:justify-center gap-1.5 py-8 px-4 scrollbar-thin">
            {/* Botão de Encaixe na Ponta Esquerda (visível se tiver peça selecionada) */}
            {selectedTile && isSelectedTileCanLeft && (
              <button
                type="button"
                onClick={() => handlePlayTile(selectedTile, 'left')}
                className="shrink-0 flex flex-col items-center justify-center w-12 h-20 rounded-lg bg-blue-600/30 border-2 border-dashed border-blue-400 hover:bg-blue-600/50 text-blue-200 transition-all animate-pulse"
                title="Encaixar na Ponta Esquerda"
              >
                <ArrowLeftIcon className="w-5 h-5 text-blue-400" />
                <span className="text-[10px] font-black uppercase mt-1">Jogar</span>
              </button>
            )}

            {/* Peças dispostas na mesa */}
            {board.tiles.map((placed, i) => (
              <div key={placed.id || i} className="shrink-0 transform hover:scale-105 transition-transform">
                <DominoTileView
                  tile={placed.tile}
                  isVertical={placed.tile[0] === placed.tile[1]} // Duplas ficam em pé na mesa tradicional!
                  size="md"
                />
              </div>
            ))}

            {/* Botão de Encaixe na Ponta Direita (visível se tiver peça selecionada) */}
            {selectedTile && isSelectedTileCanRight && (
              <button
                type="button"
                onClick={() => handlePlayTile(selectedTile, 'right')}
                className="shrink-0 flex flex-col items-center justify-center w-12 h-20 rounded-lg bg-blue-600/30 border-2 border-dashed border-blue-400 hover:bg-blue-600/50 text-blue-200 transition-all animate-pulse"
                title="Encaixar na Ponta Direita"
              >
                <ArrowRight className="w-5 h-5 text-blue-400" />
                <span className="text-[10px] font-black uppercase mt-1">Jogar</span>
              </button>
            )}
          </div>
        )}
      </main>

      {/* 3. BASE INFERIOR — MÃO DO JOGADOR E AÇÕES RÁPIDAS */}
      <footer className="space-y-3 pt-3 border-t border-slate-800">
        {/* Barra de Ações: Comprar do Monte e Passar a Vez */}
        <div className="flex items-center justify-between gap-3">
          <div className="flex items-center gap-2">
            <button
              type="button"
              onClick={handleDrawTile}
              disabled={
                !isMyTurn ||
                submittingAction ||
                boneyardCount <= 0 ||
                config.drawRule === 'no_draw' ||
                (config.drawRule as string) === 'block' ||
                hasAnyValidPlay ||
                (config.drawRule === 'one_tile' && (state?.drawsThisTurn ?? 0) >= 1) ||
                (config.drawRule === 'custom_limit' && (state?.drawsThisTurn ?? 0) >= config.maxDrawsPerTurn)
              }
              className="px-3.5 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 border border-slate-750 text-white font-bold text-xs flex items-center gap-2 transition-all disabled:opacity-40 disabled:cursor-not-allowed shadow-sm"
              title={
                hasAnyValidPlay
                  ? 'Você já possui peças válidas na mão'
                  : boneyardCount <= 0
                  ? 'Monte vazio'
                  : config.drawRule === 'no_draw' || (config.drawRule as string) === 'block'
                  ? 'Compra não permitida'
                  : (config.drawRule === 'one_tile' && (state?.drawsThisTurn ?? 0) >= 1)
                  ? 'Limite de 1 compra atingido'
                  : (config.drawRule === 'custom_limit' && (state?.drawsThisTurn ?? 0) >= config.maxDrawsPerTurn)
                  ? 'Limite de compras atingido'
                  : 'Comprar peça do monte'
              }
            >
              <Plus className="w-4 h-4 text-amber-400" />
              <span>Comprar do Monte</span>
              <span className="px-1.5 py-0.5 rounded bg-amber-500/20 text-amber-300 font-mono text-[11px]">
                {boneyardCount}
              </span>
            </button>

            <button
              type="button"
              onClick={handlePassTurn}
              disabled={
                !isMyTurn ||
                submittingAction ||
                hasAnyValidPlay ||
                (boneyardCount > 0 && config.drawRule === 'open') ||
                (boneyardCount > 0 && config.drawRule === 'one_tile' && (state?.drawsThisTurn ?? 0) === 0) ||
                (boneyardCount > 0 && config.drawRule === 'custom_limit' && (state?.drawsThisTurn ?? 0) < config.maxDrawsPerTurn)
              }
              className="px-3.5 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 border border-slate-750 text-white font-bold text-xs flex items-center gap-2 transition-all disabled:opacity-40 disabled:cursor-not-allowed shadow-sm"
              title={
                hasAnyValidPlay
                  ? 'Você tem peças válidas para jogar'
                  : (boneyardCount > 0 && config.drawRule === 'open')
                  ? 'Você deve comprar peças do monte antes de passar'
                  : (boneyardCount > 0 && config.drawRule === 'one_tile' && (state?.drawsThisTurn ?? 0) === 0)
                  ? 'Você deve comprar uma peça do monte antes de passar'
                  : (boneyardCount > 0 && config.drawRule === 'custom_limit' && (state?.drawsThisTurn ?? 0) < config.maxDrawsPerTurn)
                  ? 'Você deve comprar até o limite antes de passar'
                  : 'Passar a vez para o próximo jogador'
              }
            >
              <span>Passar Turno</span>
            </button>
          </div>

          <div className="text-right text-xs">
            <span className="text-slate-400">Sua Mão: </span>
            <span className="font-extrabold text-white">{myHand.length} peças</span>
            <span className="text-slate-500 text-[11px] ml-1.5">
              ({sumTilePips(myHand)} pts)
            </span>
          </div>
        </div>

        {/* DOCK DA MÃO DO JOGADOR */}
        <div className="p-3 rounded-2xl bg-slate-900/90 border border-slate-800 shadow-xl">
          <div className="flex items-center justify-start sm:justify-center gap-2.5 overflow-x-auto py-1 scrollbar-thin">
            {myHand.length === 0 ? (
              <div className="py-6 text-center text-xs text-slate-500">
                Você não possui peças na mão.
              </div>
            ) : (
              myHand.map((tile, idx) => {
                const canConnectLeft = leftEnd === null ? true : canTileConnect(tile, leftEnd);
                const canConnectRight = rightEnd === null ? true : canTileConnect(tile, rightEnd);
                const isPlayable = isMyTurn && (canConnectLeft || canConnectRight);
                const isSelected = selectedTile ? areTilesEqual(tile, selectedTile) : false;

                return (
                  <div key={`${tile[0]}-${tile[1]}-${idx}`} className="shrink-0 flex flex-col items-center gap-1">
                    <DominoTileView
                      tile={tile}
                      isPlayable={isPlayable}
                      isSelected={isSelected}
                      size="md"
                      onClick={submittingAction ? undefined : () => handleTileClick(tile)}
                    />
                    {isPlayable && (
                      <span className="w-1.5 h-1.5 rounded-full bg-emerald-400" />
                    )}
                  </div>
                );
              })
            )}
          </div>
        </div>

        {/* Instrução contextual para o jogador */}
        {selectedTile && (
          <div className="p-2.5 rounded-xl bg-blue-950/60 border border-blue-800/80 text-blue-200 text-xs flex items-center justify-between animate-fade-in">
            <span>
              Peça <code className="font-bold">[{selectedTile[0]}|{selectedTile[1]}]</code> selecionada. Escolha a ponta no tabuleiro para encaixar:
            </span>
            <div className="flex gap-2">
              {isSelectedTileCanLeft && (
                <button
                  type="button"
                  onClick={() => handlePlayTile(selectedTile, 'left')}
                  className="px-2.5 py-1 rounded bg-blue-600 hover:bg-blue-500 font-bold text-[11px] text-white"
                >
                  Ponta Esquerda
                </button>
              )}
              {isSelectedTileCanRight && (
                <button
                  type="button"
                  onClick={() => handlePlayTile(selectedTile, 'right')}
                  className="px-2.5 py-1 rounded bg-blue-600 hover:bg-blue-500 font-bold text-[11px] text-white"
                >
                  Ponta Direita
                </button>
              )}
              <button
                type="button"
                onClick={() => setSelectedTile(null)}
                className="px-2 py-1 rounded bg-slate-800 hover:bg-slate-700 text-[11px] text-slate-300"
              >
                Cancelar
              </button>
            </div>
          </div>
        )}
      </footer>

      {/* MODAL DE REGRAS DA SALA */}
      {showRulesModal && (
        <div
          role="dialog"
          aria-modal="true"
          className="fixed inset-0 z-50 flex items-center justify-center p-4 bg-slate-950/80 backdrop-blur-sm animate-fade-in"
        >
          <div className="w-full max-w-md rounded-2xl bg-slate-900 border border-slate-800 p-6 space-y-4 shadow-2xl">
            <div className="flex items-center justify-between pb-3 border-b border-slate-800">
              <h3 className="text-base font-bold text-white flex items-center gap-2">
                <Sparkles className="w-4 h-4 text-amber-400" />
                <span>Regras Desta Sala — Dominó Duo</span>
              </h3>
              <button
                type="button"
                onClick={() => setShowRulesModal(false)}
                className="p-1 rounded-lg text-slate-400 hover:text-white"
              >
                <X className="w-5 h-5" />
              </button>
            </div>

            <div className="space-y-2.5 text-xs text-slate-300">
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Modalidade:</span>
                <span className="font-bold text-white">{config.teamMode === 'teams_2v2' ? 'Duplas (2v2)' : 'Individual'}</span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Conjunto de Peças:</span>
                <span className="font-bold text-white">Duplo-{config.maxTileValue} ({(config.maxTileValue + 1) * (config.maxTileValue + 2) / 2} peças)</span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Peças por Jogador:</span>
                <span className="font-bold text-white">{config.initialHandSize} peças</span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Regra de Compra:</span>
                <span className="font-bold text-white">
                  {config.drawRule === 'open' ? 'Compra Livre' : config.drawRule === 'one_tile' ? '1 Peça por turno' : 'Sem Compra'}
                </span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Passagem Automática:</span>
                <span className="font-bold text-white">{config.autoPass ? 'Ativada' : 'Manual'}</span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Início de Partida:</span>
                <span className="font-bold text-white">
                  {config.startRule === 'highest_double' ? 'Maior Dupla' : config.startRule === 'random' ? 'Sorteio Aleatório' : 'Maior Peça'}
                </span>
              </div>
              <div className="flex justify-between py-1 border-b border-slate-800/60">
                <span className="text-slate-400">Pontuação:</span>
                <span className="font-bold text-white">
                  {config.scoringMode === 'single_round' ? 'Partida Única' : `Meta de ${config.targetScore} pontos`}
                </span>
              </div>
              <div className="flex justify-between py-1">
                <span className="text-slate-400">Tempo por Turno:</span>
                <span className="font-bold text-white">{config.turnTimerSeconds > 0 ? `${config.turnTimerSeconds} segundos` : 'Sem limite'}</span>
              </div>
            </div>

            <button
              type="button"
              onClick={() => setShowRulesModal(false)}
              className="w-full py-2.5 rounded-xl bg-amber-600 hover:bg-amber-500 font-bold text-xs text-slate-950 transition-colors"
            >
              Entendido
            </button>
          </div>
        </div>
      )}

      {/* MODAL DE RESULTADO DA PARTIDA */}
      {isFinished && isResultModalOpen && (
        <MatchResultModal
          isOpen={isResultModalOpen}
          matchId={matchId}
          gameName="Dominó Duo"
          status={snapshot.status}
          winnerId={snapshot.winnerId}
          isDraw={snapshot.isDraw}
          finishReason={snapshot.finishReason}
          currentUserId={currentUserId}
          myPlayer={
            myPlayer
              ? {
                  userId: currentUserId,
                  gameSymbol: 'Dominó',
                  slot: myPlayer.slot,
                  displayName: user?.user_metadata?.display_name || user?.email?.split('@')[0] || 'Você',
                }
              : null
          }
          opponentPlayer={
            opponents[0]
              ? {
                  userId: opponents[0].userId,
                  gameSymbol: 'Dominó',
                  slot: opponents[0].slot,
                  displayName: opponentsProfiles[opponents[0].userId]?.displayName || `Jogador ${opponents[0].slot}`,
                  avatarUrl: opponentsProfiles[opponents[0].userId]?.avatarUrl,
                }
              : null
          }
          onViewUserProfile={onViewPlayerProfile}
          onGoHome={onLeave}
          onViewHistory={onViewHistory || onLeave}
          onStartRematch={onStartRematch}
        />
      )}

      {/* MODAL DE ABANDONO */}
      <AbandonMatchModal
        isOpen={isAbandonModalOpen}
        isLoading={isAbandoning}
        onCancel={() => setIsAbandonModalOpen(false)}
        onConfirm={async () => {
          setIsAbandoning(true);
          try {
            await abandonMatch(matchId);
            onLeave();
          } catch {
            setIsAbandoning(false);
          }
        }}
      />
    </div>
  );
};
