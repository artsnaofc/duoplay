// ============================================================================
// Page: LeaderboardPage — DuoPlay-Online
// Phase: Transformação de Modais em Páginas Dedicadas & Redesign de Ranking
// Description: Página completa e responsiva de Classificação e Ranking Geral
//              e por Jogo, com pódio dos Top 3, busca em tempo real, cartão fixo
//              do usuário logado e navegação fluida.
// ============================================================================

import React, { useState, useEffect, useCallback, useMemo } from 'react';
import {
  Trophy,
  ArrowLeft,
  Medal,
  Award,
  Zap,
  Flame,
  Search,
  RefreshCw,
  Crown,
  Shield,
  TrendingUp,
  User,
  Swords,
  ChevronRight,
  ExternalLink,
  Sparkles,
} from 'lucide-react';
import { fetchLeaderboard, type LeaderboardEntry, calculateLevelProgress } from '@/services/stats';
import { PlayerAvatar } from '@/components/profile/PlayerAvatar';
import { useAuth } from '@/hooks/useAuth';

export interface LeaderboardPageProps {
  onNavigateHome: () => void;
  onSelectPlayer?: (userId: string) => void;
}

export const LeaderboardPage: React.FC<LeaderboardPageProps> = ({
  onNavigateHome,
  onSelectPlayer,
}) => {
  const { user } = useAuth();
  const [selectedTab, setSelectedTab] = useState<'global' | 'tic_tac_toe' | 'carta_duo' | 'snake' | 'domino'>('global');
  const [entries, setEntries] = useState<LeaderboardEntry[]>([]);
  const [isLoading, setIsLoading] = useState<boolean>(true);
  const [error, setError] = useState<string | null>(null);
  const [searchQuery, setSearchQuery] = useState<string>('');

  const loadLeaderboard = useCallback(async () => {
    setIsLoading(true);
    setError(null);
    const gameId = selectedTab === 'global' ? null : selectedTab;
    const res = await fetchLeaderboard(gameId, 100, 0);

    if (res.success && res.data) {
      setEntries(res.data);
    } else {
      setError(res.error || 'Não foi possível carregar a classificação.');
    }
    setIsLoading(false);
  }, [selectedTab]);

  useEffect(() => {
    loadLeaderboard();
  }, [loadLeaderboard]);

  const filteredEntries = useMemo(() => {
    if (!searchQuery.trim()) return entries;
    const q = searchQuery.toLowerCase().trim();
    return entries.filter(
      (entry) =>
        entry.username.toLowerCase().includes(q) ||
        entry.displayName.toLowerCase().includes(q)
    );
  }, [entries, searchQuery]);

  const currentUserEntry = useMemo(() => {
    if (!user?.id) return null;
    return entries.find((e) => e.userId === user.id) || null;
  }, [entries, user?.id]);

  const top3 = useMemo(() => {
    if (searchQuery.trim()) return [];
    return entries.slice(0, 3);
  }, [entries, searchQuery]);

  return (
    <div className="min-h-screen pb-24 md:pb-16 text-slate-100">
      {/* Top Header Bar & Breadcrumb */}
      <div className="border-b border-slate-800/80 bg-slate-950/70 backdrop-blur-md sticky top-16 z-20">
        <div className="max-w-5xl mx-auto px-4 sm:px-6 py-4 flex flex-col sm:flex-row sm:items-center justify-between gap-4">
          <div className="flex items-center gap-3">
            <button
              type="button"
              onClick={onNavigateHome}
              className="inline-flex items-center gap-2 px-3 py-2 rounded-xl bg-slate-900 border border-slate-800 hover:border-slate-700 hover:bg-slate-800 text-slate-300 hover:text-white text-xs font-bold transition-all active:scale-95 shadow-sm"
              aria-label="Voltar aos Jogos"
            >
              <ArrowLeft className="w-4 h-4 text-amber-400" />
              <span>Voltar aos Jogos</span>
            </button>
            <div className="h-5 w-px bg-slate-800 hidden sm:block" />
            <div>
              <div className="flex items-center gap-2">
                <div className="w-7 h-7 rounded-lg bg-amber-500/20 border border-amber-500/30 flex items-center justify-center text-amber-400">
                  <Trophy className="w-4 h-4" />
                </div>
                <h1 className="text-lg sm:text-xl font-black text-white tracking-tight">
                  Classificação & Hall da Fama
                </h1>
              </div>
              <p className="text-xs text-slate-400 mt-0.5">
                Os maiores competidores oficiais do DuoPlay Online
              </p>
            </div>
          </div>

          <button
            type="button"
            onClick={loadLeaderboard}
            disabled={isLoading}
            className="inline-flex items-center gap-1.5 px-3 py-2 rounded-xl bg-slate-900 hover:bg-slate-800 border border-slate-800 text-xs font-semibold text-slate-300 hover:text-white transition-all self-start sm:self-auto disabled:opacity-50"
          >
            <RefreshCw className={`w-3.5 h-3.5 ${isLoading ? 'animate-spin text-amber-400' : ''}`} />
            <span>Atualizar Ranking</span>
          </button>
        </div>
      </div>

      <div className="max-w-5xl mx-auto px-4 sm:px-6 py-6 sm:py-8 space-y-6">
        {/* Category Filter Tabs */}
        <div className="flex items-center gap-2 overflow-x-auto pb-2 scrollbar-none">
          <button
            type="button"
            onClick={() => setSelectedTab('global')}
            className={`px-4 py-2.5 rounded-xl text-xs sm:text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2 ${
              selectedTab === 'global'
                ? 'bg-amber-500/20 text-amber-300 border border-amber-500/40 shadow-lg shadow-amber-950/30'
                : 'bg-slate-900/80 text-slate-400 hover:text-slate-200 border border-slate-800'
            }`}
          >
            <Crown className="w-4 h-4 text-amber-400" />
            <span>Ranking Geral</span>
          </button>

          <button
            type="button"
            onClick={() => setSelectedTab('tic_tac_toe')}
            className={`px-4 py-2.5 rounded-xl text-xs sm:text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2 ${
              selectedTab === 'tic_tac_toe'
                ? 'bg-indigo-500/20 text-indigo-300 border border-indigo-500/40 shadow-lg shadow-indigo-950/30'
                : 'bg-slate-900/80 text-slate-400 hover:text-slate-200 border border-slate-800'
            }`}
          >
            <Swords className="w-4 h-4 text-indigo-400" />
            <span>Jogo da Velha</span>
          </button>

          <button
            type="button"
            onClick={() => setSelectedTab('carta_duo')}
            className={`px-4 py-2.5 rounded-xl text-xs sm:text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2 ${
              selectedTab === 'carta_duo'
                ? 'bg-purple-500/20 text-purple-300 border border-purple-500/40 shadow-lg shadow-purple-950/30'
                : 'bg-slate-900/80 text-slate-400 hover:text-slate-200 border border-slate-800'
            }`}
          >
            <Award className="w-4 h-4 text-purple-400" />
            <span>Carta Duo</span>
          </button>

          <button
            type="button"
            onClick={() => setSelectedTab('snake')}
            className={`px-4 py-2.5 rounded-xl text-xs sm:text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2 ${
              selectedTab === 'snake'
                ? 'bg-emerald-500/20 text-emerald-300 border border-emerald-500/40 shadow-lg shadow-emerald-950/30'
                : 'bg-slate-900/80 text-slate-400 hover:text-slate-200 border border-slate-800'
            }`}
          >
            <Flame className="w-4 h-4 text-emerald-400" />
            <span>Cobrinha Arena</span>
          </button>

          <button
            type="button"
            onClick={() => setSelectedTab('domino')}
            className={`px-4 py-2.5 rounded-xl text-xs sm:text-sm font-bold whitespace-nowrap transition-all flex items-center gap-2 ${
              selectedTab === 'domino'
                ? 'bg-blue-500/20 text-blue-300 border border-blue-500/40 shadow-lg shadow-blue-950/30'
                : 'bg-slate-900/80 text-slate-400 hover:text-slate-200 border border-slate-800'
            }`}
          >
            <Shield className="w-4 h-4 text-blue-400" />
            <span>Dominó Duo</span>
          </button>
        </div>

        {/* Podium Highlight (Top 3) */}
        {!searchQuery && top3.length >= 3 && !isLoading && (
          <div className="grid grid-cols-1 md:grid-cols-3 gap-3 sm:gap-4 pt-2">
            {/* 2º Lugar (Prata) */}
            <div
              onClick={() => onSelectPlayer?.(top3[1].userId)}
              className="order-2 md:order-1 p-5 rounded-3xl bg-gradient-to-b from-slate-900 via-slate-900/90 to-slate-950 border border-slate-700/60 shadow-xl flex flex-col items-center text-center space-y-3 cursor-pointer hover:border-slate-500 transition-all group"
            >
              <div className="relative">
                <div className="w-16 h-16 rounded-2xl p-1 bg-gradient-to-tr from-slate-400 to-slate-200 shadow-md">
                  <PlayerAvatar
                    avatarUrl={top3[1].avatarUrl}
                    displayName={top3[1].displayName}
                    size="lg"
                  />
                </div>
                <div className="absolute -bottom-2 inset-x-0 mx-auto w-6 h-6 rounded-full bg-slate-300 text-slate-950 font-black text-xs flex items-center justify-center shadow-md">
                  2
                </div>
              </div>
              <div className="space-y-0.5 pt-1">
                <h3 className="text-sm font-black text-white truncate max-w-[180px] group-hover:text-blue-300">
                  {top3[1].displayName}
                </h3>
                <span className="text-xs text-slate-400 block">@{top3[1].username}</span>
              </div>
              <div className="flex items-center gap-3 text-xs font-bold pt-2 border-t border-slate-800/80 w-full justify-around">
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Vitórias</span>
                  <span className="text-white">{top3[1].totalWins}</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Taxa</span>
                  <span className="text-emerald-400">{top3[1].winRate}%</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Nível</span>
                  <span className="text-amber-400">{top3[1].level}</span>
                </div>
              </div>
            </div>

            {/* 1º Lugar (Ouro) */}
            <div
              onClick={() => onSelectPlayer?.(top3[0].userId)}
              className="order-1 md:order-2 p-6 rounded-3xl bg-gradient-to-b from-amber-950/40 via-slate-900 to-slate-950 border-2 border-amber-500/50 shadow-2xl shadow-amber-950/40 flex flex-col items-center text-center space-y-3.5 cursor-pointer hover:border-amber-400 transition-all relative overflow-hidden group md:-translate-y-2"
            >
              <div className="absolute top-0 inset-x-0 h-1 bg-gradient-to-r from-amber-400 via-yellow-300 to-amber-500" />
              <div className="flex items-center gap-1 px-2.5 py-1 rounded-full bg-amber-500/20 border border-amber-500/30 text-amber-300 text-[10px] font-black uppercase tracking-wider">
                <Crown className="w-3 h-3 text-amber-400 fill-amber-400" />
                <span>Campeão do Ranking</span>
              </div>
              <div className="relative">
                <div className="w-20 h-20 rounded-2xl p-1 bg-gradient-to-tr from-amber-500 to-yellow-300 shadow-xl shadow-amber-500/30">
                  <PlayerAvatar
                    avatarUrl={top3[0].avatarUrl}
                    displayName={top3[0].displayName}
                    size="lg"
                  />
                </div>
                <div className="absolute -bottom-2.5 inset-x-0 mx-auto w-7 h-7 rounded-full bg-amber-400 text-slate-950 font-black text-sm flex items-center justify-center shadow-lg shadow-amber-500/50">
                  1
                </div>
              </div>
              <div className="space-y-0.5 pt-1">
                <h3 className="text-base font-black text-white truncate max-w-[200px] group-hover:text-amber-300">
                  {top3[0].displayName}
                </h3>
                <span className="text-xs text-amber-200/80 block">@{top3[0].username}</span>
              </div>
              <div className="flex items-center gap-3 text-xs font-bold pt-2 border-t border-amber-500/20 w-full justify-around">
                <div>
                  <span className="text-[10px] text-slate-400 block uppercase">Vitórias</span>
                  <span className="text-white text-sm">{top3[0].totalWins}</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-400 block uppercase">Taxa</span>
                  <span className="text-emerald-400 text-sm">{top3[0].winRate}%</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-400 block uppercase">Nível</span>
                  <span className="text-amber-400 text-sm">{top3[0].level}</span>
                </div>
              </div>
            </div>

            {/* 3º Lugar (Bronze) */}
            <div
              onClick={() => onSelectPlayer?.(top3[2].userId)}
              className="order-3 p-5 rounded-3xl bg-gradient-to-b from-slate-900 via-slate-900/90 to-slate-950 border border-amber-900/50 shadow-xl flex flex-col items-center text-center space-y-3 cursor-pointer hover:border-amber-700 transition-all group"
            >
              <div className="relative">
                <div className="w-16 h-16 rounded-2xl p-1 bg-gradient-to-tr from-amber-700 to-amber-600 shadow-md">
                  <PlayerAvatar
                    avatarUrl={top3[2].avatarUrl}
                    displayName={top3[2].displayName}
                    size="lg"
                  />
                </div>
                <div className="absolute -bottom-2 inset-x-0 mx-auto w-6 h-6 rounded-full bg-amber-700 text-white font-black text-xs flex items-center justify-center shadow-md">
                  3
                </div>
              </div>
              <div className="space-y-0.5 pt-1">
                <h3 className="text-sm font-black text-white truncate max-w-[180px] group-hover:text-amber-400">
                  {top3[2].displayName}
                </h3>
                <span className="text-xs text-slate-400 block">@{top3[2].username}</span>
              </div>
              <div className="flex items-center gap-3 text-xs font-bold pt-2 border-t border-slate-800/80 w-full justify-around">
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Vitórias</span>
                  <span className="text-white">{top3[2].totalWins}</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Taxa</span>
                  <span className="text-emerald-400">{top3[2].winRate}%</span>
                </div>
                <div>
                  <span className="text-[10px] text-slate-500 block uppercase">Nível</span>
                  <span className="text-amber-400">{top3[2].level}</span>
                </div>
              </div>
            </div>
          </div>
        )}

        {/* Search Bar */}
        <div className="relative">
          <Search className="absolute left-4 top-1/2 -translate-y-1/2 w-4 h-4 text-slate-400" />
          <input
            type="text"
            value={searchQuery}
            onChange={(e) => setSearchQuery(e.target.value)}
            placeholder="Buscar competidor por nome ou @username..."
            className="w-full pl-11 pr-4 py-3 rounded-2xl bg-slate-900/90 border border-slate-800 text-xs sm:text-sm text-slate-100 placeholder-slate-500 focus:outline-none focus:border-amber-500 transition-colors"
          />
        </div>

        {/* Current User Fixed Card */}
        {currentUserEntry && !searchQuery && (
          <div className="p-4 rounded-2xl bg-gradient-to-r from-amber-500/10 via-amber-500/5 to-slate-900 border border-amber-500/30 flex items-center justify-between gap-4 shadow-md">
            <div className="flex items-center gap-3">
              <div className="w-10 h-10 rounded-xl bg-amber-500/20 text-amber-300 border border-amber-500/40 flex items-center justify-center font-black text-sm shrink-0">
                #{currentUserEntry.rank}
              </div>
              <PlayerAvatar
                avatarUrl={currentUserEntry.avatarUrl}
                displayName={currentUserEntry.displayName}
                size="md"
              />
              <div className="min-w-0">
                <div className="flex items-center gap-2">
                  <h4 className="text-sm font-bold text-white truncate">
                    {currentUserEntry.displayName} (Você)
                  </h4>
                  <span className="px-1.5 py-0.2 rounded text-[10px] font-extrabold bg-amber-500/20 text-amber-300">
                    Sua Posição
                  </span>
                </div>
                <span className="text-xs text-slate-400 block truncate">
                  Nível {currentUserEntry.level} • {currentUserEntry.totalWins} Vitórias • {currentUserEntry.winRate}% Taxa
                </span>
              </div>
            </div>

            <div className="text-right shrink-0">
              <span className="text-xs font-bold text-amber-400">
                Rank #{currentUserEntry.rank}
              </span>
              <span className="text-[10px] text-slate-400 block">
                de {entries.length} jogadores
              </span>
            </div>
          </div>
        )}

        {/* Leaderboard Table / Cards */}
        <div className="space-y-2">
          {isLoading ? (
            <div className="space-y-2.5 py-6">
              {[1, 2, 3, 4, 5, 6].map((i) => (
                <div key={i} className="h-16 bg-slate-900/60 border border-slate-800/60 rounded-2xl animate-pulse" />
              ))}
            </div>
          ) : error ? (
            <div className="p-8 rounded-2xl bg-slate-900 border border-slate-800 text-center space-y-3">
              <p className="text-xs text-red-400">{error}</p>
              <button
                type="button"
                onClick={loadLeaderboard}
                className="inline-flex items-center gap-2 px-4 py-2 bg-slate-800 hover:bg-slate-700 text-xs font-bold text-white rounded-xl transition-colors"
              >
                <RefreshCw className="w-3.5 h-3.5" />
                <span>Tentar Novamente</span>
              </button>
            </div>
          ) : filteredEntries.length === 0 ? (
            <div className="p-12 rounded-2xl bg-slate-900/40 border border-slate-800 text-center space-y-2 text-slate-400">
              <Trophy className="w-10 h-10 stroke-1 text-slate-600 mx-auto" />
              <p className="text-sm font-medium">Nenhum jogador encontrado</p>
              <p className="text-xs text-slate-500">
                {searchQuery ? 'Tente outro termo de busca.' : 'Participe do matchmaking para inaugurar o ranking!'}
              </p>
            </div>
          ) : (
            filteredEntries.map((entry) => {
              const isCurrentUser = entry.userId === user?.id;

              return (
                <div
                  key={entry.userId}
                  onClick={() => onSelectPlayer?.(entry.userId)}
                  className={`p-3 sm:p-4 rounded-2xl border transition-all flex items-center justify-between gap-3 cursor-pointer select-none group ${
                    isCurrentUser
                      ? 'bg-amber-950/20 border-amber-500/40 hover:border-amber-400'
                      : 'bg-slate-900/80 border-slate-800/80 hover:border-slate-700 hover:bg-slate-900'
                  }`}
                >
                  <div className="flex items-center gap-3 min-w-0">
                    {/* Rank Badge */}
                    <div className="w-8 h-8 rounded-xl flex items-center justify-center shrink-0 font-black text-xs">
                      {entry.rank === 1 ? (
                        <div className="w-8 h-8 rounded-xl bg-amber-400 text-slate-950 flex items-center justify-center shadow-md">
                          <Crown className="w-4 h-4 fill-slate-950" />
                        </div>
                      ) : entry.rank === 2 ? (
                        <div className="w-8 h-8 rounded-xl bg-slate-300 text-slate-950 flex items-center justify-center shadow-md">
                          <Medal className="w-4 h-4" />
                        </div>
                      ) : entry.rank === 3 ? (
                        <div className="w-8 h-8 rounded-xl bg-amber-700 text-white flex items-center justify-center shadow-md">
                          <Award className="w-4 h-4" />
                        </div>
                      ) : (
                        <span className="text-slate-400">#{entry.rank}</span>
                      )}
                    </div>

                    <PlayerAvatar
                      avatarUrl={entry.avatarUrl}
                      displayName={entry.displayName}
                      size="sm"
                    />

                    <div className="min-w-0">
                      <div className="flex items-center gap-1.5">
                        <h4 className="text-xs sm:text-sm font-bold text-white truncate group-hover:text-blue-300 transition-colors">
                          {entry.displayName}
                        </h4>
                        {isCurrentUser && (
                          <span className="text-[10px] font-extrabold text-amber-300 bg-amber-500/20 px-1.5 rounded">
                            Você
                          </span>
                        )}
                      </div>
                      <span className="text-[11px] text-slate-400 block truncate">
                        @{entry.username}
                      </span>
                    </div>
                  </div>

                  {/* Stats summary */}
                  <div className="flex items-center gap-3 sm:gap-6 shrink-0 text-right">
                    <div className="hidden sm:block">
                      <span className="text-[10px] text-slate-500 uppercase block font-semibold">Nível</span>
                      <span className="text-xs font-bold text-amber-400">{entry.level}</span>
                    </div>
                    <div>
                      <span className="text-[10px] text-slate-500 uppercase block font-semibold">Vitórias</span>
                      <span className="text-xs font-bold text-white">{entry.totalWins}</span>
                    </div>
                    <div>
                      <span className="text-[10px] text-slate-500 uppercase block font-semibold">Taxa</span>
                      <span className="text-xs font-bold text-emerald-400">{entry.winRate}%</span>
                    </div>
                    <ChevronRight className="w-4 h-4 text-slate-500 group-hover:text-slate-300 group-hover:translate-x-0.5 transition-all" />
                  </div>
                </div>
              );
            })
          )}
        </div>
      </div>
    </div>
  );
};
